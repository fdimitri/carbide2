# frozen_string_literal: true

module Carbide
  # Output + external-command helpers shared by the deploy orchestrator and
  # every lib module. Includers must set @quiet (a null-printer TTY::Command)
  # for quiet_run to capture against.
  module CommandRunner
    def log(msg) = puts("\e[1;34m==>\e[0m #{msg}")

    def blank?(v) = v.nil? || v.to_s.strip.empty?

    # Run a long, noisy external command without streaming its (often red,
    # alarming-looking) output. Print one friendly line up front and only dump
    # the captured output if the command actually fails.
    def quiet_run(msg, *cmd_args, env: {})
      log msg
      result = @quiet.run!(*cmd_args, env: env)
      return result if result.success?

      $stdout.write(result.out)
      $stderr.write(result.err)
      abort "\e[1;31mxx\e[0m failed (output above): #{msg}"
    end
  end
end
