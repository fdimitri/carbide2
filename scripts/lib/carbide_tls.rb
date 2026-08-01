# frozen_string_literal: true

require 'tmpdir'
require 'tempfile'
require 'fileutils'

module Carbide
  # TLS/cert setup for the ingress, extracted from deploy.rb. Covers three
  # independent flows that all share the same secret/TLSStore plumbing:
  #   - setup_tls:            mint a locally-trusted mkcert cert (the default path)
  #   - generate_csr/import_cert: bring-your-own-CA (real cert) flow
  #   - trust_ca_instructions: the one manual "trust the CA in your browser" step
  #
  # It only shells out (kubectl/mkcert/openssl) via the injected TTY::Command
  # runner; it knows nothing about images, helm, or the cluster beyond the two
  # secrets it manages.
  class Tls
    # cmd         : a TTY::Command instance (pretty printer).
    # root        : meta-repo root (where carbide-rootCA.pem is exported).
    # public_host : browser-facing FQDN, added as a cert SAN / CSR CN.
    def initialize(cmd:, root:, public_host:)
      @cmd = cmd
      @root = root
      @public_host = public_host.to_s
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
    end

    # Tell the operator how to trust the signing CA on whatever machine runs the
    # browser — the ONE manual step wss:// needs. We export the public root next
    # to the repo as carbide-rootCA.pem (friendlier than mkcert's internal
    # rootCA.pem) so it's easy to copy/import. The browser machine is NOT
    # necessarily this host (someone on Windows/macOS/another Linux box may be
    # reaching the deploy by hostname), so we print steps for every platform
    # rather than guessing from the deploy host's OS. Called dead-last in run().
    def trust_ca_instructions
      caroot, = @cmd.run!('mkcert', '-CAROOT')
      caroot = (caroot || '').strip
      src = File.join(caroot, 'rootCA.pem')
      dest = File.expand_path('carbide-rootCA.pem', @root)
      FileUtils.cp(src, dest) if File.exist?(src)

      warn_ 'LAST STEP — trust the carbide root CA on the machine running your browser,'
      warn_ 'or the IDE WebSocket (wss://) silently fails even though the page loads.'
      warn_ "  root CA exported to: #{dest}"
      warn_ '  copy it to the browser machine (e.g. scp), then import for that OS:'
      warn_ ''
      warn_ '  Windows (Chromium/Edge use the Windows store; no admin needed):'
      warn_ '    certutil.exe -addstore -user -f Root carbide-rootCA.pem'
      if wsl?
        warn_ "    WSL: copy it across first — cp '#{dest}' /mnt/c/Users/Public/carbide-rootCA.pem"
        warn_ '         then run the certutil line above on C:\\Users\\Public\\carbide-rootCA.pem'
      end
      warn_ '    Firefox keeps its own store: Settings > Privacy & Security > Certificates > Import.'
      warn_ ''
      warn_ '  Linux (system trust — curl/node/etc.):'
      warn_ '    sudo cp carbide-rootCA.pem /usr/local/share/ca-certificates/carbide-rootCA.crt'
      warn_ '    sudo update-ca-certificates'
      warn_ '    Chrome/Chromium (NSS): certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n carbide -i carbide-rootCA.pem'
      warn_ ''
      warn_ '  macOS:'
      warn_ '    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain carbide-rootCA.pem'
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

    # Load a CA-signed cert (+ its key) into the TLS secret as Traefik's default.
    # key_path defaults to the single .key --csr left in TLS_OUT_DIR.
    def import_cert(cert_path, key_path: nil)
      unless system('command -v kubectl >/dev/null 2>&1')
        abort "\e[1;31mxx\e[0m kubectl not found — required to import the cert."
      end

      ns     = ENV.fetch('TRAEFIK_NS', 'traefik')
      secret = ENV.fetch('TLS_SECRET', 'carbide-tls')
      crt    = File.expand_path(cert_path)
      abort "\e[1;31mxx\e[0m cert not found: #{crt}" unless File.file?(crt)

      key = key_path ? File.expand_path(key_path) : default_csr_key
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

    private

    # True when running under WSL — the browser then lives on the Windows host,
    # so the CA must be trusted in Windows, not this Linux userland.
    def wsl?
      @wsl ||= File.exist?('/proc/version') &&
               File.read('/proc/version').match?(/microsoft/i)
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

    # The single .key left in TLS_OUT_DIR by --csr, when --key isn't given.
    def default_csr_key
      keys = Dir.glob(File.join(csr_dir, '*.key'))
      keys.first if keys.size == 1
    end

    def log(msg)  = puts("\e[1;34m==>\e[0m #{msg}")
    def warn_(msg) = warn("\e[1;33m!!\e[0m #{msg}")
  end
end
