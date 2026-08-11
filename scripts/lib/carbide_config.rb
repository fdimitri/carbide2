# frozen_string_literal: true

require 'yaml'
require 'optparse'
require 'securerandom'

module Carbide
  # Layered configuration for deploy.rb. Replaces the old "config via ENV +
  # a giant OptionParser" approach with three merged layers (last wins):
  #
  #   1. defaults.yaml    every default lives here — no implicit defaults in code
  #   2. input.yaml       (--config PATH) the emit/consume handoff file; a k3s
  #                       server emits it, agents consume it
  #   3. CLI overrides    every option maps 1:1 to a dotted config key and wins
  #
  # The option long-name IS the dotted YAML key: --cluster.backend sets
  # cluster.backend, --tls.cert-string sets tls.cert-string. Dot nests, dash
  # stays inside a leaf name (kebab), so the mapping is unambiguous both ways —
  # which is what makes emitting the resolved config back out (and re-consuming
  # it) trivial and symmetric.
  #
  # Options are not declared here: each module (Cluster, Storage, Tls, Images,
  # ControlPlane, Deploy) exposes `self.options` returning its own specs, and
  # Config aggregates them. Adding a knob = adding one spec next to the code that
  # uses it, not editing a monster parser.
  #
  # An option spec is a Hash:
  #   key:        'cluster.backend'   dotted config path (required)
  #   long:       'cluster.backend'   CLI flag body (default: key)
  #   arg:        'BACKEND'           metavar; omit for a boolean flag
  #   values:     %w[k3d k3s]         optional enum validation
  #   negatable:  true                boolean rendered as --[no-]<long>
  #   file:       true                arg is a PATH read into key (self-contained
  #                                   emit: --registry.ca-file -> registry.ca PEM)
  #   secret:     true               force-redact in --yaml-safeout    #   generate:   :hex32             mint a value when the key is blank (so an
    #                                   init node emits e.g. cluster.token)
    #   generate_when: [['a','x'],..]  only generate if every [path,value] holds  #   desc:       'help text'
  class Config
    # Leaf key names matching this are treated as secrets and redacted by
    # --yaml-safeout. Convention catches the common cases; SECRET_PATHS below
    # covers anything the naming misses. A bare `secret` leaf is deliberately
    # NOT here: it names a Kubernetes Secret (tls-opts.secret) rather than
    # holding one. Keys that really do hold a credential carry secret: true.
    SECRET_NAME  = /token|password|private[-_]?key|key[-_]?string/i
    # Explicit dotted paths to redact regardless of their leaf name.
    SECRET_PATHS = %w[].freeze
    REDACTED     = '<redacted>'

    # defaults_path : scripts/defaults.yaml (checked in).
    # specs         : aggregated option specs from every module.
    def initialize(defaults_path:, specs:)
      @defaults_path = defaults_path
      @specs         = specs
      @secret_keys   = specs.select { |s| s[:secret] }.map { |s| s[:key] }
      @data          = load_yaml_file(defaults_path)
      @overrides     = {}   # dotted-key => value, applied as the last layer
      @input_path    = nil
      @emit          = nil  # [:full | :safe, path]
    end

    # Build the parser, parse argv (mutates it), then resolve the three layers.
    # Handles --yaml-out/--yaml-safeout (dump + exit) itself. Returns self.
    def parse!(argv)
      build_parser.parse!(argv)
    rescue OptionParser::ParseError => e
      abort "\e[1;31mxx\e[0m #{e.message}"
    else
      if @input_path
        merged = load_yaml_file(@input_path)
        abort "\e[1;31mxx\e[0m --config #{@input_path}: expected a YAML mapping" unless merged.is_a?(Hash)
        deep_merge!(@data, merged)
      end
      @overrides.each { |dotted, val| set(dotted, val) }

      apply_generators!
      emit_and_exit! if @emit
      self
    end

    # Fetch a value by dotted path (segments split on '.', so kebab leaf names
    # survive intact). Returns `default` for any missing segment.
    def get(path, default = nil)
      node = @data
      path.to_s.split('.').each do |seg|
        return default unless node.is_a?(Hash) && node.key?(seg)

        node = node[seg]
      end
      node
    end

    def bool(path) = truthy?(get(path))

    # Trimmed non-empty string, or nil. The "" defaults in defaults.yaml mean
    # "unset" for optional knobs (registry.host, public.host, ...).
    def present(path)
      v = get(path)
      s = v.nil? ? nil : v.to_s.strip
      (s && !s.empty?) ? s : nil
    end

    def to_h = @data

    private

    def build_parser
      OptionParser.new do |o|
        o.banner = "Usage: deploy.rb [options]\n" \
                   "  Config layers (last wins): defaults.yaml -> --config input.yaml -> CLI flags.\n" \
                   "  Every --a.b.c flag sets the a.b.c key; emit the resolved set with --yaml-out.\n\n"

        @specs.each { |spec| add_option(o, spec) }

        o.separator ''
        o.separator 'Config file:'
        o.on('--config PATH', 'Merge a YAML config over the defaults (before CLI flags)') { |v| @input_path = v }
        o.on('--yaml-out PATH', 'FREEZE the fully-resolved config (secrets included) to PATH and exit; does NOT deploy — deploy from it with --config PATH') { |v| @emit = [:full, v] }
        o.on('--yaml-safeout PATH', 'Like --yaml-out but redact secrets (not usable by joiners); then exit') { |v| @emit = [:safe, v] }
        o.on('--schema-out PATH', 'Dump the option specs + resolved defaults as JSON to PATH and exit (drives scripts/configure.rb)') { |v| @emit = [:schema, v] }
        o.on('-h', '--help', 'Show this help') { puts o; exit 0 }
      end
    end

    def add_option(parser, spec)
      long = spec[:long] || spec[:key]
      desc = spec[:desc] || ''
      if spec[:arg]
        flag = "--#{long} #{spec[:arg]}"
        if spec[:values]
          parser.on(flag, spec[:values], desc) { |v| @overrides[spec[:key]] = v }
        elsif spec[:file]
          parser.on(flag, desc) { |v| @overrides[spec[:key]] = read_file_arg(v) }
        else
          parser.on(flag, desc) { |v| @overrides[spec[:key]] = v }
        end
      elsif spec[:negatable]
        parser.on("--[no-]#{long}", desc) { |v| @overrides[spec[:key]] = v }
      else
        parser.on("--#{long}", desc) { @overrides[spec[:key]] = true }
      end
    end

    # --*-file options carry a path whose CONTENTS become the canonical value, so
    # the resolved config (and any YAML we emit) is self-contained.
    def read_file_arg(path)
      abs = File.expand_path(path)
      abort "\e[1;31mxx\e[0m file not found: #{path}" unless File.file?(abs)
      File.read(abs)
    end

    def set(dotted, val)
      segs = dotted.to_s.split('.')
      leaf = segs.pop
      node = @data
      segs.each { |s| node = (node[s] ||= {}) }
      node[leaf] = val
    end

    # Mint values for blank keys whose spec carries `generate:`, gated on any
    # `generate_when:` [path, value] conditions all holding. Runs before emit so
    # a freshly-minted secret (cluster.token on --role init) lands in --yaml-out.
    def apply_generators!
      @specs.each do |spec|
        gen = spec[:generate]
        next unless gen
        next if present(spec[:key])
        next unless (spec[:generate_when] || []).all? { |path, val| get(path).to_s == val.to_s }

        set(spec[:key], generate_value(gen))
      end
    end

    def generate_value(kind)
      case kind
      when :hex32 then SecureRandom.hex(32)
      else abort "\e[1;31mxx\e[0m unknown generator: #{kind.inspect}"
      end
    end

    def load_yaml_file(path)
      return {} unless File.file?(path)

      data = YAML.safe_load_file(path)
      data.is_a?(Hash) ? data : {}
    rescue StandardError => e
      abort "\e[1;31mxx\e[0m failed to read config #{path}: #{e.message}"
    end

    # Recursively merge `src` into `dst`: hashes deep-merge, scalars and arrays
    # replace (an array in a later layer overrides, never appends).
    def deep_merge!(dst, src)
      src.each do |k, v|
        dst[k] = if dst[k].is_a?(Hash) && v.is_a?(Hash)
                   deep_merge!(dst[k], v)
                 else
                   v
                 end
      end
      dst
    end

    def truthy?(v)
      return v if [true, false].include?(v)
      return false if v.nil?

      %w[1 true yes on].include?(v.to_s.strip.downcase)
    end

    def emit_and_exit!
      mode, path = @emit
      return emit_schema_and_exit!(path) if mode == :schema

      out = mode == :safe ? redacted(@data) : @data
      File.write(File.expand_path(path), YAML.dump(out))
      warn "wrote #{mode == :safe ? 'redacted ' : ''}config to #{path}"
      exit 0
    end

    # The specs ARE the UI schema: key, metavar, enum, negatable-ness and help
    # text are everything a form needs. Emitting them keeps configure.rb from
    # re-declaring knobs that already live next to the code that uses them.
    # Values are NOT redacted: the form has to round-trip them, and a redacted
    # placeholder would be written back as if it were the real setting.
    def emit_schema_and_exit!(path)
      require 'json'
      payload = { 'specs' => @specs.map { |s| s.transform_keys(&:to_s) },
                  'defaults' => @data }
      File.write(File.expand_path(path), JSON.pretty_generate(payload))
      warn "wrote option schema to #{path}"
      exit 0
    end

    # Deep copy of the config with secret leaves replaced by REDACTED. A leaf is
    # secret if its dotted path is in SECRET_PATHS / a spec marked secret, or its
    # leaf name matches SECRET_NAME.
    def redacted(node, prefix = '')
      return node unless node.is_a?(Hash)

      node.each_with_object({}) do |(k, v), acc|
        path = prefix.empty? ? k.to_s : "#{prefix}.#{k}"
        acc[k] = if v.is_a?(Hash)
                   redacted(v, path)
                 elsif secret_leaf?(path, k)
                   v.nil? || v.to_s.empty? ? v : REDACTED
                 else
                   v
                 end
      end
    end

    def secret_leaf?(path, leaf)
      SECRET_PATHS.include?(path) || @secret_keys.include?(path) || leaf.to_s.match?(SECRET_NAME)
    end
  end
end
