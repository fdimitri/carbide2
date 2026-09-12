# frozen_string_literal: true

require 'fileutils'
require 'time'
require 'yaml'
require_relative 'carbide_command'
require_relative 'carbide_release'
require_relative 'carbide_registry'

module Carbide
  # Shared image logic for build.rb and deploy.rb (ADR-028 §6).
  #
  # Owns exactly one thing: turning the meta-repo's submodule checkouts into
  # immutable, SHA-tagged container images and (optionally) pushing them to a
  # registry. It is the single source of truth for how the three carbide images
  # are tagged and built — previously that logic was duplicated between
  # scripts/build-all.sh (bash) and scripts/deploy.rb (ruby), which drifted.
  #
  # The registry itself — its coordinates, CA, cert, and container — is a
  # Carbide::Registry handed in at construction. Images never runs one.
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

    CONSUME_MODES = %w[auto import pull].freeze

    # cmd/quiet : TTY::Command instances (pretty/streaming and null/capturing).
    # root      : the meta-repo root (holds the submodule checkouts).
    # registry  : Carbide::Registry, or nil for local-only :dev tags.
    def initialize(cmd:, quiet:, root:, registry: nil)
      @cmd  = cmd
      @quiet = quiet
      @root  = root
      @server  = File.join(root, 'carbide2-server')
      @control = File.join(root, 'carbide2-control')
      @worker  = File.join(root, 'carbide2-worker')
      @client  = File.join(root, 'carbide2-client')
      @registry_obj = registry
      @registry = registry&.configured? ? registry.prefix : nil
    end

    # Config option specs owned by the image lifecycle (aggregated by deploy.rb).
    def self.options
      [
        { key: 'images.build', negatable: true,
          desc: 'Build the container images (--no-images.build to redeploy what exists)' },
        { key: 'images.shell', negatable: true,
          desc: 'Include carbide2-shell in the build (slow, large; --no-images.shell reuses the existing one)' },
        { key: 'images.push', negatable: true,
          desc: 'Push SHA-tagged images to registry.host (implies build)' },
        { key: 'images.consume', arg: 'MODE', values: CONSUME_MODES,
          desc: "How this box's own cluster gets images: auto (k3d/single k3s import :dev; multi-node pulls), import, pull" }
      ]
    end

    attr_reader :registry

    def registry_host = @registry_obj&.host
    def registry_port = @registry_obj&.port

    # The release manifest (manifest.yaml at the meta root) — authoritative
    # version + codename, stamped into every image as OCI labels + runtime env.
    # Sourced from Carbide::Release so images and anything else meta-versioned
    # read one place; the CLIENT, which versions independently, does not use this
    # (see scripts/build-client).
    def manifest         = Carbide::Release.manifest(@root)
    def release_version  = Carbide::Release.version(@root)
    def release_codename = Carbide::Release.codename(@root)

    # 12-char short SHA of the checkout in `dir` (matches build-all.sh).
    def short_sha(dir)
      out, = @cmd.run!('git', '-C', dir, 'rev-parse', '--short=12', 'HEAD')
      (out || '').strip
    end

    # Committer date (UTC Zulu) of the last commit in `dir` (optionally limited
    # to a path). This is the artifact's "when did the source last move" stamp —
    # unlike build_time it is stable across rebuilds, so a registry reader can
    # tell which of two builds of the same tag is genuinely newer.
    def commit_time(dir, path = nil)
      args = ['git', '-C', dir, 'log', '-1', '--format=%cI']
      args += ['--', path] if path
      out, = @cmd.run!(*args)
      t = begin
        Time.iso8601((out || '').strip)
      rescue ArgumentError
        nil
      end
      t&.utc&.strftime('%Y-%m-%dT%H:%M:%SZ')
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

    # Commit time per component. Workspace ships server+worker, so its stamp is
    # the NEWEST of the two (a change to either is a change to the image). Shell
    # is built purely from Dockerfile.shell, so it tracks that file's own commit,
    # matching its content-addressed tag. with_refs resets the memo.
    def commit_times
      @commit_times ||= {
        workspace: [commit_time(@server), commit_time(@worker)].compact.max,
        control:   commit_time(@control),
        shell:     commit_time(@server, 'Dockerfile.shell')
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
        ensure_registry! if push && @registry
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

      ensure_registry!
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
      @registry_obj.has_manifest?(name, tag)
    end

    private

    # A push needs the registry up. Only the box that serves it can bring it up;
    # a box pushing to someone else's registry just needs it reachable.
    def ensure_registry!
      @registry_obj.serve? ? @registry_obj.ensure! : verify_reachable!
    end

    # Delegate to the registry's own check. The previous inline `curl -sf` treated
    # HTTP 401 as failure, so an authenticated registry (GitLab, or any registry
    # that challenges /v2/) was reported as "not reachable" even though it was
    # answering. check! accepts 200/401/403 (reachable AND TLS validated) and only
    # fails on a connect/TLS error (000).
    def verify_reachable!
      @registry_obj.check!
    rescue StandardError => e
      abort "\e[1;31mxx\e[0m #{e.message}"
    end

    def build_time = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

    # Faithfully mirrors build-all.sh's three buildx invocations. Always tags the
    # local :dev ref and additionally the registry SHA ref when a registry is set.
    # The release version/codename are stamped in as both build args (persisted
    # as runtime env by the Dockerfiles) and OCI labels (visible in the registry).
    def build_component(component, quiet:)
      tags = ['-t', local_ref(component)]
      tags += ['-t', image_ref(component)] if @registry
      meta = ["META_SHA=#{short_sha(@root)}", "CLIENT_SHA=#{short_sha(@client)}",
              "BUILD_TIME=#{build_time}",
              "VERSION=#{release_version}", "CODENAME=#{release_codename}"]
      labels = metadata_labels(component)
      case component
      when :workspace
        run_build(quiet, 'docker', 'buildx', 'build', '--load', *tags, *labels,
                  *build_args(*meta, "SERVER_SHA=#{short_sha(@server)}",
                              "WORKER_SHA=#{short_sha(@worker)}"),
                  '--build-context', "worker=#{@worker}", @server)
      when :control
        run_build(quiet, 'docker', 'buildx', 'build', '--load', *tags, *labels,
                  *build_args(*meta, "CONTROL_SHA=#{short_sha(@control)}"), @control)
      when :shell
        run_build(quiet, 'docker', 'buildx', 'build', '--load', *tags, *labels,
                  *build_args("VERSION=#{release_version}", "CODENAME=#{release_codename}"),
                  '-f', File.join(@server, 'Dockerfile.shell'), @server)
      else
        raise ArgumentError, "unknown component: #{component.inspect}"
      end
    end

    def build_args(*pairs) = pairs.flat_map { |p| ['--build-arg', p] }

    # OCI labels so the registry's image manifest (config.Labels) is
    # self-describing without running the image: the release version + codename
    # (from manifest.yaml — the meta release, which the images DO track) plus
    # this component's build_time and commit_time. Every artifact exposes the
    # same four keys, so a reader uses one interface regardless of artifact.
    # Empty values are omitted.
    def metadata_labels(component)
      out = []
      add = lambda do |key, val|
        out += ['--label', "org.carbide.#{key}=#{val}"] unless val.to_s.empty?
      end
      add.call('version',    release_version)
      add.call('codename',   release_codename)
      add.call('build_time', build_time)
      add.call('commit_time', commit_times[component])
      out
    end

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
      @commit_times = nil
      yield
    ensure
      originals&.each do |dir, sha|
        next if sha.empty?

        @cmd.run!('git', '-C', dir, 'checkout', sha)
      end
      @image_tags = nil
      @commit_times = nil
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
  end
end
