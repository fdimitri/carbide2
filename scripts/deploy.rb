#!/usr/bin/env ruby
# frozen_string_literal: true
#
# deploy.rb — structured deploy/redeploy orchestrator for the carbide2 stack.
#
# Takes a machine from "infra is up" to "the dashboard actually serves at
# https://<host>:8443/". Idempotent; doubles as the update/rebuild path.
#
# Pipeline:
#   1. ensure the k3d cluster + infra exist  (carbide2-server/scripts/dev-cluster.sh)
#   2. build images                          (scripts/build-all.sh)   [skip: --no-build]
#   3. k3d image import the images into the cluster
#   4. kubectl apply the Workspace CRD + wait for it to be established
#   5. helm upgrade --install the control-plane chart
#   6. roll the Deployments and wait for them to become Ready
#   7. verify ingress + report cluster state (via kubeclient)
#
# Why Ruby instead of bash: the verify/report step reads structured cluster
# state (pod readiness, Workspace CR .status.phase) through kubeclient — the
# same client the control-plane operator uses — instead of grepping kubectl
# text. The steps that only orchestrate external CLIs (docker, k3d, helm) still
# shell out, because those tools have no useful Ruby binding.
#
# Requires on the host running this: ruby (>= 3.0), bundler, docker (BuildKit),
# k3d, kubectl, helm. Gems (tty-command, kubeclient) are installed on first run
# via bundler/inline.
#
# Usage:
#   ./scripts/deploy.rb                 full build + deploy
#   ./scripts/deploy.rb --no-build      skip image build (re-import + redeploy)
#   ./scripts/deploy.rb --no-infra      skip cluster/infra bring-up
#   ./scripts/deploy.rb --no-tls        skip mkcert TLS setup (Traefik default cert)
#   ./scripts/deploy.rb --help
#
# Real (non-mkcert) certs — e.g. internal-test.carbidecore.online signed by an
# internal/corporate CA. Two standalone steps bracket your CA; neither touches
# the build pipeline:
#   PUBLIC_HOST=internal-test.carbidecore.online ./scripts/deploy.rb --csr
#       -> writes <host>.key + <host>.csr to TLS_OUT_DIR (default ./tls).
#          Submit the .csr to your CA.
#   ./scripts/deploy.rb --import-cert ./tls/<host>.crt
#       -> loads the signed cert (+ the .key) into the TLS_SECRET k8s secret and
#          wires it as Traefik's default cert. Later deploys reuse that secret.

require 'optparse'
require 'tmpdir'
require 'tempfile'
require 'fileutils'

# Bundler/inline installs the two helper gems at runtime, which needs a ruby
# whose gem dir is writable. A bare system ruby (e.g. /usr/bin/ruby on Debian)
# has a root-owned gem dir (/var/lib/gems) and a non-interactive SSH shell
# often doesn't load rbenv/rvm — so the shebang can land on exactly that ruby.
# If the current gem dir isn't writable, re-exec under a managed ruby that is.
unless File.writable?(Gem.dir) || ENV['CARBIDE_DEPLOY_REEXEC']
  candidates = [
    File.join(ENV['RBENV_ROOT'] || File.expand_path('~/.rbenv'), 'shims', 'ruby'),
    File.expand_path('~/.rvm/bin/ruby'),
  ]
  if (alt = candidates.find { |r| File.executable?(r) })
    warn "deploy.rb: #{Gem.dir} not writable under #{RbConfig.ruby}; " \
         "re-exec under #{alt}"
    exec({ 'CARBIDE_DEPLOY_REEXEC' => '1' }, alt, __FILE__, *ARGV)
  end
  abort "deploy.rb: gem dir #{Gem.dir} is not writable and no rbenv/rvm ruby " \
        "was found. Install a user-owned ruby (rbenv/rvm) and retry."
end

require 'bundler/inline'

gemfile(true) do
  source 'https://rubygems.org'
  gem 'tty-command', '~> 0.10'
  gem 'kubeclient',  '~> 4.11'
  # base64 was removed from Ruby's default gems in 3.4; kubeclient still needs it.
  gem 'base64'
end

module Carbide
  # Reads cluster state through kubeclient for the verification/report step.
  # Degrades gracefully: any failure here is non-fatal (the deploy already
  # happened), so methods rescue and return nil/empty rather than raising.
  class KubeStatus
    def initialize(control_ns:)
      @control_ns = control_ns
      @config = Kubeclient::Config.read(File.expand_path(ENV.fetch('KUBECONFIG', '~/.kube/config')))
      @context = @config.context
    rescue StandardError => e
      warn "  (kubeclient: could not read kubeconfig: #{e.message})"
      @context = nil
    end

    def available?
      !@context.nil?
    end

    # [{name:, ready:, phase:}] for control-plane pods.
    def control_pods
      core.get_pods(namespace: @control_ns).map do |p|
        ready = Array(p.status.containerStatuses).all? { |c| c.ready }
        { name: p.metadata.name, ready: ready, phase: p.status.phase }
      end
    rescue StandardError => e
      warn "  (kubeclient: pod read failed: #{e.message})"
      []
    end

    # [{name:, project:, phase:}] for Workspace CRs in the control namespace.
    def workspaces
      crd.get_workspaces(namespace: @control_ns).map do |w|
        { name: w.metadata.name,
          project: w.spec&.projectId,
          phase: (w.status&.phase || 'Pending') }
      end
    rescue StandardError => e
      # No CRs (or CRD just installed) is normal, not an error worth shouting about.
      []
    end

    private

    def core
      @core ||= Kubeclient::Client.new(
        @context.api_endpoint, 'v1',
        ssl_options: @context.ssl_options, auth_options: @context.auth_options
      )
    end

    def crd
      @crd ||= Kubeclient::Client.new(
        "#{@context.api_endpoint}/apis", 'carbide.dev/v1',
        ssl_options: @context.ssl_options, auth_options: @context.auth_options
      )
    end
  end

  class Deploy
    # No registry exists in dev, so every one of these must be `k3d image import`ed
    # or the pods ImagePullBackOff.
    IMAGES = %w[carbide2:dev carbide2-control:dev carbide2-shell:dev].freeze

    def initialize(opts)
      @opts       = opts
      @cmd        = TTY::Command.new(uuid: false, printer: :pretty)
      @root       = File.expand_path('..', __dir__)
      @server     = File.join(@root, 'carbide2-server')
      @control    = File.join(@root, 'carbide2-control')
      @cluster    = ENV.fetch('CLUSTER_NAME', 'carbide-dev')
      @control_ns = ENV.fetch('CONTROL_NS', 'carbide-system')
      @release    = ENV.fetch('RELEASE', 'carbide-control')
      @http_port  = ENV.fetch('HTTP_PORT', '8080')
      @https_port = ENV.fetch('HTTPS_PORT', '8443')
      # The hostname the BROWSER uses to reach the ingress. Drives the TLS cert
      # SANs, the public URL the control-plane advertises, and the Rails host
      # allowlist for workspace pods. Defaults to localhost for a purely-local
      # cluster; set PUBLIC_HOST=dev1.frankd.local for a LAN-reachable dev box.
      @public_host = ENV.fetch('PUBLIC_HOST', 'localhost')
      @public_url  = ENV.fetch('PUBLIC_URL_BASE', "https://#{@public_host}:#{@https_port}")
    end

    def run
      return generate_csr if @opts[:csr]
      return import_cert if @opts[:import_cert]

      require_tools
      ensure_infra unless @opts[:no_infra]
      build_images unless @opts[:no_build]
      import_images
      apply_crd
      install_control_plane
      setup_tls unless @opts[:no_tls]
      roll_deployments
      verify
      summary
    end

    private

    def log(msg) = puts("\e[1;34m==>\e[0m #{msg}")
    def warn_(msg) = warn("\e[1;33m!!\e[0m #{msg}")

    def require_tools
      %w[docker k3d kubectl helm].each do |tool|
        next if system("command -v #{tool} >/dev/null 2>&1")

        abort "\e[1;31mxx\e[0m missing required tool: #{tool}"
      end
    end

    def ensure_infra
      log "ensuring cluster + infra via carbide2-server/scripts/dev-cluster.sh"
      @cmd.run(File.join(@server, 'scripts', 'dev-cluster.sh'),
               env: { 'CLUSTER_NAME' => @cluster,
                      'HTTP_PORT' => @http_port,
                      'HTTPS_PORT' => @https_port })
    end

    def build_images
      log "building images via scripts/build-all.sh"
      @cmd.run(File.join(@root, 'scripts', 'build-all.sh'))
    end

    def import_images
      log "importing images into k3d cluster '#{@cluster}'"
      IMAGES.each do |img|
        if @cmd.run!("docker image inspect #{img}").success?
          log "  import #{img}"
          @cmd.run('k3d', 'image', 'import', img, '-c', @cluster)
        else
          warn_ "  #{img} not present locally — skipping import (build it first)"
        end
      end
    end

    # Generate a locally-trusted TLS cert with mkcert and install it as the
    # Traefik *default* certificate, so every IngressRoute that leaves its tls
    # block empty (tls: {}) — the control-plane route AND the operator's
    # per-workspace ws-* routes — serves a trusted cert. Without this Traefik
    # falls back to its built-in "TRAEFIK DEFAULT CERT" (wrong host, untrusted),
    # which browsers let you click through for page loads but NOT for wss://
    # WebSocket handshakes — so the IDE socket fails with no response headers.
    def setup_tls
      ns     = ENV.fetch('TRAEFIK_NS', 'traefik')
      secret = ENV.fetch('TLS_SECRET', 'carbide-tls')

      if @cmd.run!('kubectl', '-n', ns, 'get', "secret/#{secret}").success?
        log "TLS secret #{ns}/#{secret} already present — reusing (delete it to regenerate)"
        ensure_tls_store(ns, secret)
        return
      end

      unless system('command -v mkcert >/dev/null 2>&1')
        abort <<~ERR
          \e[1;31mxx mkcert not found.\e[0m It is required to mint a locally-trusted TLS
          cert for the ingress. Without a trusted cert the dashboard loads after a
          browser click-through, but the IDE WebSocket (wss://) silently fails.

          Install mkcert, then re-run this script:
            # Debian/Ubuntu
            sudo apt-get install -y libnss3-tools
            curl -JLO "https://dl.filippo.io/mkcert/latest?for=linux/amd64"
            chmod +x mkcert-v*-linux-amd64 && sudo mv mkcert-v*-linux-amd64 /usr/local/bin/mkcert
            mkcert -install

          Alternatives:
            - bring a real CA-signed cert: ./scripts/deploy.rb --csr  then
              ./scripts/deploy.rb --import-cert <signed.crt>, or
            - set TLS_SECRET to an existing kubernetes TLS secret in the
              '#{ns}' namespace to skip mkcert, or
            - re-run with --no-tls to leave Traefik on its (untrusted) default cert.
        ERR
      end

      hosts = tls_hosts
      log "minting locally-trusted cert via mkcert for: #{hosts.join(' ')}"
      Dir.mktmpdir do |dir|
        crt = File.join(dir, 'tls.crt')
        key = File.join(dir, 'tls.key')
        @cmd.run('mkcert', '-cert-file', crt, '-key-file', key, *hosts)
        @cmd.run('kubectl', '-n', ns, 'create', 'secret', 'tls', secret,
                 "--cert=#{crt}", "--key=#{key}")
      end
      ensure_tls_store(ns, secret)

      caroot, = @cmd.run!('mkcert', '-CAROOT')
      caroot = (caroot || '').strip
      warn_ "Trust mkcert's root CA on the machine running your browser, or wss:// still fails:"
      warn_ "  rootCA: #{caroot}/rootCA.pem"
      warn_ "  (copy it to that machine and `mkcert -install`, or import it into the OS/browser trust store)"
    end

    # The TLSStore named 'default' in Traefik's namespace is the cert Traefik
    # serves whenever an IngressRoute's tls block names no explicit secret.
    def ensure_tls_store(ns, secret)
      store = <<~YAML
        apiVersion: traefik.io/v1alpha1
        kind: TLSStore
        metadata:
          name: default
          namespace: #{ns}
        spec:
          defaultCertificate:
            secretName: #{secret}
      YAML
      Tempfile.create(['tlsstore', '.yaml']) do |f|
        f.write(store)
        f.flush
        @cmd.run('kubectl', 'apply', '-f', f.path)
      end
    end

    # Hostnames/IPs the cert is valid for. Override with TLS_HOSTS="a b c";
    # otherwise auto-detect this host's FQDN, short name, and IPs plus loopback.
    def tls_hosts
      return ENV['TLS_HOSTS'].split if ENV['TLS_HOSTS'] && !ENV['TLS_HOSTS'].strip.empty?

      hosts = %w[localhost 127.0.0.1 ::1]
      hosts << @public_host unless @public_host.empty?
      %w[-f -s].each do |flag|
        out, = @cmd.run!('hostname', flag)
        v = (out || '').strip
        hosts << v unless v.empty?
      end
      ips, = @cmd.run!('hostname', '-I')
      hosts.concat((ips || '').strip.split)
      hosts.uniq
    end

    # --- bring-your-own-CA cert flow -------------------------------------------
    # For a real cert (internal/corporate CA, public ACME-portal, etc.) you don't
    # want a locally-trusted mkcert cert — you want a CSR your CA can sign. These
    # two steps bracket the CA and exit without touching the build pipeline.

    # Where --csr writes the key/CSR and where --import-cert looks for the key.
    def csr_dir = File.expand_path(ENV.fetch('TLS_OUT_DIR', 'tls'))

    # Pick the cert CN: prefer an explicit FQDN (PUBLIC_HOST or a dotted SAN),
    # falling back to the first host so the file naming stays predictable.
    def csr_common_name(hosts)
      return @public_host unless @public_host.empty? || @public_host == 'localhost'

      hosts.find { |h| h.include?('.') && !h.match?(/\A[0-9.]+\z/) } || hosts.first
    end

    def dns_san?(host) = !host.include?(':') && !host.match?(/\A[0-9.]+\z/)

    def openssl_csr_config(cn, hosts)
      sans = hosts.each_with_index
                  .map { |h, i| "#{dns_san?(h) ? 'DNS' : 'IP'}.#{i + 1} = #{h}" }
                  .join("\n")
      <<~CNF
        [req]
        distinguished_name = dn
        req_extensions = v3_req
        prompt = no
        [dn]
        CN = #{cn}
        [v3_req]
        basicConstraints = CA:FALSE
        keyUsage = digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = @alt
        [alt]
        #{sans}
      CNF
    end

    def generate_csr
      unless system('command -v openssl >/dev/null 2>&1')
        abort "\e[1;31mxx\e[0m openssl not found — required to generate a CSR."
      end

      hosts = tls_hosts
      cn    = csr_common_name(hosts)
      FileUtils.mkdir_p(csr_dir)
      key = File.join(csr_dir, "#{cn}.key")
      csr = File.join(csr_dir, "#{cn}.csr")
      log "generating RSA key + CSR for CN=#{cn}"
      log "  SANs: #{hosts.join(' ')}"
      Tempfile.create(['csr', '.cnf']) do |cfg|
        cfg.write(openssl_csr_config(cn, hosts))
        cfg.flush
        @cmd.run('openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes',
                 '-keyout', key, '-out', csr, '-config', cfg.path)
      end
      File.chmod(0o600, key)
      puts <<~MSG

        \e[1;32mCSR written.\e[0m Keep the key private; submit the CSR to your CA.
          key: #{key}   (private — do not share)
          csr: #{csr}

        When your CA returns the signed certificate (PEM), import it:
          ./scripts/deploy.rb --import-cert #{csr.sub(/\.csr\z/, '.crt')}

        If the CA gives you a chain, concatenate the leaf + intermediates into
        that .crt (leaf first) before importing.
      MSG
    end

    def import_cert
      unless system('command -v kubectl >/dev/null 2>&1')
        abort "\e[1;31mxx\e[0m kubectl not found — required to import the cert."
      end

      ns     = ENV.fetch('TRAEFIK_NS', 'traefik')
      secret = ENV.fetch('TLS_SECRET', 'carbide-tls')
      crt    = File.expand_path(@opts[:import_cert])
      abort "\e[1;31mxx\e[0m cert not found: #{crt}" unless File.file?(crt)

      key = @opts[:key] ? File.expand_path(@opts[:key]) : default_csr_key
      unless key && File.file?(key)
        abort "\e[1;31mxx\e[0m private key not found. Pass --key PATH (or run " \
              "--csr first so the key lives in #{csr_dir})."
      end

      log "importing cert into secret #{ns}/#{secret}"
      log "  cert: #{crt}"
      log "  key:  #{key}"
      # Recreate so a re-import replaces an older cert rather than failing on AlreadyExists.
      @cmd.run!('kubectl', '-n', ns, 'delete', 'secret', secret, '--ignore-not-found')
      @cmd.run('kubectl', '-n', ns, 'create', 'secret', 'tls', secret,
               "--cert=#{crt}", "--key=#{key}")
      ensure_tls_store(ns, secret)
      puts <<~MSG

        \e[1;32mCert imported.\e[0m Traefik now serves #{ns}/#{secret} as its default cert.
        Run ./scripts/deploy.rb (it reuses an existing TLS_SECRET) or, if the
        stack is already up, the new cert is live immediately.
      MSG
    end

    # The single .key left in TLS_OUT_DIR by --csr, when --key isn't given.
    def default_csr_key
      keys = Dir.glob(File.join(csr_dir, '*.key'))
      keys.first if keys.size == 1
    end

    def apply_crd
      log "applying Workspace CRD"
      @cmd.run('kubectl', 'apply', '-f', File.join(@control, 'deploy', 'crd-workspace.yaml'))
      @cmd.run('kubectl', 'wait', '--for=condition=established',
               'crd/workspaces.carbide.dev', '--timeout=60s')
    end

    def install_control_plane
      log "installing/upgrading control-plane release '#{@release}' in ns '#{@control_ns}'"
      @cmd.run('helm', 'upgrade', '--install', @release,
               File.join(@control, 'charts', 'control-plane'),
               '--namespace', @control_ns, '--create-namespace',
               '--set', "ingress.publicPort=#{@http_port}",
               '--set', "ingress.publicHttpsPort=#{@https_port}",
               '--set', "publicUrlBase=#{@public_url}",
               '--set-json', 'ingress.entryPoints=["web","websecure"]',
               '--set-json', 'ingress.tls={}',
               '--wait', '--timeout', '5m')
    end

    def roll_deployments
      # helm upgrade is a no-op for the pod spec when only image *contents* change
      # (same tag), so force a rollout to pull the freshly-imported images.
      log "rolling control-plane Deployments to pick up new images"
      %w[control-plane-rails control-plane-operator].each do |dep|
        @cmd.run('kubectl', '-n', @control_ns, 'rollout', 'restart', "deploy/#{dep}")
        @cmd.run('kubectl', '-n', @control_ns, 'rollout', 'status', "deploy/#{dep}", '--timeout=5m')
      end

      # Roll any existing workspace deployments so re-deploys refresh them too.
      workspace_namespaces.each do |ns|
        next unless @cmd.run!('kubectl', '-n', ns, 'get', "deploy/#{ns}").success?

        log "rolling workspace deployment #{ns}"
        @cmd.run('kubectl', '-n', ns, 'rollout', 'restart', "deploy/#{ns}")
      end
    end

    def workspace_namespaces
      out, = @cmd.run!('kubectl', 'get', 'ns', '-o', 'name')
      (out || '').lines.map { |l| l.strip.sub('namespace/', '') }
                 .select { |n| n.match?(/\Aws-\d+\z/) }
    end

    def verify
      log "verifying ingress (self-signed cert -> curl -k)"
      http  = curl_code("http://localhost:#{@http_port}/")
      https = curl_code("https://localhost:#{@https_port}/", insecure: true)
      log "  http://localhost:#{@http_port}/   -> #{http} (expect 301/308 redirect)"
      log "  https://localhost:#{@https_port}/ -> #{https} (expect 200)"

      status = KubeStatus.new(control_ns: @control_ns)
      return unless status.available?

      pods = status.control_pods
      unless pods.empty?
        log "control-plane pods:"
        pods.each { |p| puts "    #{p[:ready] ? '✓' : '✗'} #{p[:name]} (#{p[:phase]})" }
      end

      ws = status.workspaces
      unless ws.empty?
        log "workspaces:"
        ws.each { |w| puts "    #{w[:name]} project=#{w[:project]} phase=#{w[:phase]}" }
      end
    end

    def curl_code(url, insecure: false)
      flags = insecure ? '-sk' : '-s'
      out, = @cmd.run!('curl', flags, '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '10', url)
      (out || '???').strip
    end

    def summary
      puts <<~MSG

        \e[1;32mStack deployed to cluster '#{@cluster}'.\e[0m

          Dashboard:   #{@public_url}/   (http://#{@public_host}:#{@http_port}/ redirects here)
          Seeded user: admin@example.com / password   (carbide2-control db/seeds.rb)

        Inspect:
          kubectl -n #{@control_ns} get pods,ingressroute
          helm -n #{@control_ns} get values #{@release}

        Re-run this script any time to rebuild + redeploy. Flags:
          --no-build   skip image build (just re-import + redeploy)
          --no-infra   skip cluster/infra bring-up
          --no-tls     skip mkcert TLS setup (leave Traefik default cert)
      MSG
    end
  end
end

opts = { no_build: false, no_infra: false, no_tls: false, csr: false, import_cert: nil, key: nil }
OptionParser.new do |o|
  o.banner = 'Usage: deploy.rb [--no-build] [--no-infra] [--no-tls] [--csr | --import-cert FILE]'
  o.on('--no-build', 'Skip image build (just re-import + redeploy)') { opts[:no_build] = true }
  o.on('--no-infra', 'Skip cluster/infra bring-up')                  { opts[:no_infra] = true }
  o.on('--no-tls',   'Skip mkcert TLS setup (Traefik default cert)')  { opts[:no_tls] = true }
  o.on('--csr', 'Generate a private key + CSR (TLS_HOSTS/PUBLIC_HOST) in TLS_OUT_DIR, then exit') { opts[:csr] = true }
  o.on('--import-cert FILE', 'Load a CA-signed cert into TLS_SECRET as Traefik default, then exit') { |v| opts[:import_cert] = v }
  o.on('--key FILE', 'Private key for --import-cert (default: the .key from --csr in TLS_OUT_DIR)') { |v| opts[:key] = v }
  o.on('-h', '--help', 'Show this help') { puts o; exit 0 }
end.parse!(ARGV)

Carbide::Deploy.new(opts).run
