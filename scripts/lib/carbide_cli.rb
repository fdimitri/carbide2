# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative 'carbide_command'
require_relative 'carbide_config'
require_relative 'carbide_identity'
require_relative 'carbide_images'
require_relative 'carbide_registry'
require_relative 'carbide_client'
require_relative 'carbide_minio'

module Carbide
  # carcli's grammar, resolution and dispatch (ADR-043 §1-§3, §6, §12).
  #
  # scripts/carcli is a thin shim over this so the whole CLI is testable: the
  # interesting parts are the parse-time rules, the source chains and the exit
  # codes, none of which are reachable if they live in a script body.
  class CLI
    include Carbide::CommandRunner

    # ADR-043 §3. 1 doubles as "absent" for detect and "generic failure"
    # elsewhere, which is unambiguous per verb because detect has no generic
    # failure — its failure modes are 2, 3 and 4.
    EXIT_OK          = 0
    EXIT_FAIL        = 1
    EXIT_ABSENT      = 1
    EXIT_UNREACHABLE = 2
    EXIT_USAGE       = 3
    EXIT_CONFIG      = 4
    EXIT_REFUSED     = 5

    UsageError  = Class.new(StandardError)
    ConfigError = Class.new(StandardError)

    ARTIFACTS = %i[workspace control shell client].freeze
    IMAGES    = %i[workspace control shell].freeze

    # The context set is subject-dependent and enforced AT PARSE, so
    # `carcli workspace populate minio` is a usage error rather than something
    # that fails halfway through a build.
    GRAMMAR = {
      workspace: { verbs: %i[state build populate detect list rm], stores: %w[registry] },
      control:   { verbs: %i[state build populate detect list rm], stores: %w[registry] },
      shell:     { verbs: %i[state build populate detect list rm], stores: %w[registry] },
      client:    { verbs: %i[state build populate detect list rm], stores: %w[registry minio both] },
      registry:  { verbs: %i[serve check], stores: [] }
    }.freeze

    # Verbs that take a store context. `both` is a value, not a store, and is
    # client-only; it is accepted where writing or listing two stores makes
    # sense and refused for the single-object verbs.
    CONTEXT_VERBS = %i[populate detect list rm].freeze
    NO_BOTH       = %i[detect rm].freeze

    SOURCES = %w[auto registry build].freeze

    def self.run(argv, root:, defaults_path:, out: $stdout, err: $stderr, cmd: nil, quiet: nil)
      new(root: root, defaults_path: defaults_path, out: out, err: err,
          cmd: cmd, quiet: quiet).run(argv)
    end

    # cmd/quiet: injectable so the CLI is testable without tty-command, and so a
    # caller that already has runners (deploy.rb) does not build a second pair.
    def initialize(root:, defaults_path:, out: $stdout, err: $stderr, cmd: nil, quiet: nil)
      @root = root
      @defaults_path = defaults_path
      @out = out
      @err = err
      @cmd = cmd
      @quiet = quiet
      @opts = { source: 'auto', refs: {} }
    end

    def run(argv)
      subject, verb, context = parse!(argv.dup)
      dispatch(subject, verb, context)
    rescue UsageError => e
      error(e.message)
      EXIT_USAGE
    rescue ConfigError => e
      error(e.message)
      EXIT_CONFIG
    rescue Carbide::Images::DirtyRefused => e
      error(e.message)
      EXIT_REFUSED
    rescue Carbide::Minio::Unreachable => e
      error(e.message)
      EXIT_UNREACHABLE
    rescue Carbide::Images::Error, Carbide::Client::Error, Carbide::Minio::Error,
           Carbide::Identity::Error, Carbide::Worktree::Error => e
      error(e.message)
      # A refusal phrased as a plain Error still deserves code 5: the caller
      # needs to tell "you need a flag" from "it broke".
      e.message.include?('--allow-dirty') || e.message.include?('--force') ? EXIT_REFUSED : EXIT_FAIL
    rescue StandardError => e
      error(e.message)
      EXIT_FAIL
    end

    private

    # --- parsing ---------------------------------------------------------------

    # Options are parsed FIRST. OptionParser removes each recognized flag AND
    # its value from argv, so what is left is genuinely positional — filtering
    # on a leading dash instead would read `--ref main` as the store `main`.
    def parse!(argv)
      positional = parse_options!(argv)
      subject = positional[0]
      raise UsageError, usage if subject.nil?

      subject = subject.to_sym
      grammar = GRAMMAR[subject]
      raise UsageError, "unknown subject '#{subject}' (want: #{GRAMMAR.keys.join(', ')})" if grammar.nil?

      verb = positional[1]&.to_sym
      raise UsageError, "#{subject}: no verb (want: #{grammar[:verbs].join(', ')})" if verb.nil?
      unless grammar[:verbs].include?(verb)
        raise UsageError, "#{subject} has no verb '#{verb}' (want: #{grammar[:verbs].join(', ')})"
      end

      context = positional[2]
      validate_context!(subject, verb, context, grammar)
      extra = positional[(CONTEXT_VERBS.include?(verb) ? 3 : 2)..] || []
      # rm takes a sha after its store; nothing else takes a fourth positional.
      @opts[:shas] = extra
      raise UsageError, "#{subject} #{verb}: unexpected argument '#{extra.first}'" if !extra.empty? && verb != :rm

      [subject, verb, context]
    end

    def validate_context!(subject, verb, context, grammar)
      if CONTEXT_VERBS.include?(verb)
        raise UsageError, "#{subject} #{verb}: needs a store (#{grammar[:stores].join(' | ')})" if context.nil?
        unless grammar[:stores].include?(context)
          raise UsageError, "#{subject} #{verb}: no store '#{context}' " \
                            "(#{subject} has: #{grammar[:stores].join(', ')})"
        end
        if context == 'both' && NO_BOTH.include?(verb)
          raise UsageError, "#{subject} #{verb}: 'both' names two stores; #{verb} acts on one"
        end
      elsif context
        raise UsageError, "#{subject} #{verb}: takes no store, got '#{context}'"
      end
    end

    # Returns the leftover positionals. argv is mutated by OptionParser.
    def parse_options!(argv)
      @config = Carbide::Config.new(
        defaults_path: @defaults_path,
        specs: specs,
        fail_with: ->(msg) { raise ConfigError, msg },
        fail_usage: ->(msg) { raise UsageError, msg },
        discover: true,
        env_layer: true
      )
      @config.parse!(argv) { |parser| behavior_options(parser) }
      argv
    end

    def behavior_options(parser)
      parser.separator ''
      parser.separator 'carcli:'
      parser.on('--source SOURCE', SOURCES,
                "Where the artifact comes from: #{SOURCES.join(' | ')} (default: auto). " \
                'An explicit source is STRICT — it never falls back to a build.') { |v| @opts[:source] = v }
      parser.on('--allow-dirty', 'Permit a dirty tree to be built, and a -dirty tag to be written') { @opts[:allow_dirty] = true }
      parser.on('--force', 'Destination-side: overwrite a tag that is already present') { @opts[:force] = true }
      parser.on('--force-rebuild', 'Source-side: build even though the tag exists') { @opts[:force_rebuild] = true }
      parser.on('--ref REF', 'Build this ref of a single-source subject') { |v| @opts[:ref] = v }
      %w[server worker control client].each do |component|
        parser.on("--#{component}-ref REF", "Build from this carbide2-#{component} ref") do |v|
          @opts[:refs][component.to_sym] = v
        end
      end
      parser.on('--label TEXT', 'Label this client build in the picker (default: the sha)') { |v| @opts[:label] = v }
      parser.on('--json', 'Machine-readable output where the verb has a structured form') { @opts[:json] = true }
    end

    def specs
      Carbide::Images.options + Carbide::Registry.options + Carbide::Minio.options +
        Carbide::Client.options
    end

    # --- dispatch --------------------------------------------------------------

    def dispatch(subject, verb, context)
      return registry_verb(verb) if subject == :registry

      case verb
      when :state    then show_state(subject)
      when :build    then do_build(subject)
      when :detect   then do_detect(subject, context)
      when :list     then do_list(subject, context)
      when :rm       then do_rm(subject, context)
      when :populate then do_populate(subject, context)
      end
    end

    def show_state(subject)
      state = identity.state(subject, refs: refs_for(subject))
      if @opts[:json]
        @out.puts JSON.pretty_generate(state)
      else
        @out.puts state.map { |k, v| "#{k}\t#{v.is_a?(Hash) ? v.map { |kk, vv| "#{kk}=#{vv}" }.join(',') : v}" }
      end
      EXIT_OK
    end

    def do_build(subject)
      resolution(subject: subject, source: 'build', target: nil)
      if subject == :client
        client.build(refs: refs_for(subject), allow_dirty: @opts[:allow_dirty]) do |built|
          info "build: #{built[:dists].size} variants at #{built[:sha]}"
        end
      else
        images.build(components: [subject], refs: refs_for(subject),
                     push: false, force: @opts[:force_rebuild],
                     quiet: false, allow_dirty: @opts[:allow_dirty])
      end
      EXIT_OK
    end

    def do_detect(subject, store)
      result = detect(subject, store)
      @out.puts result
      { present: EXIT_OK, absent: EXIT_ABSENT, unreachable: EXIT_UNREACHABLE }.fetch(result)
    end

    def detect(subject, store)
      return images.detect(subject, refs: refs_for(subject)) if store == 'registry' && subject != :client
      return client.cache_detect(tag_for(subject)) if store == 'registry'

      with_minio { |store_obj, session| minio_detect(store_obj, session, tag_for(:client)) }
    end

    # The client occupies two MinIO families per sha, and a build is only
    # present when BOTH are: a half-published build serves one of them a 404.
    def minio_detect(store_obj, session, sha)
      results = Carbide::Client::FAMILIES.map { |f| store_obj.detect(session, f[:family], sha) }
      return :unreachable if results.include?(:unreachable)

      results.all? { |r| r == :present } ? :present : :absent
    end

    def do_list(subject, store)
      case store
      when 'registry' then list_registry(subject)
      when 'minio'    then list_minio
      when 'both'     then (list_registry(subject); list_minio)
      end
      EXIT_OK
    end

    def list_registry(subject)
      name = subject == :client ? Carbide::Client::NAME : Carbide::Images::NAMES.fetch(subject)
      registry.tags(name).each { |tag| @out.puts "registry\t#{tag}\t#{name}" }
    end

    def list_minio
      with_minio do |store_obj, session|
        index = store_obj.read_index(session)
        if index.nil?
          warn_line 'no clients/registry.json — listing raw objects instead'
          store_obj.objects(session).each { |key| @out.puts "minio\t#{key}" }
        else
          index.fetch('families', {}).each_value do |builds|
            builds.each { |b| @out.puts "minio\t#{b['sha']}\t#{b['family']} #{b['label']} #{b['commit_time']}" }
          end
        end
      end
    end

    def do_rm(subject, store)
      sha = @opts[:shas].first
      raise UsageError, "#{subject} rm #{store}: needs a sha" if sha.nil?
      raise UsageError, 'rm registry is not implemented yet' if store == 'registry'

      with_minio do |store_obj, session|
        Carbide::Client::FAMILIES.each { |f| store_obj.remove(session, f[:family], sha) }
        store_obj.reindex(session)
      end
      EXIT_OK
    end

    # --- populate --------------------------------------------------------------

    def do_populate(subject, store)
      return populate_image(subject) if IMAGES.include?(subject)

      case store
      when 'registry' then populate_client_registry
      when 'minio'    then populate_client_minio
      when 'both'     then populate_client_both
      end
    end

    def populate_image(subject)
      resolution(subject: subject, source: @opts[:source], target: 'registry')
      raise ConfigError, 'populate registry needs registry.host' unless registry.configured?

      unless @opts[:source] == 'build' || @opts[:force]
        case images.detect(subject, refs: refs_for(subject))
        when :present
          return skip("registry has #{subject} already") unless @opts[:force_rebuild]
        when :unreachable then return strict_stop('registry')
        when :absent      then strict_absent!('registry') unless @opts[:source] == 'auto'
        end
      end

      registry.login! if registry.auth?
      images.build(components: [subject], refs: refs_for(subject), push: true,
                   force: @opts[:force_rebuild] || @opts[:force], quiet: false,
                   allow_dirty: @opts[:allow_dirty])
      EXIT_OK
    end

    def populate_client_registry
      resolution(subject: :client, source: @opts[:source], target: 'registry')
      raise ConfigError, 'populate registry needs registry.host' unless registry.configured?

      sha = tag_for(:client)
      unless @opts[:source] == 'build' || @opts[:force]
        case client.cache_detect(sha)
        when :present     then return skip("registry has carbide2-client:#{sha}")
        when :unreachable then return strict_stop('registry')
        when :absent      then strict_absent!('registry') unless @opts[:source] == 'auto'
        end
      end

      registry.login! if registry.auth?
      client.build(refs: refs_for(:client), allow_dirty: @opts[:allow_dirty]) do |built|
        client.cache_push(built, allow_dirty: @opts[:allow_dirty])
      end
      EXIT_OK
    end

    def populate_client_minio
      resolution(subject: :client, source: @opts[:source], target: 'minio')
      sha = tag_for(:client)

      with_minio do |store_obj, session|
        unless @opts[:force]
          case minio_detect(store_obj, session, sha)
          when :present     then return skip("minio has #{sha}")
          when :unreachable then return unreachable_target('minio')
          end
        end

        obtain(sha) do |built|
          publish(store_obj, session, built)
        end
      end
      EXIT_OK
    end

    def populate_client_both
      resolution(subject: :client, source: @opts[:source], target: 'both')
      raise ConfigError, 'populate both needs registry.host' unless registry.configured?

      registry.login! if registry.auth?
      # One obtain, two writes. Not two sequential populates — that would build,
      # push the registry, then pull back what it just pushed.
      obtain(tag_for(:client), seed_registry: true) do |built|
        with_minio { |store_obj, session| publish(store_obj, session, built) }
      end
      EXIT_OK
    end

    # Get the client bundle from wherever the source rules allow, and yield it.
    #
    # Under auto the registry is a cheap source and its being unreachable is a
    # WARNing that falls through to a build. Under an explicit --source it is
    # strict: unreachable is an error and absent is an error, because a strict
    # source that silently built would be auto under another name.
    def obtain(sha, seed_registry: false)
      if @opts[:source] != 'build' && registry.configured?
        case client.cache_detect(sha)
        when :present
          return client_from_cache(sha) { |built| yield built }
        when :unreachable
          strict_stop!('registry') unless @opts[:source] == 'auto'
          warn_line 'registry unreachable — falling through to a build'
        when :absent
          strict_absent!('registry') unless @opts[:source] == 'auto'
        end
      elsif @opts[:source] == 'registry'
        raise ConfigError, '--source=registry needs registry.host'
      end

      info 'building the client'
      client.build(refs: refs_for(:client), allow_dirty: @opts[:allow_dirty]) do |built|
        client.cache_push(built, allow_dirty: @opts[:allow_dirty]) if seed_registry
        yield built
      end
    end

    def client_from_cache(sha)
      info "registry has #{sha} — pulling"
      Dir.mktmpdir('carbide-client-cache-') do |into|
        dists = client.cache_pull(sha, into: into)
        yield({ sha: sha, commit: sha.sub(/-dirty\z/, ''), dists: dists,
                version: nil, codename: nil })
      end
    end

    def publish(store_obj, session, built)
      client.stamp_manifests(built, label: @opts[:label])
      Carbide::Client::FAMILIES.each do |f|
        store_obj.upload(session, f[:family], built[:sha], built[:dists].fetch(f[:family]))
      end
      store_obj.reindex(session)
      info "minio: uploaded #{built[:sha]}, index regenerated"
    end

    # --- registry subject ------------------------------------------------------

    def registry_verb(verb)
      raise ConfigError, 'registry.host is not set' unless registry.configured?

      case verb
      when :serve
        raise ConfigError, 'registry.serve is false: this box does not run the registry' unless registry.serve?

        registry.ensure!
      when :check
        registry.check!
        @out.puts "ok\t#{registry.endpoint}"
      end
      EXIT_OK
    rescue RuntimeError => e
      error(e.message)
      EXIT_UNREACHABLE
    end

    # --- helpers ---------------------------------------------------------------

    def strict_absent!(store)
      raise "#{store} has no #{@subject_label}\n" \
            "      --source=#{@opts[:source]} is strict; no build attempted\n" \
            '      use --source=auto to build, or --source=build to force one'
    end

    def strict_stop!(store)
      raise Carbide::Minio::Unreachable,
            "#{store} is unreachable, and --source=#{@opts[:source]} is strict"
    end

    def strict_stop(store)
      error "#{store} is unreachable"
      EXIT_UNREACHABLE
    end

    def unreachable_target(store)
      error "#{store} is unreachable — refusing to guess whether the artifact is there"
      EXIT_UNREACHABLE
    end

    def skip(message)
      info "#{message}, skipping"
      EXIT_OK
    end

    def refs_for(subject)
      refs = @opts[:refs].dup
      if @opts[:ref]
        components = Carbide::Identity::SOURCES.fetch(subject)
        if components.length > 1
          raise UsageError, "#{subject} is built from #{components.join(' + ')}; " \
                            "--ref cannot address it (use #{components.map { |c| "--#{c}-ref" }.join(' / ')})"
        end
        refs[components.first] = @opts[:ref]
      end
      refs
    end

    def tag_for(subject) = identity.tag(subject, refs: refs_for(subject))

    def with_minio(&block)
      minio.with_session { |session| block.call(minio, session) }
    end

    # --- objects ---------------------------------------------------------------

    def cmd   = @cmd   ||= runner(:pretty)
    def quiet = @quiet ||= runner(:null)

    def runner(printer)
      require 'tty-command'
      TTY::Command.new(uuid: false, printer: printer)
    end

    def identity = @identity ||= Carbide::Identity.new(cmd: quiet, root: @root)

    def registry
      @registry ||= Carbide::Registry.new(
        cmd: cmd, quiet: quiet,
        host: @config.present('registry.host'),
        port: @config.present('registry.port'),
        path: @config.present('registry.path'),
        mode: @config.present('registry.mode') || 'generic',
        ca: @config.present('registry.ca'),
        serve: @config.bool('registry.serve'),
        username: @config.present('registry.username'),
        password: @config.present('registry.password')
      )
    end

    def images
      @images ||= Carbide::Images.new(cmd: cmd, quiet: quiet, root: @root,
                                      registry: registry, identity: identity)
    end

    def client
      @client ||= Carbide::Client.new(cmd: cmd, quiet: quiet, root: @root,
                                      registry: registry, identity: identity,
                                      node_image: @config.present('client-build.node-image'))
    end

    def minio
      @minio ||= Carbide::Minio.new(
        cmd: cmd, quiet: quiet,
        namespace: @config.present('minio.namespace') || @config.present('control.namespace') || 'carbide-system',
        service: @config.present('minio.service') || 'minio',
        secret: @config.present('minio.secret') || 'minio-credentials',
        kube_env: kube_env,
        mc: @config.present('minio.mc')
      )
    end

    # Step 5 (Carbide::Kubeconfig) fills this in from cluster.name; until then
    # the ambient context applies, which is the thing ADR-043 §9 exists to stop.
    def kube_env = {}

    # --- output ----------------------------------------------------------------

    # One resolution line before any work. Every decision prints: it is how the
    # knobs become discoverable, and how a fan-out across clusters stays
    # debuggable when it goes wrong on the fourth one.
    def resolution(subject:, source:, target:)
      @subject_label = subject.to_s
      bits = ["subject=#{subject}", "source=#{source}"]
      bits << "target=#{target}" if target
      state = identity.state(subject, refs: refs_for(subject))
      bits << "dirty=#{state[:dirty] ? 'yes' : 'no'}"
      bits << "cluster=#{@config.present('cluster.name') || '?'}"
      bits << "config=#{@config.sources.join(' < ')}"
      @err.puts "resolved: #{bits.join(' ')}"
    end

    def info(message)  = @err.puts("INFO  #{message}")
    def warn_line(msg) = @err.puts("WARN  #{msg}")
    def error(message) = @err.puts("ERROR #{message}")

    def usage
      <<~USAGE
        Usage: carcli [options] <subject> <verb> [store]

          subjects  #{GRAMMAR.keys.join(', ')}
          verbs     state, build, populate <store>, detect <store>, list <store>, rm <store> <sha>
                    registry serve, registry check
          stores    #{GRAMMAR.map { |s, g| "#{s}: #{g[:stores].empty? ? '-' : g[:stores].join('|')}" }.join('  ')}

        --help lists every option.
      USAGE
    end
  end
end
