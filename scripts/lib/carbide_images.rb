# frozen_string_literal: true

require 'fileutils'
require_relative 'carbide_command'

module Carbide
  # Shared image/registry logic for build.rb and deploy.rb.
  #
  # Owns exactly one thing: turning the meta-repo's submodule checkouts into
  # immutable, SHA-tagged container images and (optionally) getting them into a
  # self-hosted registry. It is the single source of truth for how the three
  # carbide images are tagged and built — previously that logic was duplicated
  # between scripts/build-all.sh (bash) and scripts/deploy.rb (ruby), which
  # drifted. Both callers now go through here.
  #
  # It is a pure library: it takes injected TTY::Command runners (so the caller
  # controls verbosity — build.rb streams, deploy.rb captures) and never sets up
  # gems or parses CLI itself. It knows nothing about kubernetes, helm, TLS, or
  # the client SPA; those stay in deploy.rb.
  class Images
    include Carbide::CommandRunner

    # Logical component -> image repository name. The workspace pod image is
    # historically just "carbide2".
    NAMES = { workspace: 'carbide2', control: 'carbide2-control', shell: 'carbide2-shell' }.freeze
    ALL   = NAMES.keys.freeze

    # cmd/quiet   : TTY::Command instances (pretty/streaming and null/capturing).
    # root        : the meta-repo root (holds the submodule checkouts).
    # registry_*  : self-hosted registry coordinates; host nil => local-only :dev.
    # registry_ca : an externally-run registry's CA pem (preferred over mkcert).
    # registry_container : docker container name for the local registry:2.
    def initialize(cmd:, quiet:, root:, registry_host: nil, registry_port: '5000',
                   registry_ca: nil, registry_container: 'carbide-registry')
      @cmd  = cmd
      @quiet = quiet
      @root  = root
      @server  = File.join(root, 'carbide2-server')
      @control = File.join(root, 'carbide2-control')
      @worker  = File.join(root, 'carbide2-worker')
      @client  = File.join(root, 'carbide2-client')
      host = registry_host&.strip
      host = nil if host&.empty?
      @registry_host = host
      @registry_port = registry_port.to_s
      @registry      = host ? "#{host}:#{@registry_port}/" : nil
      ca = registry_ca&.strip
      @registry_ca = (ca && !ca.empty?) ? ca : nil
      container = registry_container.to_s.strip
      @registry_container = container.empty? ? 'carbide-registry' : container
    end

    # Config option specs owned by the image/registry layer (aggregated by deploy.rb).
    def self.options
      [
        { key: 'registry.host', arg: 'HOST',
          desc: 'Registry mode: push SHA-tagged images to a self-hosted registry at HOST (blank => single-node containerd import). Required for multi-node' },
        { key: 'registry.port', arg: 'PORT', desc: 'Registry port (default: 5000)' },
        { key: 'registry.ca', arg: 'PEM', desc: 'Inline CA PEM of an externally-run registry, so this node trusts it' },
        { key: 'registry.ca', long: 'registry.ca-file', arg: 'FILE', file: true,
          desc: 'Load registry.ca from a PEM file (mkcert rootCA.pem of the build host)' },
        { key: 'registry.container', arg: 'NAME', desc: 'Local registry:2 container name (default: carbide-registry)' },
        { key: 'registry.publish-only', long: 'publish-only', desc: 'Build + push SHA-tagged images to the registry, then exit (dedicated build/registry host). Needs registry.host' },
        { key: 'registry.external', long: 'external-registry', desc: 'This node pulls from a registry run elsewhere: skip the local registry + build. Needs registry.host + registry.ca' }
      ]
    end

    attr_reader :registry, :registry_host, :registry_port

    # 12-char short SHA of the checkout in `dir` (matches build-all.sh).
    def short_sha(dir)
      out, = @cmd.run!('git', '-C', dir, 'rev-parse', '--short=12', 'HEAD')
      (out || '').strip
    end

    # 12-char git blob hash of a single file's contents. Used to tag an image
    # whose only build input is that file, so unrelated repo commits (docs, app
    # code) don't churn its tag and force a needless rebuild.
    def blob_sha(path)
      out, = @cmd.run!('git', 'hash-object', path)
      (out || '').strip[0, 12]
    end

    # Immutable per-component tags. Workspace ships server+worker, so its tag is
    # composite; control tracks its own repo. The shell image is built purely
    # from Dockerfile.shell (it COPYs nothing from the repo and takes no build
    # args), so it's tagged by that file's content — not the server repo SHA —
    # so a docs/app commit doesn't rebuild it. with_refs resets the memo.
    def image_tags
      @image_tags ||= {
        workspace: "#{short_sha(@server)}-#{short_sha(@worker)}",
        control:   short_sha(@control),
        shell:     blob_sha(File.join(@server, 'Dockerfile.shell'))
      }
    end

    # Registry-prefixed immutable ref for a component (host:port/name:sha). Falls
    # back to the local :dev ref when there's no registry.
    def image_ref(component)
      return local_ref(component) unless @registry

      "#{@registry}#{NAMES.fetch(component)}:#{image_tags.fetch(component)}"
    end

    # The always-built local tag (the k3d/k3s containerd-import path uses these).
    def local_ref(component) = "#{NAMES.fetch(component)}:dev"

    # Registry-prefixed repository (no tag), for callers like helm that take
    # image.repository and image.tag as separate values. Nil registry => bare name.
    def repository(component) = "#{@registry}#{NAMES.fetch(component)}"

    # Build the requested components (default all) and, when push: true and a
    # registry is configured, push each to it. Build and push happen inside the
    # same with_refs block so the tags pushed are exactly the tags built even
    # when refs: overrides temporarily check out other SHAs. Returns a map of
    # component => the ref that was produced (registry ref when pushing/registry
    # mode, else the local :dev ref), for the caller to print.
    #
    # force: false skips any component whose registry ref already exists (tags
    # are immutable, so an existing tag is identical content) — this check is
    # inside with_refs so it uses the same SHAs that would be built.
    def build(components: ALL, refs: {}, push: false, force: false, quiet: true)
      built = {}
      with_refs(refs) do
        ensure_registry if push && @registry
        components.each do |component|
          ref = image_ref(component)
          if !force && @registry && in_registry?(ref)
            log "skipping #{component}: #{ref} already in registry (use --force-rebuild)"
            built[component] = ref
            next
          end
          build_component(component, quiet: quiet)
          built[component] = ref
          push_one(ref) if push && @registry
        end
      end
      built
    end

    # Push already-built components to the registry (no build). Used by deploy.rb
    # when it built earlier in the same process (no ref override in play).
    def push(components: ALL)
      raise 'push called without a registry' unless @registry

      ensure_registry
      components.each { |component| push_one(image_ref(component)) }
    end

    # True when every requested component's registry ref already exists — so the
    # (slow) build can be skipped entirely (immutable tags => identical content).
    def all_present?(components = ALL)
      return false unless @registry

      components.all? { |component| in_registry?(image_ref(component)) }
    end

    # True if <name>:<tag> already exists in the registry (GET of the manifest).
    def in_registry?(ref)
      return false unless @registry

      name, tag = ref.sub(@registry, '').split(':', 2)
      url = "https://#{@registry_host}:#{@registry_port}/v2/#{name}/manifests/#{tag}"
      registry_curl('-sf', '-o', '/dev/null',
                    '-H', 'Accept: application/vnd.docker.distribution.manifest.v2+json',
                    url).success?
    end

    # Resolve the CA pem that signs the registry's TLS cert: an externally-run
    # registry supplies it explicitly; otherwise fall back to the local mkcert
    # CAROOT. Returns nil when neither is available.
    def mkcert_ca_pem
      return @mkcert_ca if defined?(@mkcert_ca)
      return @mkcert_ca = @registry_ca if @registry_ca && File.exist?(@registry_ca)

      out, = @cmd.run!('mkcert', '-CAROOT')
      pem  = File.join((out || '').strip, 'rootCA.pem')
      @mkcert_ca = File.exist?(pem) ? pem : nil
    end

    # Bring up (or reuse) a standalone registry:2 on this host over TLS. The cert
    # reuses the carbide mkcert root CA, so nodes that already trust that CA can
    # pull without extra config. Idempotent.
    def ensure_registry
      log "ensuring standalone registry at #{@registry_host}:#{@registry_port}"
      dir = File.expand_path('~/.carbide/registry')
      crt = File.join(dir, 'registry.crt')
      key = File.join(dir, 'registry.key')
      ensure_registry_cert(dir, crt, key)
      ensure_registry_container(dir)
      verify_registry
    end

    private

    def build_time = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

    # Faithfully mirrors build-all.sh's three buildx invocations. Always tags the
    # local :dev ref and additionally the registry SHA ref when a registry is set.
    def build_component(component, quiet:)
      tags = ['-t', local_ref(component)]
      tags += ['-t', image_ref(component)] if @registry
      meta = ["META_SHA=#{short_sha(@root)}", "CLIENT_SHA=#{short_sha(@client)}",
              "BUILD_TIME=#{build_time}"]
      case component
      when :workspace
        run_build(quiet, 'docker', 'buildx', 'build', '--load', *tags,
                  *build_args(*meta, "SERVER_SHA=#{short_sha(@server)}",
                              "WORKER_SHA=#{short_sha(@worker)}"),
                  '--build-context', "worker=#{@worker}", @server)
      when :control
        run_build(quiet, 'docker', 'buildx', 'build', '--load', *tags,
                  *build_args(*meta, "CONTROL_SHA=#{short_sha(@control)}"), @control)
      when :shell
        run_build(quiet, 'docker', 'buildx', 'build', '--load', *tags,
                  '-f', File.join(@server, 'Dockerfile.shell'), @server)
      else
        raise ArgumentError, "unknown component: #{component.inspect}"
      end
    end

    def build_args(*pairs) = pairs.flat_map { |p| ['--build-arg', p] }

    # Run a build either streaming (build.rb: user watches progress; raises on
    # failure) or captured (deploy.rb: surface output only on failure).
    def run_build(quiet, *args)
      return @cmd.run(*args) unless quiet

      res = @quiet.run!(*args)
      return res if res.success?

      $stdout.write(res.out)
      $stderr.write(res.err)
      abort "\e[1;31mxx\e[0m build failed (output above): #{args.last}"
    end

    # Check out the given refs in their submodules for the duration of the block,
    # restoring each checkout's original HEAD afterwards. refs is a map of
    # component-ish key => git ref, e.g. {server: 'feat/x', worker: '<sha>'}.
    # The image-tag memo is reset around the swap so tags reflect the active SHAs.
    def with_refs(refs)
      refs = (refs || {}).reject { |_, v| v.nil? || v.to_s.strip.empty? }
      return yield if refs.empty?

      dirs = { server: @server, control: @control, worker: @worker, client: @client }
      originals = {}
      refs.each do |key, ref|
        dir = dirs.fetch(key.to_sym)
        orig, = @cmd.run!('git', '-C', dir, 'rev-parse', 'HEAD')
        originals[dir] = (orig || '').strip
        log "checkout #{key} @ #{ref}"
        @cmd.run('git', '-C', dir, 'checkout', ref)
      end
      @image_tags = nil
      yield
    ensure
      originals&.each do |dir, sha|
        next if sha.empty?

        @cmd.run!('git', '-C', dir, 'checkout', sha)
      end
      @image_tags = nil
    end

    def push_one(ref)
      if in_registry?(ref)
        log "  skip #{ref} (already in registry)"
        return
      end
      unless @quiet.run!("docker image inspect #{ref}").success?
        abort "\e[1;31mxx\e[0m #{ref} not present locally \u2014 build it first, then " \
              "re-run. Refusing to publish a tag the cluster will ImagePullBackOff on."
      end
      log "  push #{ref}"
      res = @quiet.run!('docker', 'push', ref)
      return if res.success?

      $stdout.write(res.out)
      $stderr.write(res.err)
      abort "\e[1;31mxx\e[0m docker push failed for #{ref} (output above)."
    end

    def registry_curl(*args)
      cmd = ['curl']
      cmd += ['--cacert', mkcert_ca_pem] if mkcert_ca_pem
      @quiet.run!(*cmd, *args)
    end

    def ensure_registry_cert(dir, crt, key)
      return if File.exist?(crt) && File.exist?(key)

      unless system('command -v mkcert >/dev/null 2>&1')
        abort "\e[1;31mxx mkcert not found.\e[0m It mints the registry's TLS cert " \
              "(and the CA nodes trust to pull). Install mkcert and retry."
      end
      FileUtils.mkdir_p(dir)
      hosts = registry_tls_hosts
      log "minting registry TLS cert via mkcert for: #{hosts.join(' ')}"
      @cmd.run('mkcert', '-cert-file', crt, '-key-file', key, *hosts)
    end

    def registry_tls_hosts
      hosts = [@registry_host, 'localhost', '127.0.0.1']
      ips, = @cmd.run!('hostname', '-I')
      hosts.concat((ips || '').strip.split)
      hosts.uniq
    end

    def ensure_registry_container(dir)
      name = @registry_container
      running, = @cmd.run!('docker', 'ps', '-q', '-f', "name=^#{name}$")
      unless (running || '').strip.empty?
        log "registry container '#{name}' already running \u2014 reusing"
        return
      end

      @quiet.run!('docker', 'rm', '-f', name)
      log "starting registry:2 container '#{name}' on :#{@registry_port}"
      @cmd.run('docker', 'run', '-d', '--restart=always', '--name', name,
               '-p', "#{@registry_port}:5000",
               '-v', "#{dir}:/certs:ro",
               '-e', 'REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt',
               '-e', 'REGISTRY_HTTP_TLS_KEY=/certs/registry.key',
               'registry:2')
    end

    def verify_registry
      url = "https://#{@registry_host}:#{@registry_port}/v2/"
      15.times do
        return if registry_curl('-sf', '-o', '/dev/null', url).success?

        sleep 1
      end
      abort "\e[1;31mxx\e[0m registry did not become reachable at #{url}. Check " \
            "`docker logs carbide-registry` and that the mkcert CA is trusted on this host."
    end
  end
end
