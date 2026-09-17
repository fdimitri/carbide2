# frozen_string_literal: true

require 'minitest/autorun'

LIB = File.expand_path('../scripts/lib', __dir__)
$LOAD_PATH.unshift(LIB) unless $LOAD_PATH.include?(LIB)

require_relative 'support/shell_runner'
require_relative 'support/git_fixture'

module Carbide
  module TestSupport
    # Silences Carbide::CommandRunner#log, which writes to stdout unconditionally.
    module QuietLog
      def log(_msg) = nil
    end
  end
end
