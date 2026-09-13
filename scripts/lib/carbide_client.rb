# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'carbide_command'
require_relative 'carbide_identity'
require_relative 'carbide_worktree'

module Carbide
  # The client SPA as a carcli subject (ADR-043 §2): one source, two served
  # families, a registry cache and a per-cluster MinIO serving tier.
  #
  # ONE client source, TWO served families. The workspace SPA and the control
  # dashboard are the same carbide2-client source built with different
  # VITE_CARBIDE_MODE and an absolute Vite base of /clients/<family>/<sha>/.
  # They are built together and published together.
  #
  # FAMILIES is deliberately DATA, iterated everywhere — build, COPY, docker cp,
  # upload. When the SPA becomes one build with mode selected at runtime, the
  # change is deleting an element, not untangling two code paths.
  class Client
    include Carbide::CommandRunner

    Error = Class.new(StandardError)

    FAMILIES = [
      { mode: 'workspace', family: 'carbide2-client'  },
      { mode: 'control',   family: 'carbide2-control' }
    ].freeze

    NAME = 'carbide2-client'
    DEFAULT_NODE_IMAGE = 'node:22-alpine'

    def self.options
      [
        { key: 'client.node-image', arg: 'IMAGE',
          desc: "Node image the SPA is built in (default: #{DEFAULT_NODE_IMAGE})" }
      ]
    end

    def initialize(cmd:, quiet:, root:, registry: nil, node_image: nil, identity: nil)
      @cmd = cmd
      @quiet = quiet
      @root = root
      @src = File.join(root, 'carbide2-client')
      @registry_obj = registry
      @registry = registry&.configured? ? registry.prefix : nil
      @node_image = node_image.to_s.empty? ? DEFAULT_NODE_IMAGE : node_image
      @identity = identity || Carbide::Identity.new(cmd: cmd, root: root)
    end

    attr_reader :identity

    def state(refs: {}) = @identity.state(:client, refs: refs)
    def tag(refs: {})   = @identity.tag(:client, refs: refs)
    def dirty?(refs: {}) = @identity.dirty?(:client, refs: refs)

    def families = FAMILIES.map { |f| f[:family] }
    def family_for(mode) = FAMILIES.find { |f| f[:mode] == mode }&.fetch(:family)
    def base_path(family, sha) = "/clients/#{family}/#{sha}/"

    # The registry cache holds ONE artifact per client sha, with every family's
    # output inside it, so N deploys across N clusters share one build.
    def cache_ref(sha) = @registry ? "#{@registry}#{NAME}:#{sha}" : nil

    def cache_detect(sha)
      return :unreachable unless @registry

      @registry_obj.detect(NAME, sha)
    end

    # Build every family, yielding { sha:, version:, codename:, dists: {family => dir} }.
    #
    # Output and npm's cache go to a temp directory OUTSIDE the checkout, and
    # that is not fastidiousness. The client's .gitignore covers node_modules and
    # dist, but not dist-workspace / dist-control or a stray .npm — so writing
    # them into the working tree would leave untracked files behind, and by this
    # tool's own rule (untracked-but-not-ignored is dirty) the next build of an
    # otherwise clean tree would tag itself -dirty because of the previous build.
    def build(refs: {}, allow_dirty: false)
      st = state(refs: refs)
      guard_dirty!(st, allow_dirty)
      # The TAG, not the bare sha: the -dirty suffix is applied wherever a tag or
      # a path is named, and for the client that is both the registry tag and
      # the served /clients/<family>/<sha>/ path.
      sha = st[:tag]

      with_source(refs) do |src|
        Dir.mktmpdir('carbide-client-out-') do |out|
          version, codename = read_version(src)
          install_dependencies(src, out)
          dists = FAMILIES.to_h do |f|
            [f[:family], vite_build(src, out, f, sha)]
          end
          yield({ sha: sha, commit: st[:sha], version: version, codename: codename,
                  dists: dists })
        end
      end
    end

    # manifest.json is composed at PUBLISH time, not build time: build-client
    # writes it after the cache pull/build branch, so the cached registry
    # artifact contains the Vite output and nothing else. Two consequences worth
    # keeping in view — the manifest describes the upload, and on a cache hit
    # build_time is the upload's, while the cached image's OCI label still
    # carries the original build's.
    #
    # floors is passed through exactly as build-client emitted it. Nothing
    # enforces it; compatibility gating is not this tool's business.
    def manifest(family:, mode:, sha:, version:, codename:, label: nil,
                 full_sha: nil, floors: {}, build_time: nil, commit_time: nil)
      {
        'family' => family,
        'mode' => mode,
        'sha' => sha,
        'full_sha' => full_sha || sha,
        'label' => label.to_s.empty? ? sha : label,
        'version' => version,
        'codename' => codename,
        'build_time' => build_time || now_z,
        'commit_time' => commit_time,
        'base' => base_path(family, sha),
        'floors' => floors || {}
      }
    end

    # Write the manifest into each built family directory, ready for upload.
    def stamp_manifests(built, label: nil, floors: {}, commit_time: nil)
      build_time = now_z
      FAMILIES.each do |f|
        dist = built[:dists].fetch(f[:family])
        doc = manifest(family: f[:family], mode: f[:mode], sha: built[:sha],
                       full_sha: built[:commit],
                       version: built[:version], codename: built[:codename],
                       label: label, floors: floors,
                       build_time: build_time, commit_time: commit_time)
        File.write(File.join(dist, 'manifest.json'), "#{JSON.pretty_generate(doc)}\n")
      end
      built
    end

    # --- registry cache --------------------------------------------------------

    # One FROM-scratch image per client sha, with one directory per family
    # inside it. Transitional: when the families collapse this is one COPY of one
    # directory, and what survives is "one artifact per sha", not its contents.
    def cache_push(built, allow_dirty: false)
      raise Error, 'no registry configured' unless @registry

      if built[:sha].end_with?('-dirty') && !allow_dirty
        raise Error, "refusing to push #{cache_ref(built[:sha])}: a -dirty tag names a class " \
                     'of working tree, not a build. Pass --allow-dirty if you mean it.'
      end

      Dir.mktmpdir('carbide-client-cache-') do |ctx|
        dockerfile = ['FROM scratch']
        FAMILIES.each do |f|
          FileUtils.cp_r(built[:dists].fetch(f[:family]), File.join(ctx, f[:mode]))
          dockerfile << "COPY #{f[:mode]} /#{f[:mode]}"
        end
        File.write(File.join(ctx, 'Dockerfile'), "#{dockerfile.join("\n")}\n")
        ref = cache_ref(built[:sha])
        run!('docker', 'build', '--quiet', '-t', ref, *label_args(built), ctx)
        run!('docker', 'push', ref)
        log "  pushed cache artifact #{ref}"
      end
    end

    # Pull the cached artifact back apart into per-family directories. The
    # manifest is NOT in there (see #manifest), so the caller stamps it.
    def cache_pull(sha, into:)
      raise Error, 'no registry configured' unless @registry

      ref = cache_ref(sha)
      log "  cache hit — pulling #{ref}"
      run!('docker', 'pull', ref)
      container = run!('docker', 'create', ref).out.to_s.strip
      begin
        FAMILIES.to_h do |f|
          dest = File.join(into, "dist-#{f[:mode]}")
          FileUtils.mkdir_p(dest)
          run!('docker', 'cp', "#{container}:/#{f[:mode]}/.", dest)
          [f[:family], dest]
        end
      ensure
        @quiet.run!('docker', 'rm', container)
      end
    end

    private

    def now_z = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

    def guard_dirty!(st, allow_dirty)
      return if allow_dirty || !st[:dirty]

      raise Error, "refusing to build from a dirty tree: #{st[:sha]} dirty. " \
                   'Pass --allow-dirty to build it as <sha>-dirty.'
    end

    # Bare builds the working tree as it stands; an explicit ref is materialized
    # in a detached worktree and is therefore clean by construction.
    def with_source(refs, &block)
      ref = refs && (refs[:client] || refs['client'])
      return block.call(@src) if ref.nil? || ref.to_s.strip.empty?

      sha = @identity.resolve(:client, ref.to_s.strip)
      Carbide::Worktree.with(cmd: @cmd, repo: @src, sha: sha, prefix: 'carbide-client', &block)
    end

    # The client carries its OWN version, independent of the meta manifest: it
    # moves at its own cadence, so the meta release version would be a lie.
    def read_version(src)
      package = File.join(src, 'package.json')
      version = begin
        JSON.parse(File.read(package))['version'].to_s
      rescue StandardError
        ''
      end
      log "client package.json has no version; the bundle will be unstamped" if version.empty?
      codename = File.read(File.join(src, 'src', 'version.js'))[/CODENAME\s*=\s*'([^']+)'/, 1].to_s
      [version, codename]
    rescue Errno::ENOENT => e
      raise Error, "cannot read the client's version: #{e.message}"
    end

    # Install dependencies ONCE. The family builds differ only in
    # VITE_CARBIDE_MODE, not in dependencies, so a second npm ci would wipe and
    # reinstall node_modules for nothing — and it is the slowest step.
    def install_dependencies(src, out)
      log 'npm ci (node container)'
      run_node(src, out, [], 'npm ci --no-audit --no-fund')
    end

    def vite_build(src, out, family, sha)
      base = base_path(family[:family], sha)
      dist = File.join(out, "dist-#{family[:mode]}")
      log "building #{family[:family]} @ #{sha} (mode=#{family[:mode]}, base=#{base})"
      run_node(src, out,
               ['-e', "VITE_CARBIDE_MODE=#{family[:mode]}",
                '-e', "VITE_APP_CLIENT_SHA=#{sha}",
                '-e', "VITE_APP_BUILD_TIME=#{now_z}"],
               "npx vite build --base=#{base} --outDir /out/dist-#{family[:mode]} --emptyOutDir")
      raise Error, "build produced no index.html for #{family[:mode]}" unless File.file?(File.join(dist, 'index.html'))

      dist
    end

    # Runs as the host user so everything the build writes is owned by us rather
    # than root. HOME points at the OUT directory, not the source: npm would
    # otherwise drop a .npm cache into the checkout, which is not gitignored and
    # would make the tree dirty.
    def run_node(src, out, env, script)
      run!('docker', 'run', '--rm',
           '--user', "#{Process.uid}:#{Process.gid}",
           '-e', 'HOME=/out',
           '-v', "#{src}:/app",
           '-v', "#{out}:/out",
           '-w', '/app',
           *env,
           @node_image, 'sh', '-c', script)
    end

    def label_args(built)
      pairs = { 'org.carbide.version' => built[:version],
                'org.carbide.codename' => built[:codename] }
      pairs.reject { |_, v| v.to_s.empty? }.flat_map { |k, v| ['--label', "#{k}=#{v}"] }
    end

    def run!(*args)
      res = @quiet.run!(*args)
      return res if res.success?

      raise Error, "#{args.take(2).join(' ')} failed: #{res.err.to_s.strip}#{res.out.to_s.strip}"
    end
  end
end
