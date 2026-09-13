# frozen_string_literal: true

require_relative 'shell_runner'

module Carbide
  module TestSupport
    # A runner that executes git for real and fakes docker.
    #
    # The point of the tests that use it is the ARGV: which directory ends up as
    # the build context, which tags and labels are attached, whether build_time
    # appears once or twice. Those are where the bugs live, and none of them need
    # a docker daemon — but they do need real git, because worktree materialization
    # and dirty detection are the behavior under test.
    class FakeDocker < ShellRunner
      Recorded = Struct.new(:argv) do
        def to_s = argv.join(' ')
        def include_arg?(value) = argv.include?(value)
        def flag_values(flag) = argv.each_cons(2).select { |f, _| f == flag }.map(&:last)
      end

      def initialize(present_images: [], registry_tags: {}, push_fails: false,
                     manifest_error: 'manifest unknown', http_code: '200')
        super()
        @present_images = present_images   # refs `docker image inspect` finds
        @registry_tags  = registry_tags    # ref => true when the registry has it
        @push_fails     = push_fails
        @manifest_error = manifest_error
        @http_code      = http_code        # what Registry#check!'s curl sees
        @docker = []
      end

      attr_reader :docker, :present_images, :registry_tags

      def docker_commands(*prefix)
        @docker.select { |r| r.argv[1, prefix.length] == prefix }
      end

      def run!(*args, stdin: nil, env: {})
        argv = args.map(&:to_s)
        # Registry#check! shells curl for the /v2/ preflight. Left to the real
        # shell it would try to reach a host that does not exist, so every test
        # that pushes would fail on the preflight rather than on the thing it is
        # testing.
        return Result.new(@http_code, '', 0) if argv.first == 'curl'
        return super unless argv.first == 'docker'

        @docker << Recorded.new(argv)
        fake_docker(argv)
      end

      private

      def fake_docker(argv)
        case argv[1, 2]
        when %w[manifest inspect] then manifest_result(argv.last)
        when %w[image inspect]    then image_result(argv.last)
        when %w[buildx build]     then ok
        else
          argv[1] == 'push' ? push_result(argv.last) : ok
        end
      end

      def manifest_result(ref)
        return ok if @registry_tags[ref]

        Result.new('', @manifest_error, 1)
      end

      def image_result(ref)
        @present_images.include?(ref) ? ok : Result.new('', 'No such image', 1)
      end

      def push_result(ref)
        return Result.new('', 'denied: requested access to the resource is denied', 1) if @push_fails

        @registry_tags[ref] = true
        ok
      end

      def ok = Result.new('', '', 0)
    end
  end
end
