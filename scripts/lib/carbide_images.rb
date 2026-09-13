# frozen_string_literal: true

require 'fileutils'
require 'time'
require 'yaml'
require_relative 'carbide_command'
require_relative 'carbide_release'
require_relative 'carbide_registry'
require_relative 'carbide_identity'
require_relative 'carbide_worktree'

module Carbide
  # Shared image logic for carcli and deploy.rb (ADR-028 §6, ADR-043).
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
  # Identity (what an artifact is called, and whether its tree is dirty) is
  # Carbide::Identity's: this class no longer computes shas. That matters beyond
  # tidiness — the image subjects gained dirty builds in ADR-043 §5, and a second
  # implementation of "what is this called" is exactly how the tag in the
  # registry and the tag in the helm release drift apart.
  #
  # It is a pure library: it takes injected TTY::Command runners (so the caller
  # controls verbosity — carcli streams, deploy.rb captures) and never sets up
  # gems or parses CLI itself. It knows nothing about kubernetes, helm, TLS, or
  # the client SPA; those stay in deploy.rb and Carbide::Client.
  #
  # Failures RAISE (Carbide::Images::Error) rather than abort. A library that
  # calls abort cannot be tested and cannot be given an exit code by its caller;
  # carcli maps these to the ADR-043 §3 exit codes and deploy.rb aborts on them.
  class Images
    include Carbide::CommandRunner

    Error = Class.new(StandardError)
    DirtyRefused = Class.new(Error)

    # Logical component -> image repository name. The workspace pod image is
    # historically just "carbide2".
    NAMES = { workspace: 'carbide2', control: 'carbide2-control', shell: 'carbide2-shell' }.freeze
    ALL   = NAMES.keys.freeze

    CONSUME_MODES = %w[auto import pull].freeze

    # cmd/quiet : TTY::Command instances (pretty/streaming and null/capturing).
    # root      : the meta-repo root (holds the submodule checkouts).
    # registry  : Carbide::Registry, or nil for local-only :dev tags.
    # identity  : Carbide::Identity; injectable for tests, built from root here.
    def initialize(cmd:, quiet:, root:, registry: nil, identity: nil)
      @cmd  = cmd
      @quiet = quiet
      @root  = root
      @server  = File.join(root, 'carbide2-server')
      @control = File.join(root, 'carbide2-control')
      @worker  = File.join(root, 'carbide2-worker')
      @client  = File.join(root, 'carbide2-client')
      @registry_obj = registry
      @registry = registry&.configured? ? registry.prefix : nil
      @identity = identity || Carbide::Identity.new(cmd: cmd, root: root)
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

    attr_reader :registry, :identity

    def registry_host = @registry_obj&.host
    def registry_port = @registry_obj&.port

    # The release manifest (manifest.yaml at the meta root) — authoritative
    # version + codename, stamped into every image as OCI labels + runtime env.
    # Sourced from Carbide::Release so images and anything else meta-versioned
    # read one place; the CLIENT, which versions independently, does not use this.
    def manifest         = Carbide::Release.manifest(@root)
    def release_version  = Carbide::Release.version(@root)
    def release_codename = Carbide::Release.codename(@root)

    # Committer date (UTC Zulu) of the last commit in `dir` at `rev`, optionally
    # limited to a path. Unlike build_time this is stable across rebuilds, so a
    # registry reader can tell which of two builds is genuinely newer.
    def commit_time(dir, path = nil, rev: 'HEAD')
      args = ['git', '-C', dir, 'log', '-1', '--format=%cI', rev]
      args += ['--', path] if path
      out, = @cmd.run!(*args)
      t = begin
        Time.iso8601((out || '').strip)
      rescue ArgumentError
        nil
      end
      t&.utc&.strftime('%Y-%m-%dT%H:%M:%SZ')
    end

    # Immutable per-component tags for the CURRENT working trees. Kept as a
    # no-argument public method because deploy.rb's control-plane install reads
    # it as a hash; ref-aware callers use tags_for.
    def image_tags = @image_tags ||= tags_for({})

    # Tags as they would be with these ref overrides applied. Workspace ships
    # server+worker so its tag is composite; shell is the content hash of
    # Dockerfile.shell, so a docs or app commit does not churn a ~4GB image.
    # A dirty tree yields <tag>-dirty (never for shell — see Carbide::Identity).
    def tags_for(refs)
      ALL.to_h { |component| [component, @identity.tag(component, refs: refs)] }
    end

    def dirty?(component, refs: {}) = @identity.dirty?(component, refs: refs)

    # Commit time per component. Workspace ships server+worker, so its stamp is
    # the NEWEST of the two (a change to either is a change to the image). Shell
    # is built purely from Dockerfile.shell, so it tracks that file's own commit,
    # matching its content-addressed tag.
    def commit_times(sources = nil)
      return @commit_times ||= commit_times_for(default_sources) if sources.nil?

      commit_times_for(sources)
    end

    # Registry-prefixed immutable ref for a component (host:port/name:sha). Falls
    # back to the local :dev ref when there's no registry.
    def image_ref(component, tags = image_tags)
      return local_ref(component) unless @registry

      "#{@registry}#{NAMES.fetch(component)}:#{tags.fetch(component)}"
    end

    # The always-built local tag (the k3d/k3s containerd-import path uses these).
    def local_ref(component) = "#{NAMES.fetch(component)}:dev"

    # Registry-prefixed repository (no tag), for callers like helm that take
    # image.repository and image.tag as separate values. Nil registry => bare name.
    def repository(component) = "#{@registry}#{NAMES.fetch(component)}"

    # Build the requested components and, when push: true and a registry is
    # configured, push each.
    #
    # Refs are materialized in DETACHED WORKTREES for the duration of the build
    # (ADR-043 §5), not checked out in place: an explicit ref is pristine by
    # construction, two builds on one host cannot collide, and an aborted build
    # cannot leave a submodule detached. A bare build uses the working tree as it
    # stands, dirty and all, because you should not have to commit to build.
    #
    # force: false skips any component whose registry ref already exists (tags
    # are immutable, so an existing tag is identical content). A DIRTY tag is
    # never skipped on presence: <sha>-dirty names a class of tree, not an
    # instance, so its presence is not information.
    def build(components: ALL, refs: {}, push: false, force: false, quiet: true,
              allow_dirty: false)
      tags = tags_for(refs)
      guard_dirty!(components, tags, refs, allow_dirty)
      built = {}
      with_sources(refs) do |sources|
        ensure_registry! if push && @registry
        times = commit_times(sources)
        components.each do |component|
          ref = image_ref(component, tags)
          if skip_present?(component, ref, tags, force)
            log "skipping #{component}: #{ref} already in registry (use --force-rebuild)"
            built[component] = ref
            next
          end
          build_component(component, sources: sources, tags: tags, times: times, quiet: quiet)
          built[component] = ref
          push_one(ref, dirty: dirty_tag?(tags[component]), allow_dirty: allow_dirty) if push && @registry
        end
      end
      built
    end

    # Push already-built components to the registry (no build). Used by deploy.rb
    # when it built earlier in the same process (no ref override in play).
    def push(components: ALL, allow_dirty: false)
      raise Error, 'push called without a registry' unless @registry

      # Gate before touching the network: a push that is going to be refused
      # should not first start a registry container or wait out a TLS timeout.
      tags = image_tags
      guard_dirty!(components, tags, {}, allow_dirty)
      ensure_registry!
      components.each do |component|
        push_one(image_ref(component, tags),
                 dirty: dirty_tag?(tags[component]), allow_dirty: allow_dirty)
      end
    end

    # True when every requested component's registry ref already exists — so the
    # (slow) build can be skipped entirely (immutable tags => identical content).
    # A dirty tag is never "already present" in any useful sense, so a dirty tree
    # never reports all-present.
    def all_present?(components = ALL)
      return false unless @registry

      tags = image_tags
      components.all? do |component|
        !dirty_tag?(tags[component]) && in_registry?(image_ref(component, tags))
      end
    end

    # present / absent / unreachable (ADR-043 §7). Unreachable is never collapsed
    # into absent: "the registry is down" must not read as "build it".
    def detect(component, refs: {})
      return :unreachable unless @registry

      tags = refs.empty? ? image_tags : tags_for(refs)
      name, tag = split_ref(image_ref(component, tags))
      @registry_obj.detect(name, tag)
    end

    # True if <name>:<tag> already exists in the registry.
    def in_registry?(ref)
      return false unless @registry

      name, tag = split_ref(ref)
      @registry_obj.has_manifest?(name, tag)
    end

    private

    def default_sources
      { server: @server, worker: @worker, control: @control, client: @client }
    end

    def dirty_tag?(tag) = tag.to_s.end_with?('-dirty')

    def split_ref(ref) = ref.sub(@registry, '').split(':', 2)

    # Presence is only a trustworthy skip signal for a content-addressed tag.
    def skip_present?(component, ref, tags, force)
      return false if force || !@registry || dirty_tag?(tags[component])

      in_registry?(ref)
    end

    # The build-dirty gate (ADR-043 §5). Building writes nothing, so the gate is
    # not about danger: the tag class is a classification that decides whether
    # detect means anything, whether auto applies, and whether a push is allowed
    # downstream. Deriving that silently from `git status` is the one
    # consequential inference this tool would make without saying so.
    def guard_dirty!(components, tags, refs, allow_dirty)
      return if allow_dirty

      dirty = components.select { |c| dirty_tag?(tags[c]) }
      return if dirty.empty?

      detail = dirty.map { |c| "#{c} (#{describe_dirty(c, refs)})" }.join(', ')
      raise DirtyRefused,
            "refusing to build from a dirty tree: #{detail}. " \
            'Pass --allow-dirty to build it as <sha>-dirty.'
    end

    # Which half of a composite is dirty is the thing you actually want in the
    # message; the tag deliberately does not carry it.
    def describe_dirty(component, refs)
      state = @identity.state(component, refs: refs)
      return "#{state[:sha]} dirty" unless component == :workspace

      %i[server worker].select { |half| state[half][:dirty] }
                       .map { |half| "#{half} dirty" }.join(' + ')
    end

    # A push needs the registry up. Only the box that serves it can bring it up;
    # a box pushing to someone else's registry just needs it reachable.
    def ensure_registry!
      @registry_obj.serve? ? @registry_obj.ensure! : @registry_obj.check!
    rescue StandardError => e
      raise Error, e.message
    end

    # ONE build_time per invocation, used for both the OCI label and the runtime
    # env build arg. Computing it twice let the label and the env disagree by a
    # second, so the same image reported two build times depending which you read.
    def build_time = @build_time ||= Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

    def commit_times_for(sources)
      {
        workspace: [commit_time(sources[:server]), commit_time(sources[:worker])].compact.max,
        control:   commit_time(sources[:control]),
        shell:     commit_time(sources[:server], 'Dockerfile.shell')
      }
    end

    # Yield the directory each component builds from: its submodule checkout, or
    # a detached worktree when a ref was given for it. Nested so that several ref
    # overrides compose, and so every worktree is removed on the way out however
    # the block leaves.
    def with_sources(refs, &block)
      pending = normalize_refs(refs)
      materialize(pending.keys, pending, default_sources, &block)
    end

    def materialize(keys, refs, sources, &block)
      return block.call(sources) if keys.empty?

      key  = keys.first
      repo = sources.fetch(key)
      sha  = @identity.resolve(key, refs.fetch(key))
      log "materializing #{key} @ #{sha[0, 12]} in a detached worktree"
      Carbide::Worktree.with(cmd: @cmd, repo: repo, sha: sha) do |path|
        materialize(keys[1..], refs, sources.merge(key => path), &block)
      end
    end

    def normalize_refs(refs)
      (refs || {}).each_with_object({}) do |(k, v), out|
        next if v.nil? || v.to_s.strip.empty?

        key = k.to_sym
        next unless default_sources.key?(key)

        out[key] = v.to_s.strip
      end
    end

    # Always tags the local :dev ref and additionally the registry SHA ref when a
    # registry is set. The release version/codename are stamped in as both build
    # args (persisted as runtime env by the Dockerfiles) and OCI labels (visible
    # in the registry).
    #
    # The *_SHA build args are commit provenance and stay bare 12-char shas even
    # on a dirty build; dirtiness lives in the tag, which is the thing that has
    # to stay distinguishable in a store.
    def build_component(component, sources:, tags:, times:, quiet:)
      refs = ['-t', local_ref(component)]
      refs += ['-t', image_ref(component, tags)] if @registry
      server = sources.fetch(:server)
      meta = ["META_SHA=#{head_short(@root)}", "CLIENT_SHA=#{head_short(sources.fetch(:client))}",
              "BUILD_TIME=#{build_time}",
              "VERSION=#{release_version}", "CODENAME=#{release_codename}"]
      labels = metadata_labels(component, times)
      case component
      when :workspace
        run_build(quiet, 'docker', 'buildx', 'build', '--load', *refs, *labels,
                  *build_args(*meta, "SERVER_SHA=#{head_short(server)}",
                              "WORKER_SHA=#{head_short(sources.fetch(:worker))}"),
                  '--build-context', "worker=#{sources.fetch(:worker)}", server)
      when :control
        control = sources.fetch(:control)
        run_build(quiet, 'docker', 'buildx', 'build', '--load', *refs, *labels,
                  *build_args(*meta, "CONTROL_SHA=#{head_short(control)}"), control)
      when :shell
        run_build(quiet, 'docker', 'buildx', 'build', '--load', *refs, *labels,
                  *build_args("VERSION=#{release_version}", "CODENAME=#{release_codename}"),
                  '-f', File.join(server, 'Dockerfile.shell'), server)
      else
        raise ArgumentError, "unknown component: #{component.inspect}"
      end
    end

    # HEAD of an arbitrary directory — the meta repo, and the resolved source
    # dirs (which may be worktrees, where HEAD is the pinned commit). Component
    # identity is Carbide::Identity's; this is only the provenance stamp.
    def head_short(dir)
      out, = @cmd.run!('git', '-C', dir, 'rev-parse', '--short=12', 'HEAD')
      (out || '').strip
    end

    def build_args(*pairs) = pairs.flat_map { |p| ['--build-arg', p] }

    # OCI labels so the registry's image manifest (config.Labels) is
    # self-describing without running the image: the release version + codename
    # (from manifest.yaml — the meta release, which the images DO track) plus
    # this component's build_time and commit_time. Every artifact exposes the
    # same four keys, so a reader uses one interface regardless of artifact.
    # Empty values are omitted.
    def metadata_labels(component, times)
      out = []
      add = lambda do |key, val|
        out += ['--label', "org.carbide.#{key}=#{val}"] unless val.to_s.empty?
      end
      add.call('version',    release_version)
      add.call('codename',   release_codename)
      add.call('build_time', build_time)
      add.call('commit_time', times[component])
      out
    end

    # Run a build either streaming (carcli: the user watches progress) or
    # captured (deploy.rb: surface output only on failure).
    def run_build(quiet, *args)
      return @cmd.run(*args) unless quiet

      res = @quiet.run!(*args)
      return res if res.success?

      $stdout.write(res.out)
      $stderr.write(res.err)
      raise Error, "build failed (output above): #{args.last}"
    end

    def push_one(ref, dirty: false, allow_dirty: false)
      # The push-dirty gate lives HERE rather than only in the CLI, so a caller
      # that bypasses the wrapper cannot seed a shared store with an artifact
      # nobody can identify.
      if dirty && !allow_dirty
        raise DirtyRefused, "refusing to push #{ref}: a -dirty tag names a class of " \
                            'working tree, not a build. Pass --allow-dirty if you mean it.'
      end

      if !dirty && in_registry?(ref)
        log "  skip #{ref} (already in registry)"
        return
      end

      unless @quiet.run!('docker', 'image', 'inspect', ref).success?
        raise Error, "#{ref} not present locally — build it first, then re-run. " \
                     'Refusing to publish a tag the cluster will ImagePullBackOff on.'
      end
      log "  push #{ref}"
      res = @quiet.run!('docker', 'push', ref)
      return if res.success?

      $stdout.write(res.out)
      $stderr.write(res.err)
      raise Error, "docker push failed for #{ref} (output above)."
    end
  end
end
