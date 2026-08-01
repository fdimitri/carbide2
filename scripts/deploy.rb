#!/usr/bin/env ruby
# frozen_string_literal: true
#
# deploy.rb — structured deploy/redeploy orchestrator for the carbide2 stack.
#
# Takes a machine from "infra is up" to "the dashboard actually serves at
# https://<host>:8443/". Idempotent; doubles as the update/rebuild path.
#
# Pipeline:
#   1. ensure the cluster + infra exist      (carbide2-server/scripts/dev-cluster-<backend>.sh)
#   2. build images                          (scripts/build-all.sh)   [skip: --no-build]
#   3. import the images into the cluster    (k3d image import, or k3s containerd import)
#   4. build + upload the pinned SPA clients (workspace + control) to the
#      MinIO static tier                      (scripts/build-client)   [skip: --no-client]
#   5. kubectl apply the Workspace CRD + wait for it to be established
#   6. helm upgrade --install the control-plane chart
#   7. roll the Deployments and wait for them to become Ready
#   8. verify ingress + report cluster state (via kubeclient)
#
# Why Ruby instead of bash: the verify/report step reads structured cluster
# state (pod readiness, Workspace CR .status.phase) through kubeclient — the
# same client the control-plane operator uses — instead of grepping kubectl
# text. The steps that only orchestrate external CLIs (docker, k3d, helm) still
# shell out, because those tools have no useful Ruby binding.
#
# Requires on the host running this: ruby (>= 3.0), bundler, docker (BuildKit),
# kubectl, helm, and k3d (only for the default --kube-backend=k3d; the k3s
# backend installs k3s itself). Gems (tty-command, kubeclient) are installed on
# first run via bundler/inline.
#
# Usage:
#   ./scripts/deploy.rb                 full build + deploy
#   ./scripts/deploy.rb --kube-backend k3s   deploy to host-native k3s (default: k3d)
#   ./scripts/deploy.rb --registry-host HOST  push SHA-tagged images to a self-hosted
#                                       registry at HOST (multi-node: every node pulls
#                                       from it instead of a per-node containerd import)
#   ./scripts/deploy.rb --publish-only --registry-host HOST
#                                       build + push images to the registry, then STOP.
#                                       For a dedicated build/registry host that runs no
#                                       k3s (pair with --external-registry on the nodes).
#   ./scripts/deploy.rb --external-registry --registry-host HOST --registry-ca FILE
#                                       deploy to a k3s node that pulls from a registry
#                                       run ELSEWHERE: skip the local registry + build,
#                                       just pull the already-pushed tags.
#   ./scripts/deploy.rb --no-build      skip image build (re-import + redeploy)
#   ./scripts/deploy.rb --no-shell      build everything EXCEPT the carbide2-shell image
#   ./scripts/deploy.rb --no-client     skip building + uploading the pinned SPA client
#   ./scripts/deploy.rb --no-infra      skip cluster/infra bring-up
#   ./scripts/deploy.rb --no-tls        skip mkcert TLS setup (Traefik default cert)
#   ./scripts/deploy.rb --no-pull       skip the self-update (pull + submodules) step
#   ./scripts/deploy.rb --help
#
# Self-update: by default the very first thing deploy.rb does is `git pull
# --ff-only` the meta repo and `git submodule update --init --recursive`, so a
# deploy always runs the latest orchestrator + submodule SHAs. If the pull
# changes deploy.rb itself, the script re-execs the updated copy before doing
# any work. Pass --no-pull to deploy exactly what's checked out right now.
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
require 'digest'
require_relative 'lib/carbide_images'
require_relative 'lib/carbide_tls'
require_relative 'lib/carbide_cluster'
require_relative 'lib/carbide_control_plane'

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
    def initialize(opts)
      @opts       = opts
      @cmd        = TTY::Command.new(uuid: false, printer: :pretty)
      # A second command instance that prints NOTHING — used for the long,
      # noisy external builds whose raw docker/k3d output (much of it on stderr,
      # which the pretty printer renders in alarming red) is just progress
      # spew. quiet_run captures it and only surfaces it on failure.
      @quiet      = TTY::Command.new(uuid: false, printer: :null)
      @root       = File.expand_path('..', __dir__)
      @server     = File.join(@root, 'carbide2-server')
      @control    = File.join(@root, 'carbide2-control')
      @cluster    = ENV.fetch('CLUSTER_NAME', 'carbide-dev')
      @control_ns = ENV.fetch('CONTROL_NS', 'carbide-system')
      @release    = ENV.fetch('RELEASE', 'carbide-control')
      # The local single-node backend (k3d default / k3s host-native) — its
      # ports, infra bring-up, and containerd image-import path all live in the
      # shared Carbide::Cluster helper (validates the backend on construction).
      @cluster_iface = Carbide::Cluster.new(
        cmd: @cmd, quiet: @quiet,
        backend: @opts[:kube_backend] || ENV.fetch('KUBE_BACKEND', 'k3d'),
        name: @cluster, server_root: @server
      )
      @http_port  = @cluster_iface.http_port
      @https_port = @cluster_iface.https_port
      # Optional self-hosted registry. When --registry-host/REGISTRY_HOST is set,
      # deploy switches from the single-node containerd-import path to building
      # immutable SHA-tagged images, pushing them to a standalone registry:2 on
      # this host, and pinning those tags into the control-plane chart — so every
      # node in a multi-node cluster pulls the same image over HTTPS. Unset =
      # legacy behavior (k3d/k3s `ctr images import`, :dev tags).
      @registry_host = (@opts[:registry_host] || ENV['REGISTRY_HOST'])&.strip
      @registry_host = nil if @registry_host && @registry_host.empty?
      @registry_port = (@opts[:registry_port] || ENV.fetch('REGISTRY_PORT', '5000')).to_s
      @registry      = @registry_host ? "#{@registry_host}:#{@registry_port}/" : nil
      # Split-host modes so a multi-node cluster needn't co-locate build+registry
      # on a k3s node. --publish-only: THIS host only builds + pushes images to
      # its registry (no k3s/helm). --external-registry: THIS host is a k3s node
      # that pulls from a registry someone ELSE runs, so skip standing up a local
      # one and skip building (images are already pushed). --registry-ca points at
      # that external registry's CA so containerd + our reachability check trust it.
      @publish_only      = @opts[:publish_only]
      @external_registry = @opts[:external_registry]
      @registry_ca       = (@opts[:registry_ca] || ENV['REGISTRY_CA'])&.strip
      @registry_ca       = nil if @registry_ca && @registry_ca.empty?
      validate_registry_modes!
      # All image build/tag/registry logic lives in the shared Images library
      # (also used by scripts/build.rb) so the two never drift.
      @images = Carbide::Images.new(
        cmd: @cmd, quiet: @quiet, root: @root,
        registry_host: @registry_host, registry_port: @registry_port,
        registry_ca: @registry_ca
      )
      # Which meta-repo branch/ref this deploy builds from. self_update checks it
      # out and fast-forwards it before doing anything, so the deployed images
      # always match a known ref instead of "whatever happened to be checked
      # out". Default 'main' (the deployable line); --ref/DEPLOY_REF can target
      # 'dev' for a test deploy. The resolved ref + SHA are logged up front.
      @deploy_ref = (@opts[:ref] || ENV.fetch('DEPLOY_REF', 'main')).to_s
      # The hostname the BROWSER uses to reach the ingress. Drives the TLS cert
      # SANs, the public URL the control-plane advertises, and the Rails host
      # allowlist. We refuse to silently guess 'localhost': that bakes the wrong
      # cert SANs and advertises an unreachable URL whenever the box is actually
      # reached by its LAN name. resolve_public_endpoint detects a real FQDN via
      # `hostname -f` and otherwise STOPS with instructions (see method).
      # The dedicated build/registry host (--publish-only) serves no ingress, so
      # don't demand a browser FQDN there.
      @public_host, @public_url = @publish_only ? ['', ''] : resolve_public_endpoint
      # Which deployments roll_deployments restarts after a redeploy:
      #   all     — control-plane AND workspace deployments (+ orphaned shell
      #             pods). Version-coherent: the editor SPA (served by the
      #             workspace pod) and the dashboard SPA (served by control-
      #             plane) move together, avoiding client:server skew. Cost:
      #             restarting a workspace deployment kills its worker and
      #             drops all live project terminals/PTYs.
      #   control — control-plane deployments only. Preserves active project
      #             terminals, but risks a new dashboard talking to an old
      #             workspace API. Use when iterating on control-plane only.
      #   none    — skip rolling entirely (helm/CRD changes only).
      # Default is 'all' because every current environment is dev, where
      # coherence matters more than terminal uptime. CLI --roll-scope overrides.
      @roll_scope = (@opts[:roll_scope] || ENV.fetch('ROLL_SCOPE', 'all')).to_s
      # Ingress TLS/cert flows (mkcert default cert, CSR/import, CA trust hints)
      # live in the shared Carbide::Tls helper.
      @tls = Carbide::Tls.new(cmd: @cmd, root: @root, public_host: @public_host)
      # The CRD + helm release + Deployment rollouts live in Carbide::ControlPlane;
      # it reads image tags straight from @images so the chart pins what we built.
      @control_plane = Carbide::ControlPlane.new(
        cmd: @cmd, control_root: @control, namespace: @control_ns, release: @release,
        images: @images, http_port: @http_port, https_port: @https_port,
        public_url: @public_url, roll_scope: @roll_scope
      )
    end

    def run
      self_update
      return @tls.generate_csr if @opts[:csr]
      return @tls.import_cert(@opts[:import_cert], key_path: @opts[:key]) if @opts[:import_cert]

      require_tools
      return publish_only_run if @publish_only

      ensure_registry if @registry && !@external_registry
      ensure_infra unless @opts[:no_infra]
      build_images unless @opts[:no_build] || @external_registry || skip_build?
      publish_images unless @external_registry
      build_and_upload_client unless @opts[:no_client]
      @control_plane.apply_crd
      @control_plane.install
      @tls.setup_tls unless @opts[:no_tls]
      @control_plane.roll_deployments
      verify
      summary
      # Trust instructions go dead last so they're the final thing on screen —
      # they're the one manual step left and shouldn't scroll off behind build
      # spew or the verify report.
      @tls.trust_ca_instructions unless @opts[:no_tls]
    end

    private

    # --publish-only: build the SHA-tagged images and push them to the self-hosted
    # registry, then stop. Runs on the dedicated build/registry host (no k3s, no
    # helm, no cluster) so the k3s nodes can pull the images over HTTPS. Pair it
    # with --external-registry on each k3s node, which consumes this registry
    # instead of standing up its own.
    def publish_only_run
      ensure_registry
      build_images unless @opts[:no_build] || skip_build?
      @images.push
      log "publish-only complete \u2014 images are in the registry at " \
          "#{@registry_host}:#{@registry_port}"
      log "next: on each k3s node run deploy.rb --external-registry " \
          "--registry-host #{@registry_host} --registry-ca <rootCA.pem> " \
          "(copy this host's mkcert rootCA.pem over first)"
    end

    # Guard the split-host registry flags: they only make sense with a registry,
    # are mutually exclusive, and --external-registry needs the registry's CA.
    def validate_registry_modes!
      if @publish_only && @external_registry
        abort "\e[1;31mxx\e[0m --publish-only and --external-registry are mutually " \
              "exclusive: one builds+pushes images, the other consumes them."
      end
      if (@publish_only || @external_registry) && !@registry
        abort "\e[1;31mxx\e[0m #{@publish_only ? '--publish-only' : '--external-registry'} " \
              "needs --registry-host (the self-hosted registry to push to / pull from)."
      end
      if @external_registry && !@registry_ca
        abort "\e[1;31mxx\e[0m --external-registry needs --registry-ca FILE (the registry's " \
              "mkcert rootCA.pem, copied from the build host) so this node trusts it."
      end
    end

    # Resolve the browser-facing hostname + URL base. Order of precedence:
    #   1. PUBLIC_URL_BASE  (explicit full URL, wins outright)
    #   2. PUBLIC_HOST env / --public-host flag
    #   3. `hostname -f`    (only if it yields a real, dotted FQDN)
    # If none of those produce a usable hostname we STOP rather than silently
    # falling back to 'localhost'. A localhost guess bakes the wrong TLS cert
    # SANs, advertises an unreachable dashboard URL, and (historically) produced
    # confusing "Blocked hosts" 403s when the box was reached by its LAN name.
    def resolve_public_endpoint
      if (url = ENV['PUBLIC_URL_BASE']) && !url.strip.empty?
        u    = url.strip
        host = u.sub(%r{\A[a-zA-Z]+://}, '').sub(/:\d+\z/, '')
        return [host, u]
      end
      host = (@opts[:public_host] || ENV['PUBLIC_HOST'])&.strip
      fqdn = detect_fqdn
      host = fqdn if host.nil? || host.empty?
      unless host && !host.empty? && valid_public_host?(host)
        abort <<~MSG
          \e[1;31mxx\e[0m Could not determine the browser-facing hostname for this deploy.
             `hostname -f` returned #{fqdn.inspect}, which is not a usable FQDN
             (a bare short name like "dev1" won't resolve for remote browsers and
             makes useless cert SANs). Set one explicitly and re-run, e.g.:
               PUBLIC_HOST=dev1.frankd.local ./scripts/deploy.rb
               ./scripts/deploy.rb --public-host dev1.frankd.local
             or pin the full URL base:
               PUBLIC_URL_BASE=https://dev1.frankd.local:#{@https_port} ./scripts/deploy.rb
             (Use PUBLIC_HOST=localhost only for a purely-local, same-machine cluster.)
        MSG
      end
      [host, "https://#{host}:#{@https_port}"]
    end

    def detect_fqdn
      out, = @cmd.run!('hostname', '-f')
      (out || '').strip
    end

    # A usable public host is a dotted FQDN, an explicit 'localhost', or an IPv4
    # literal. A bare short name (no dot, e.g. "dev1") is rejected.
    def valid_public_host?(host)
      return true if host == 'localhost'
      return true if host =~ /\A\d{1,3}(\.\d{1,3}){3}\z/
      host.include?('.') && host !~ /\s/ && !host.start_with?('.') && !host.end_with?('.')
    end

    def log(msg) = puts("\e[1;34m==>\e[0m #{msg}")

    # Run a long, noisy external command without streaming its (often red,
    # alarming-looking) docker/k3d output. Print one friendly line up front and
    # only dump the captured output if the command actually fails.
    def quiet_run(msg, *cmd_args, env: {})
      log msg
      result = @quiet.run!(*cmd_args, env: env)
      return result if result.success?

      $stdout.write(result.out)
      $stderr.write(result.err)
      abort "\e[1;31mxx\e[0m failed (output above): #{msg}"
    end

    # Pull the meta repo + refresh submodules BEFORE any deploy work, so a deploy
    # always runs the newest orchestrator and the submodule SHAs it expects.
    # Default on; --no-pull skips it. If the pull changes deploy.rb itself we
    # re-exec the updated copy (CARBIDE_DEPLOY_PULLED guards against a loop —
    # it's inherited across the exec, so the child skips this step).
    def self_update
      return if @opts[:no_pull]
      return if ENV['CARBIDE_DEPLOY_PULLED']

      log "self-update: fetch + checkout '#{@deploy_ref}' + submodule update in #{@root}"
      before = file_digest(__FILE__)
      Dir.chdir(@root) do
        unless @cmd.run!('git', 'fetch', '--prune', 'origin').success?
          abort "\e[1;31mxx\e[0m self-update: 'git fetch origin' failed in #{@root}. " \
                "Check the network/remote (or pass --no-pull) and retry."
        end
        unless @cmd.run!('git', 'checkout', @deploy_ref).success?
          abort "\e[1;31mxx\e[0m self-update: cannot checkout '#{@deploy_ref}' in #{@root}. " \
                "Commit/stash local changes, or pick a valid --ref (or pass --no-pull), then retry."
        end
        unless @cmd.run!('git', 'merge', '--ff-only', "origin/#{@deploy_ref}").success?
          abort "\e[1;31mxx\e[0m self-update: '#{@deploy_ref}' is not fast-forwardable to " \
                "origin/#{@deploy_ref} (local commits or a dirty tree). Resolve it " \
                "(or pass --no-pull) and retry."
        end
        @cmd.run('git', 'submodule', 'update', '--init', '--recursive')
        sha, = @cmd.run!('git', 'rev-parse', '--short', 'HEAD')
        log "self-update: deploying ref '#{@deploy_ref}' @ #{(sha || '').strip}"
      end
      after = file_digest(__FILE__)

      ENV['CARBIDE_DEPLOY_PULLED'] = '1'
      return unless before && after && before != after

      log 'self-update: deploy.rb changed — re-running the updated orchestrator'
      exec(RbConfig.ruby, __FILE__, *ARGV)
    end

    def file_digest(path)
      Digest::SHA256.file(path).hexdigest
    rescue StandardError
      nil
    end

    def require_tools
      # k3s installs itself from dev-cluster-k3s.sh, so it isn't a prereq tool;
      # docker stays required for BOTH backends (image build + the k3s
      # `docker save | k3s ctr images import` path).
      # --publish-only only builds + pushes images: docker is enough, no k8s CLI.
      tools = @publish_only ? %w[docker] : %w[docker kubectl helm]
      tools.concat(@cluster_iface.extra_tools) unless @publish_only
      tools.each do |tool|
        next if system("command -v #{tool} >/dev/null 2>&1")

        abort "\e[1;31mxx\e[0m missing required tool: #{tool} " \
              "(run scripts/setmeup.sh on a fresh host to install everything)"
      end

      # docker present but daemon unreachable is the #1 fresh-box gotcha: the
      # user was added to the 'docker' group but hasn't re-logged in yet.
      unless @cmd.run!('docker', 'info').success?
        abort "\e[1;31mxx\e[0m docker is installed but the daemon isn't reachable. " \
              "Is it running, and are you in the 'docker' group? " \
              "(try: sudo systemctl enable --now docker; newgrp docker)"
      end

      # build-all.sh uses `docker buildx build --load` and `docker compose`.
      # On Ubuntu these ship as SEPARATE packages (docker-buildx / docker-compose-v2)
      # that a bare `docker.io` install omits — catch that here, not mid-build.
      unless @opts[:no_build] || @cmd.run!('docker', 'buildx', 'version').success?
        abort "\e[1;31mxx\e[0m 'docker buildx' is unavailable but image build needs it. " \
              "Install the buildx plugin (apt: docker-buildx) or pass --no-build."
      end

      # The k3s backend installs k3s and imports images into its host containerd,
      # both of which need root. Prime sudo now (visible prompt) so the later
      # quiet, output-captured steps don't hang on a hidden password prompt.
      if @cluster_iface.needs_sudo? && !@publish_only && !system('sudo', '-v')
        abort "\e[1;31mxx\e[0m the k3s backend needs sudo (k3s install + containerd " \
              "image import). Grant sudo, or use the default --kube-backend=k3d."
      end
    end

    def ensure_infra
      env = {}
      if @registry
        env['REGISTRY_HOST'] = @registry_host
        env['REGISTRY_PORT'] = @registry_port
        env['REGISTRY_CA']   = @images.mkcert_ca_pem.to_s
      end
      @cluster_iface.ensure_infra(env: env)
    end

    def build_images
      components = @opts[:no_shell] ? %i[workspace control] : Carbide::Images::ALL
      log 'building the container images — on a cold cache this builds Ruby from ' \
          'source, so give it a few minutes (reticulating splines...)'
      @images.build(components: components, quiet: true)
    end

    # Build the PINNED SPA clients (the carbide2-client submodule's checked-out
    # SHA) and upload them to the MinIO static tier via scripts/build-client.
    # Two families are published from the same source, differing only by build
    # mode: 'workspace' (family carbide2-client, served by workspace pods) and
    # 'control' (family carbide2-control, the dashboard served by the control
    # pod). Neither is baked into any image — they live only in MinIO, served at
    # /clients/<family>/<sha>/, and the pod loaders resolve them at request
    # time. Runs after ensure_infra (which brings MinIO up) so the upload target
    # exists. --no-client skips it (e.g. redeploys that don't touch the client).
    def build_and_upload_client
      %w[workspace control].each do |mode|
        quiet_run("building + uploading the pinned '#{mode}' SPA client to the MinIO static tier",
                  File.join(@root, 'scripts', 'build-client'), '--mode', mode,
                  env: { 'CARBIDE_MINIO_NS' => @control_ns })
      end
    end

    # Image tagging, building, and registry lifecycle all live in the shared
    # Carbide::Images library (also used by scripts/build.rb).

    # Publish the freshly-built images so the cluster can pull them. Registry
    # mode pushes SHA tags to the standalone registry (works across every node);
    # legacy mode imports :dev into the single node's containerd.
    def publish_images
      @registry ? @images.push : @cluster_iface.import_images
    end

    # When every SHA tag is already in the registry there's nothing to build —
    # immutable tags mean identical content, so skip the (slow) build entirely.
    def skip_build?
      skip = @images.all_present?
      log "all image tags already in registry #{@registry_host}:#{@registry_port} — skipping build" if skip
      skip
    end

    def ensure_registry = @images.ensure_registry

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
          --ref REF          meta branch/ref to deploy (default main; e.g. --ref dev)
          --kube-backend k3s local k8s backend: k3d (default) or k3s (host-native)
          --registry-host H  push SHA-tagged images to a self-hosted registry at H
                             (multi-node: nodes pull from it; needs the CA trusted
                             per node via scripts/setmeup.sh --registry-host)
          --no-pull          skip self-update (git pull + submodule update)
          --no-build         skip image build (just re-import + redeploy)
          --no-client        skip building + uploading the pinned SPA client
          --no-infra         skip cluster/infra bring-up
          --no-tls           skip mkcert TLS setup (leave Traefik default cert)
          --roll-scope all   roll everything (default; coherent but drops terminals)
          --roll-scope control   roll control-plane only (keeps project terminals alive)
          --roll-scope none      skip rollouts (helm/CRD changes only)
      MSG
    end
  end
end

opts = { no_build: false, no_infra: false, no_tls: false, no_pull: false, csr: false, import_cert: nil, key: nil, roll_scope: nil, public_host: nil, ref: nil, kube_backend: nil, registry_host: nil, registry_port: nil, registry_ca: nil, publish_only: false, external_registry: false }
OptionParser.new do |o|
  o.banner = 'Usage: deploy.rb [--ref REF] [--kube-backend k3d|k3s] [--registry-host HOST] [--publish-only | --external-registry] [--no-pull] [--no-build] [--no-shell] [--no-client] [--no-infra] [--no-tls] [--roll-scope SCOPE] [--csr | --import-cert FILE]'
  o.on('--ref REF', 'Meta-repo branch/ref to deploy (default: main; DEPLOY_REF env). Checked out + fast-forwarded before build') { |v| opts[:ref] = v }
  o.on('--registry-host HOST', 'Enable registry mode: push SHA-tagged images to a self-hosted registry at HOST (REGISTRY_HOST env). Nodes pull from it — required for multi-node') { |v| opts[:registry_host] = v }
  o.on('--registry-port PORT', 'Registry port (default 5000; REGISTRY_PORT env)') { |v| opts[:registry_port] = v }
  o.on('--registry-ca FILE', 'CA (mkcert rootCA.pem) of an externally-run registry, so this node trusts it (REGISTRY_CA env). Required with --external-registry') { |v| opts[:registry_ca] = v }
  o.on('--publish-only', 'Build + push SHA-tagged images to the self-hosted registry, then exit. For the dedicated build/registry host (no k3s/helm). Needs --registry-host') { opts[:publish_only] = true }
  o.on('--external-registry', 'This k3s node pulls from a registry run elsewhere: skip the local registry + build. Needs --registry-host + --registry-ca') { opts[:external_registry] = true }
  o.on('--no-pull',  'Skip self-update (git pull + submodule update before deploy)') { opts[:no_pull] = true }
  o.on('--no-build', 'Skip image build (just re-import + redeploy)') { opts[:no_build] = true }
  o.on('--no-shell', 'Skip rebuilding the carbide2-shell image (reuse existing carbide2-shell:dev)') { opts[:no_shell] = true }
  o.on('--no-client', 'Skip building + uploading the pinned SPA client to the MinIO static tier') { opts[:no_client] = true }
  o.on('--no-infra', 'Skip cluster/infra bring-up')                  { opts[:no_infra] = true }
  o.on('--kube-backend BACKEND', %w[k3d k3s],
       'Local Kubernetes backend: k3d (default, k3s-in-Docker) or k3s (host-native)') { |v| opts[:kube_backend] = v }
  o.on('--no-tls',   'Skip mkcert TLS setup (Traefik default cert)')  { opts[:no_tls] = true }
  o.on('--public-host HOST', 'Browser-facing FQDN for ingress/cert/host-auth (default: hostname -f; localhost only for same-machine)') { |v| opts[:public_host] = v }
  o.on('--roll-scope SCOPE', %w[all control none],
       'Which deployments to roll: all (default), control, none') { |v| opts[:roll_scope] = v }
  o.on('--csr', 'Generate a private key + CSR (TLS_HOSTS/PUBLIC_HOST) in TLS_OUT_DIR, then exit') { opts[:csr] = true }
  o.on('--import-cert FILE', 'Load a CA-signed cert into TLS_SECRET as Traefik default, then exit') { |v| opts[:import_cert] = v }
  o.on('--key FILE', 'Private key for --import-cert (default: the .key from --csr in TLS_OUT_DIR)') { |v| opts[:key] = v }
  o.on('-h', '--help', 'Show this help') { puts o; exit 0 }
end.parse!(ARGV)

Carbide::Deploy.new(opts).run
