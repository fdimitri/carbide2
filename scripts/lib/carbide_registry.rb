# frozen_string_literal: true

require 'fileutils'
require 'tempfile'
require_relative 'carbide_command'

module Carbide
  # The self-hosted image registry as a FACT about the deployment (ADR-028 §1):
  # where it is, what CA signs its certificate, and whether THIS box runs it.
  # Identical on every node of a fleet except for `serve`.
  #
  # Extracted from Carbide::Images, which used to both build images and run the
  # registry as a side effect of building them. Images now takes one of these
  # (or nil) and only builds / pushes / imports; Node takes one and asks it for
  # the CA the node's containerd must trust.
  #
  # The CA (ADR-028 §1, "one field, three cases"):
  #   serve: true   -> the CA is mkcert's rootCA.pem on this box's disk; any
  #                    configured `ca` is ignored (with a warning upstream).
  #   serve: false  -> `ca` is the inline PEM a consumer trusts, or blank to
  #                    mean "the system trust store" (a publicly-signed registry).
  class Registry
    include Carbide::CommandRunner

    DEFAULT_PORT      = '5000'
    DEFAULT_CONTAINER = 'carbide-registry'
    CERT_DIR          = '~/.carbide/registry'

    # Config option specs owned by the registry (aggregated by deploy.rb).
    def self.options
      [
        { key: 'registry.mode', arg: 'MODE',
          desc: 'Registry flavour: generic (self-hosted registry:2) | gitlab (GitLab Container ' \
                'Registry). gitlab implies a namespace path, credentials, and no _catalog, and ' \
                'makes the build check the endpoint before pushing.' },
        { key: 'registry.host', arg: 'HOST',
          desc: 'Registry endpoint every node in the fleet pushes to / pulls from (blank => no registry)' },
        { key: 'registry.port', arg: 'PORT',
          desc: "Registry port. Blank omits it (e.g. an implicit-443 registry like GitLab) " \
                "(self-hosted default: #{DEFAULT_PORT})." },
        { key: 'registry.path', arg: 'PATH',
          desc: 'Repository namespace between host and image name, e.g. group/project for a ' \
                'GitLab registry. Blank for a flat registry. Becomes part of every repo name.' },
        { key: 'registry.repos', arg: 'LIST',
          desc: 'Comma-separated extra repo names control should list when the registry does ' \
                'not expose a catalog (GitLab). Blank = only the known carbide repos.' },
        { key: 'registry.catalog', arg: 'WHEN',
          desc: 'Whether the registry exposes /v2/_catalog: auto (probe, then fall back) | ' \
                'yes | no.' },
        { key: 'registry.username', arg: 'USER',
          desc: 'Registry username for push/pull (a GitLab deploy-token user / robot account). ' \
                'Blank = no auth (self-hosted) or an ambient docker login.' },
        { key: 'registry.password', arg: 'SECRET',
          desc: 'Registry password/token matching registry.username. SECRET.' },
        { key: 'registry.pull-secret', arg: 'NAME',
          desc: 'Name of an existing docker-registry Secret to use as imagePullSecret on ' \
                'workspace pods (GitLab). Alternative to handing control the credentials.' },
        { key: 'registry.ca', arg: 'PEM',
          desc: 'Inline CA PEM a consumer trusts (blank => system trust store; ignored when registry.serve)' },
        { key: 'registry.ca', long: 'registry.ca-file', arg: 'FILE', file: true,
          desc: 'Load registry.ca from a PEM file (the serving host\'s mkcert rootCA.pem)' },
        { key: 'registry.serve', negatable: true,
          desc: 'This box runs the registry:2 container (its cert is minted by mkcert here)' }
      ]
    end

    attr_reader :host, :port, :path, :username, :password, :pull_secret, :mode

    # cmd/quiet : streaming / capturing TTY::Command.
    # host      : registry hostname; nil/blank => not configured.
    # port      : registry port.
    # ca        : inline PEM (or a file path, from older configs) a consumer trusts.
    # serve     : this box runs the registry.
    def initialize(cmd:, quiet:, host:, port: DEFAULT_PORT, path: nil, ca: nil, serve: false,
                   username: nil, password: nil, pull_secret: nil, mode: 'generic',
                   container: DEFAULT_CONTAINER)
      @cmd   = cmd
      @quiet = quiet
      h = host.to_s.strip
      @host  = h.empty? ? nil : h
      # Blank port => omit it entirely (a registry with an implicit port, e.g.
      # GitLab on 443). Callers wanting the self-hosted default pass nothing or
      # DEFAULT_PORT.
      @port  = port.to_s.strip.empty? ? nil : port.to_s.strip
      pa    = path.to_s.strip.gsub(%r{\A/+|/+\z}, '')
      @path  = pa.empty? ? nil : pa
      c = ca.to_s.strip
      @ca    = c.empty? ? nil : c
      u = username.to_s.strip
      @username = u.empty? ? nil : u
      pw = password.to_s.strip
      @password = pw.empty? ? nil : pw
      ps = pull_secret.to_s.strip
      @pull_secret = ps.empty? ? nil : ps
      m = mode.to_s.strip.downcase
      @mode = m.empty? ? 'generic' : m
      @serve = serve ? true : false
      @container = container.to_s.strip.empty? ? DEFAULT_CONTAINER : container.to_s.strip
    end

    def configured? = !@host.nil?
    def auth?       = !@username.nil? && !@password.nil?

    def gitlab? = mode == 'gitlab'

    # Preflight: confirm the registry is reachable AND its certificate is
    # trusted from THIS host, so a build fails with a clear message instead of
    # mid-push. Deliberately no `-k`: a 200/401/403 means TLS validated; a 000
    # means connect or trust failed (the exact "not reachable or CA not trusted"
    # case). Requires registry.username/password to be set when the registry
    # needs auth, which is why build.rb calls login! first.
    def check!
      return nil unless configured?

      out, = @quiet.run!('curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', "#{base_url}/v2/")
      code = out.to_s.strip
      return nil if %w[200 401 403].include?(code)

      raise "registry #{endpoint}/v2/ is not reachable from this host, or its CA is not " \
            "trusted (curl #{code.empty? ? 'failed to connect' : "returned #{code}"}). " \
            "Import the registry's CA into the system trust store, then retry." if code == '000' || code.empty?

      raise "registry #{endpoint}/v2/ returned #{code}"
    end

    # GitLab registries always need a namespace (group/project) and credentials;
    # fail loudly rather than pushing to a wrong repo or getting a bare 401.
    def validate_mode!
      return unless gitlab?

      raise 'registry.mode=gitlab requires registry.path (e.g. group/project)' if @path.nil?
      raise 'registry.mode=gitlab requires registry.username/registry.password (a deploy token)' unless auth?
    end

    # Log docker in to the registry so push and `docker manifest inspect` use
    # the credential store. No-op without credentials (self-hosted). Idempotent.
    def login!
      return false unless auth?

      @cmd.run('docker', 'login', endpoint,
               '--username', @username, '--password-stdin',
               stdin: @password)
      true
    end
    def serve?      = @serve
    # "host[:port]" — the :port only when one is configured.
    def endpoint    = configured? ? (@port ? "#{@host}:#{@port}" : @host) : nil
    # Image-ref prefix ("host[:port]/[path]/"), or nil when no registry.
    def prefix      = configured? ? "#{endpoint}/#{@path ? "#{@path}/" : ''}" : nil
    def base_url    = configured? ? "https://#{endpoint}" : nil
    # Repository name for the v2 API and refs: the namespace is part of the repo
    # name (GitLab: host/v2/<path>/<repo>/…), NOT the base URL.
    def repo_name(name) = @path ? "#{@path}/#{name}" : name

    # Path to the CA PEM the pull side trusts, or nil for the system store.
    # serve: mkcert's root on this box. Otherwise the configured PEM, written to
    # a tempfile if it arrived inline (containerd and curl both want a path).
    def ca_path
      return @ca_path if defined?(@ca_path)

      @ca_path =
        if @serve
          mkcert_root
        elsif @ca.nil?
          nil
        elsif @ca.include?('-----BEGIN')
          write_ca_tempfile(@ca)
        elsif File.file?(File.expand_path(@ca))
          File.expand_path(@ca)
        end
    end

    # The CA PEM text, or '' when there is none to hand out. This is what
    # --yaml-out embeds so a consumer's config is self-contained, and what
    # control receives as REGISTRY_CA for its image picker.
    def ca_text
      path = ca_path
      return '' unless path && File.file?(path)

      File.read(path).strip
    rescue StandardError
      ''
    end

    # Bring up (or reuse) registry:2 on this box over TLS with an mkcert cert.
    # Idempotent. Only meaningful when serve?.
    def ensure!
      raise 'ensure! called on a registry this box does not serve' unless @serve
      raise 'ensure! called without registry.host' unless configured?

      log "ensuring standalone registry at #{endpoint}"
      dir = File.expand_path(CERT_DIR)
      crt = File.join(dir, 'registry.crt')
      key = File.join(dir, 'registry.key')
      ensure_cert(dir, crt, key)
      ensure_container(dir)
      verify!
    end

    # Attach the registry container to a Docker network under an alias equal to
    # registry.host, so a k3d node on that network resolves the name to the
    # container instead of to its own loopback (ADR-028 §5). Idempotent.
    def join_docker_network(network)
      raise 'join_docker_network on a registry this box does not serve' unless @serve

      nets, = @quiet.run!('docker', 'inspect', @container, '--format', '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')
      return log "registry already on docker network #{network}" if nets.to_s.split.include?(network)

      log "attaching registry container to docker network #{network} as #{@host}"
      @cmd.run('docker', 'network', 'connect', '--alias', @host, network, @container)
    end

    # Tag lookup, tri-state (ADR-043 §7): :present | :absent | :unreachable.
    #
    # Unreachable must never collapse into absent, or a registry that is down
    # reads as "absent, build it" — and on an authenticated registry it would do
    # so on every single invocation, because an anonymous `docker manifest
    # inspect` is answered with 401. That is also why login! has to have run
    # before this: auth failure is indistinguishable from a network failure here,
    # and both are correctly NOT absent.
    #
    # The classification is by message rather than by exit status because the
    # docker CLI collapses every failure into exit 1. Anything it does not say is
    # a missing manifest is treated as unreachable, which is the safe direction:
    # the cost of a false unreachable is a stopped command, the cost of a false
    # absent is a needless rebuild or a clobbered store.
    ABSENT_PATTERNS = [
      /manifest unknown/i,
      /MANIFEST_UNKNOWN/,
      /no such manifest/i,
      /not found/i,
      /manifest for .* not found/i
    ].freeze

    def detect(name, tag)
      return :unreachable unless configured?

      res = @quiet.run!('docker', 'manifest', 'inspect', "#{prefix}#{name}:#{tag}")
      return :present if res.success?

      message = "#{res.err}#{res.out}"
      ABSENT_PATTERNS.any? { |p| message.match?(p) } ? :absent : :unreachable
    rescue StandardError
      :unreachable
    end

    # True only for :present. Kept because Images and the deploy path ask a
    # boolean question ("may I skip this build?"), where absent and unreachable
    # both mean "do not skip".
    def has_manifest?(name, tag) = detect(name, tag) == :present

    # curl against the registry, trusting its CA when one is known.
    def curl(*args)
      cmd = ['curl']
      cmd += ['--cacert', ca_path] if ca_path
      @quiet.run!(*cmd, *args)
    end

    private

    def mkcert_root
      out, = @cmd.run!('mkcert', '-CAROOT')
      pem  = File.join((out || '').strip, 'rootCA.pem')
      File.exist?(pem) ? pem : nil
    end

    def write_ca_tempfile(pem)
      f = Tempfile.new(['carbide-registry-ca', '.pem'])
      f.write(normalize_pem(pem))
      f.write("\n")
      f.flush
      @ca_tempfile = f # keep a reference so the file outlives this method
      f.path
    end

    # A PEM pasted into a plain YAML scalar comes back with its newlines folded
    # to spaces. Re-wrap the base64 body at 64 columns.
    def normalize_pem(pem)
      s = pem.to_s.strip
      return s if s.include?("\n")

      m = s.match(/\A(-----BEGIN [^-]+-----)\s*(.*?)\s*(-----END [^-]+-----)\z/m)
      return s unless m

      body = m[2].gsub(/\s+/, '')
      [m[1], *body.scan(/.{1,64}/), m[3]].join("\n")
    end

    def ensure_cert(dir, crt, key)
      return if File.exist?(crt) && File.exist?(key)

      unless system('command -v mkcert >/dev/null 2>&1')
        abort "\e[1;31mxx mkcert not found.\e[0m It mints the registry's TLS cert " \
              '(and the CA nodes trust to pull). Install mkcert and retry.'
      end
      FileUtils.mkdir_p(dir)
      hosts = tls_hosts
      log "minting registry TLS cert via mkcert for: #{hosts.join(' ')}"
      @cmd.run('mkcert', '-cert-file', crt, '-key-file', key, *hosts)
    end

    def tls_hosts
      hosts = [@host, 'localhost', '127.0.0.1']
      ips, = @cmd.run!('hostname', '-I')
      hosts.concat((ips || '').strip.split)
      hosts.uniq
    end

    def ensure_container(dir)
      running, = @cmd.run!('docker', 'ps', '-q', '-f', "name=^#{@container}$")
      unless (running || '').strip.empty?
        log "registry container '#{@container}' already running \u2014 reusing"
        return
      end

      @quiet.run!('docker', 'rm', '-f', @container)
      log "starting registry:2 container '#{@container}' on :#{@port}"
      @cmd.run('docker', 'run', '-d', '--restart=always', '--name', @container,
               '-p', "#{@port}:5000",
               '-v', "#{dir}:/certs:ro",
               '-e', 'REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt',
               '-e', 'REGISTRY_HTTP_TLS_KEY=/certs/registry.key',
               'registry:2')
    end

    def verify!
      url = "#{base_url}/v2/"
      15.times do
        return if curl('-sf', '-o', '/dev/null', url).success?

        sleep 1
      end
      abort "\e[1;31mxx\e[0m registry did not become reachable at #{url}. Check " \
            "`docker logs #{@container}` and that the mkcert CA is trusted on this host."
    end
  end
end
