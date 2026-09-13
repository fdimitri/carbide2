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
require_relative 'carbide_kubeconfig'

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
    HelpRequested = Class.new(StandardError)

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

    # Behaviour flags — the ones with no config home. Held as data because three
    # things read them: the parser, --help, and the completion script. A flag
    # that exists in one and not the others is the drift this avoids.
    BEHAVIOR = [
      ['--source', 'SOURCE', :source,
       "Where the artifact comes from: #{SOURCES.join(' | ')} (default: auto). " \
       'An explicit source is STRICT — it never falls back to a build.'],
      ['--allow-dirty', nil, :allow_dirty,
       'Permit a dirty tree to be built, and a -dirty tag to be written'],
      ['--force', nil, :force,
       'Destination-side: overwrite a tag that is already present'],
      ['--force-rebuild', nil, :force_rebuild,
       'Source-side: build even though the tag exists'],
      ['--ref', 'REF', :ref, 'Build this ref of a single-source subject'],
      ['--server-ref', 'REF', :server_ref, 'Build from this carbide2-server ref'],
      ['--worker-ref', 'REF', :worker_ref, 'Build from this carbide2-worker ref'],
      ['--control-ref', 'REF', :control_ref, 'Build from this carbide2-control ref'],
      ['--client-ref', 'REF', :client_ref, 'Build from this carbide2-client ref'],
      ['--label', 'TEXT', :label, 'Label this client build in the picker (default: the sha)'],
      ['--kubeconfig', 'PATH', :kubeconfig,
       'Use this kubeconfig instead of the one derived from cluster.name'],
      ['--json', nil, :json, 'Machine-readable output where the verb has a structured form'],
      ['--completion', 'SHELL', :completion, 'Print a shell completion script (bash | zsh) and exit']
    ].freeze

    COMPLETION_SHELLS = %w[bash zsh].freeze

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
      return completion(@opts[:completion]) if @opts[:completion]

      dispatch(subject, verb, context)
    rescue HelpRequested => e
      # Asking for help is not an error: it goes to stdout and exits 0, so
      # `carcli --help | less` works and a script can tell it from a failure.
      @out.puts e.message
      EXIT_OK
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
      return [nil, nil, nil] if @opts[:completion]

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
        env_layer: true,
        banner: banner,
        on_help: ->(text) { raise HelpRequested, text }
      )
      @config.parse!(argv) { |parser| behavior_options(parser) }
      argv
    end

    def behavior_options(parser)
      parser.separator ''
      parser.separator 'carcli:'
      BEHAVIOR.each do |flag, arg, key, desc|
        spec = arg ? "#{flag} #{arg}" : flag
        if key == :source
          parser.on(spec, SOURCES, desc) { |v| @opts[:source] = v }
        elsif key.to_s.end_with?('_ref') && key != :ref
          component = key.to_s.sub('_ref', '').to_sym
          parser.on(spec, desc) { |v| @opts[:refs][component] = v }
        elsif arg
          parser.on(spec, desc) { |v| @opts[key] = v }
        else
          parser.on(spec, desc) { @opts[key] = true }
        end
      end
    end

    def specs
      Carbide::Images.options + Carbide::Registry.options + Carbide::Minio.options +
        Carbide::Client.options + Carbide::Kubeconfig.options
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
                     push: false, force_rebuild: @opts[:force_rebuild],
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

      images.build(components: [subject], refs: refs_for(subject), push: true,
                   force_rebuild: @opts[:force_rebuild], force: @opts[:force],
                   quiet: false, allow_dirty: @opts[:allow_dirty])
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

    def kubeconfig
      @kubeconfig ||= Carbide::Kubeconfig.new(
        cmd: quiet,
        cluster_name: @config.present('cluster.name').to_s,
        dir: @config.present('kubeconfig.dir'),
        override: @opts[:kubeconfig]
      )
    end

    # KUBECONFIG for this cluster. Empty when no per-cluster file has been
    # written yet, which leaves the ambient context in play — so a MinIO
    # operation against a cluster this box has never deployed says so rather
    # than quietly talking to whichever cluster the shell happened to point at.
    def kube_env
      env = kubeconfig.env
      warn_line "no kubeconfig at #{kubeconfig.path} — falling back to the ambient context" if env.empty?
      env
    end

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
      bits << "kubeconfig=#{kubeconfig.exist? ? kubeconfig.path : 'ambient'}" if target == 'minio' || target == 'both'
      bits << "config=#{@config.sources.join(' < ')}"
      @err.puts "resolved: #{bits.join(' ')}"
    end

    def info(message)  = @err.puts("INFO  #{message}")
    def warn_line(msg) = @err.puts("WARN  #{msg}")
    def error(message) = @err.puts("ERROR #{message}")

    # The Usage: block Config puts at the top of --help. deploy.rb's default
    # describes deploy.rb, which is worse than no banner at all on another tool.
    def banner
      "#{usage}\n"
    end

    # --- completion ------------------------------------------------------------

    # A STATIC script, generated from the same GRAMMAR the parser uses, rather
    # than a script that shells out to carcli on every tab press: the shim runs
    # bundler/inline on each invocation, which is far too slow to sit behind a
    # keystroke. Regenerate it when the grammar changes.
    #
    # Install, in order of how likely it is to actually work:
    #
    #   eval "$(carcli --completion bash)"            # this shell, right now
    #   carcli --completion bash >> ~/.bashrc         # every new shell
    #   carcli --completion bash | sudo tee /etc/bash_completion.d/carcli
    #
    # The last one needs bash-completion installed AND a new shell: that
    # directory is read once at init. Filename completion instead of subjects is
    # what an unregistered command looks like — `complete -p carcli` says
    # whether anything is registered at all.
    def completion(shell)
      unless COMPLETION_SHELLS.include?(shell)
        raise UsageError, "--completion takes #{COMPLETION_SHELLS.join(' | ')}, got '#{shell}'"
      end

      @out.puts(shell == 'bash' ? bash_completion : zsh_completion)
      EXIT_OK
    end

    def completion_flags
      config_flags = specs.flat_map do |spec|
        long = spec[:long] || spec[:key]
        spec[:negatable] ? ["--#{long}", "--no-#{long}"] : ["--#{long}"]
      end
      (BEHAVIOR.map(&:first) + config_flags + ['--config', '--help']).uniq.sort
    end

    def bash_completion
      subject_verbs = GRAMMAR.map { |s, g| "    #{s}) echo '#{g[:verbs].join(' ')}' ;;" }.join("\n")
      subject_stores = GRAMMAR.reject { |_, g| g[:stores].empty? }
                              .map { |s, g| "    #{s}) echo '#{g[:stores].join(' ')}' ;;" }.join("\n")
      <<~BASH
        # carcli bash completion — generated by `carcli --completion bash`.
        # Regenerate after a grammar change; nothing here calls carcli at runtime.
        #
        #   eval "$(carcli --completion bash)"    load it into THIS shell
        #
        # If TAB lists files instead of subjects, nothing is registered: check
        # with `complete -p carcli`. /etc/bash_completion.d is read only at shell
        # init, and only when bash-completion is installed.
        _carcli_verbs() {
          case "$1" in
        #{subject_verbs}
          esac
        }
        _carcli_stores() {
          case "$1" in
        #{subject_stores}
          esac
        }
        _carcli() {
          local cur prev words=() i
          cur="${COMP_WORDS[COMP_CWORD]}"
          # Positionals only: a flag or its value must not shift the grammar
          # position, or `carcli --config x.yaml <TAB>` completes verbs.
          for ((i=1; i<COMP_CWORD; i++)); do
            case "${COMP_WORDS[i]}" in
              -*) case "${COMP_WORDS[i]}" in
                    #{BEHAVIOR.select { |_, arg, _, _| arg }.map(&:first).join('|')}|--config) ((i++)) ;;
                  esac ;;
              *) words+=("${COMP_WORDS[i]}") ;;
            esac
          done
          if [[ "$cur" == -* ]]; then
            COMPREPLY=($(compgen -W '#{completion_flags.join(' ')}' -- "$cur"))
            return
          fi
          case "${#words[@]}" in
            0) COMPREPLY=($(compgen -W '#{GRAMMAR.keys.join(' ')}' -- "$cur")) ;;
            1) COMPREPLY=($(compgen -W "$(_carcli_verbs "${words[0]}")" -- "$cur")) ;;
            2) COMPREPLY=($(compgen -W "$(_carcli_stores "${words[0]}")" -- "$cur")) ;;
            *) COMPREPLY=() ;;
          esac
        }
        # The bare name is what bash looks up; it falls back to the basename for
        # ./scripts/carcli, and the explicit spellings cost nothing for anyone
        # whose bash does not.
        complete -F _carcli carcli ./carcli scripts/carcli ./scripts/carcli
      BASH
    end

    def zsh_completion
      verbs = GRAMMAR.map { |s, g| "    #{s}) verbs=(#{g[:verbs].join(' ')}) ;;" }.join("\n")
      stores = GRAMMAR.reject { |_, g| g[:stores].empty? }
                      .map { |s, g| "    #{s}) stores=(#{g[:stores].join(' ')}) ;;" }.join("\n")
      <<~ZSH
        #compdef carcli
        # carcli zsh completion — generated by `carcli --completion zsh`.
        # Regenerate after a grammar change; nothing here calls carcli at runtime.
        #
        # Save as _carcli somewhere on $fpath, then `compinit` (a new shell, or
        # `rm -f ~/.zcompdump; compinit`). `print -l $fpath` shows the candidates.
        _carcli() {
          local -a words_only verbs stores
          local w skip=0
          for w in ${words[2,$((CURRENT-1))]}; do
            if (( skip )); then skip=0; continue; fi
            case $w in
              #{BEHAVIOR.select { |_, arg, _, _| arg }.map(&:first).join('|')}|--config) skip=1 ;;
              -*) ;;
              *) words_only+=$w ;;
            esac
          done
          if [[ $words[CURRENT] == -* ]]; then
            compadd -- #{completion_flags.join(' ')}
            return
          fi
          case ${#words_only} in
            0) compadd -- #{GRAMMAR.keys.join(' ')} ;;
            1) case $words_only[1] in
        #{verbs}
               esac
               compadd -- $verbs ;;
            2) case $words_only[1] in
        #{stores}
               esac
               compadd -- $stores ;;
          esac
        }
        _carcli "$@"
      ZSH
    end

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
