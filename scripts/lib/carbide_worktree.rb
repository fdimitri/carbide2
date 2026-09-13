# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require_relative 'carbide_command'

module Carbide
  # A throwaway detached worktree for an explicit ref (ADR-043 §5).
  #
  # "Explicit ref => always clean" is an invariant rather than a convention, and
  # this is the thing that makes it true: `git worktree add --detach` materializes
  # exactly the named commit, so no uncommitted state can reach the build.
  #
  # It replaces Images#with_refs, which checked the submodule out IN PLACE and
  # restored it in an ensure. That approach carried uncommitted changes into a
  # ref build, could not run twice on one host, and left the submodule detached
  # when it aborted. build-client already used a worktree; this is that, lifted
  # out of one script's trap so both the image and client paths share it.
  #
  # A BARE build (no ref) deliberately does not come through here: it builds the
  # working tree as it stands, dirty or not, because you should not have to
  # commit in order to build or test code.
  class Worktree
    include Carbide::CommandRunner

    Error = Class.new(StandardError)

    # Carbide::Worktree.with(cmd:, repo: dir, sha: sha) { |path| ... }
    def self.with(cmd:, repo:, sha:, prefix: 'carbide-wt', &block)
      new(cmd: cmd, repo: repo).with(sha, prefix: prefix, &block)
    end

    def initialize(cmd:, repo:)
      @cmd  = cmd
      @repo = repo
    end

    # Yields the path of a detached worktree at `sha`, and removes it afterwards
    # whether the block returns or raises. The mktmpdir happens before the add so
    # a failed add still has a path to clean up.
    def with(sha, prefix: 'carbide-wt')
      path = Dir.mktmpdir("#{prefix}-")
      begin
        add(sha, path)
        yield path
      ensure
        remove(path)
      end
    end

    private

    def add(sha, path)
      # --force twice over: mktmpdir has already created the path, and the same
      # commit may be checked out elsewhere (a second carcli on the same host).
      # Neither is a reason to refuse.
      res = @cmd.run!('git', '-C', @repo, 'worktree', 'add', '--detach', '--force', path, sha)
      return if res.success?

      raise Error, "git worktree add #{sha} failed in #{@repo}: #{res.err.to_s.strip}"
    end

    # Both steps, in this order. `worktree remove` unregisters it — leaving the
    # administrative entry behind is what accumulates stale worktrees in the
    # parent repo — and rm_rf covers the case where remove refused.
    def remove(path)
      @cmd.run!('git', '-C', @repo, 'worktree', 'remove', '--force', path)
      FileUtils.rm_rf(path)
    end
  end
end
