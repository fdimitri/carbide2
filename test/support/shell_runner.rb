# frozen_string_literal: true

require 'open3'

module Carbide
  module TestSupport
    # A real command runner with TTY::Command's return contract, for tests.
    #
    # The libs never `require 'tty-command'` — deploy.rb and build.rb install it
    # via bundler/inline and inject an instance, and every lib just calls
    # @cmd.run! / @cmd.run. This runner satisfies the same contract, so the tests
    # execute real git without pulling the gem into the test path.
    #
    # The contract the libs rely on, and the part worth stating because it is
    # easy to get wrong: `out, = cmd.run!(...)` works because TTY::Command::Result
    # implements #to_ary as [out, err]. Result below does the same. Anything the
    # libs use beyond out / err / success? is NOT modeled here, so a lib that
    # starts depending on more of TTY::Command's surface needs this updated with
    # it.
    class ShellRunner
      Result = Struct.new(:out, :err, :status) do
        def success? = status.zero?
        def failure? = !success?
        def to_ary   = [out, err]
        def to_a     = [out, err]
      end

      # printer:/uuid: are accepted and ignored so a test can construct this the
      # same way the scripts construct TTY::Command.
      def initialize(printer: nil, uuid: nil)
        @printer = printer
        @uuid = uuid
        @calls = []
      end

      attr_reader :calls

      # Never raises; the caller inspects success?.
      def run!(*args, stdin: nil, env: {})
        args = args.flat_map { |a| a.is_a?(String) ? a.split(' ') : a } if args.size == 1
        @calls << args
        out, err, status = Open3.capture3(env.transform_keys(&:to_s), *args.map(&:to_s),
                                          stdin_data: stdin.to_s)
        Result.new(out, err, status.exitstatus || 1)
      end

      # Raises on failure, like TTY::Command#run.
      def run(*args, stdin: nil, env: {})
        res = run!(*args, stdin: stdin, env: env)
        return res if res.success?

        raise "command failed (#{res.status}): #{args.join(' ')}\n#{res.err}"
      end
    end
  end
end
