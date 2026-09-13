# frozen_string_literal: true

# Runs the whole suite with no gems beyond minitest, which ships with ruby:
#
#   ruby test/run_all.rb
#
# A single file runs on its own the same way (ruby test/identity_test.rb).
Dir[File.join(__dir__, '*_test.rb')].sort.each { |f| require f }
