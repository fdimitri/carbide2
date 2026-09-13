# frozen_string_literal: true

require 'json'
require 'base64'
require_relative 'shell_runner'

module Carbide
  module TestSupport
    # An in-memory MinIO bucket behind a fake `mc`, plus a fake kubectl for the
    # credentials read and a forwarder that spawns nothing.
    #
    # This models the bucket rather than the CLI's output format, so the tests
    # can assert on what ends up stored — which is the thing that matters for
    # ordering (manifest last) and for reindexing.
    class FakeMc < ShellRunner
      MINIO_VERSION = "mc version RELEASE.2026-01-01T00-00-00Z (minio client)\n"

      def initialize(objects: {}, secret: { 'root-user' => 'root', 'root-password' => 'hunter2' },
                     mc_name: 'mcli', stat_error: 'Object does not exist')
        super()
        @objects = objects        # bucket key => contents
        @secret = secret
        @mc_name = mc_name
        @stat_error = stat_error
        @mc_calls = []
      end

      attr_reader :objects, :mc_calls

      def keys = @objects.keys.sort

      def mc_verbs = @mc_calls.map { |argv| argv.find { |a| !a.start_with?('-') && a != @mc_name && a != config_dir_of(argv) } }

      def run!(*args, stdin: nil, env: {})
        argv = args.map(&:to_s)
        case argv.first
        when @mc_name          then mc(argv)
        when 'kubectl'         then kubectl(argv)
        else super
        end
      end

      private

      def config_dir_of(argv)
        i = argv.index('--config-dir')
        i ? argv[i + 1] : nil
      end

      def mc(argv)
        return Result.new(MINIO_VERSION, '', 0) if argv.include?('--version')

        rest = argv.drop(1)
        rest = rest.drop(2) if rest.first == '--config-dir'
        @mc_calls << argv
        json = rest.delete('--json')
        verb = rest.shift
        send("mc_#{verb}", rest, json: !json.nil?)
      rescue NoMethodError
        Result.new('', "unsupported mc verb: #{verb}", 1)
      end

      def mc_alias(_rest, json: false) = Result.new('', '', 0)

      def mc_stat(rest, json: false)
        key = bucket_key(rest.last)
        @objects.key?(key) ? Result.new("Name: #{key}\n", '', 0) : Result.new('', @stat_error, 1)
      end

      # mirror copies every file under the source dir except those excluded, and
      # --remove deletes destination keys the source no longer has.
      def mc_mirror(rest, json: false)
        excludes = rest.select { |a| a.start_with?('--exclude=') }.map { |a| a.split('=', 2).last }
        paths = rest.reject { |a| a.start_with?('-') }
        source, dest = paths
        prefix = bucket_key(dest)
        Dir.glob(File.join(source, '**', '*')).each do |file|
          next unless File.file?(file)

          name = file.delete_prefix("#{source}/")
          next if excludes.include?(File.basename(name))

          @objects["#{prefix}/#{name}"] = File.read(file)
        end
        Result.new('', '', 0)
      end

      def mc_cp(rest, json: false)
        source, dest = rest.reject { |a| a.start_with?('-') }
        @objects[bucket_key(dest)] = File.read(source)
        Result.new('', '', 0)
      end

      def mc_rm(rest, json: false)
        prefix = bucket_key(rest.reject { |a| a.start_with?('-') }.last)
        @objects.delete_if { |key, _| key == prefix || key.start_with?("#{prefix}/") || key.start_with?(prefix) }
        Result.new('', '', 0)
      end

      def mc_cat(rest, json: false)
        key = bucket_key(rest.last)
        return Result.new('', 'Object does not exist', 1) unless @objects.key?(key)

        Result.new(@objects[key], '', 0)
      end

      def mc_ls(rest, json: false)
        prefix = bucket_key(rest.reject { |a| a.start_with?('-') }.last)
        matching = @objects.keys.select { |k| prefix.empty? || k.start_with?(prefix) }
        out = matching.map { |k| JSON.generate(key: k, size: @objects[k].bytesize) }.join("\n")
        Result.new("#{out}\n", '', 0)
      end

      # "carbide-tier/clients/carbide2-client/abc/manifest.json" -> the part
      # after the bucket, which is how the store addresses objects.
      def bucket_key(url)
        url.to_s.sub(%r{\Acarbide-tier/clients/?}, '').sub(%r{/\z}, '')
      end

      def kubectl(argv)
        key = argv.join(' ')[/jsonpath=\{\.data\.([a-z-]+)\}/, 1]
        return Result.new('', 'error: secret not found', 1) if key.nil? || !@secret.key?(key)

        Result.new(Base64.strict_encode64(@secret[key]), '', 0)
      end
    end

    # Hands back a port without spawning kubectl.
    class FakeForwarder
      Handle = Struct.new(:port, :stopped) do
        def stop = self.stopped = true
      end

      def initialize(port: 34_567)
        @port = port
        @handles = []
      end

      attr_reader :handles

      def start(namespace:, service:, workdir:, env: {})
        @started = { namespace: namespace, service: service, env: env }
        Handle.new(@port, false).tap { |h| @handles << h }
      end

      attr_reader :started
    end
  end
end
