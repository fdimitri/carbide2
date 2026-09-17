# frozen_string_literal: true

require_relative 'test_helper'
require 'carbide_worktree'

# ADR-043 §5: an explicit ref is materialized in a detached worktree, which is
# what makes "explicit ref => always clean" an invariant rather than a habit.
class WorktreeTest < Minitest::Test
  def setup
    @fixture = Carbide::TestSupport::GitFixture.new
    @cmd = Carbide::TestSupport::ShellRunner.new
    @repo = @fixture.dir(:client)
  end

  def teardown = @fixture.destroy

  def test_materializes_the_named_commit_not_the_working_tree
    @fixture.write(:client, 'app.js', "const v = 1\n")
    pinned = @fixture.commit(:client, 'v1')
    @fixture.write(:client, 'app.js', "const v = 999 // uncommitted\n")

    seen = nil
    Carbide::Worktree.with(cmd: @cmd, repo: @repo, sha: pinned) do |path|
      seen = File.read(File.join(path, 'app.js'))
    end

    assert_equal "const v = 1\n", seen
  end

  def test_an_untracked_file_does_not_reach_the_worktree
    pinned = @fixture.commit(:client, 'base')
    @fixture.write(:client, 'sneaky.js', "leak\n")

    present = nil
    Carbide::Worktree.with(cmd: @cmd, repo: @repo, sha: pinned) do |path|
      present = File.exist?(File.join(path, 'sneaky.js'))
    end

    refute present
  end

  def test_the_worktree_is_detached_so_the_parent_checkout_is_undisturbed
    branch_before = @fixture.git(:client, 'rev-parse', '--abbrev-ref', 'HEAD').strip
    pinned = @fixture.commit(:client, 'another')

    Carbide::Worktree.with(cmd: @cmd, repo: @repo, sha: pinned) { |_| nil }

    assert_equal branch_before, @fixture.git(:client, 'rev-parse', '--abbrev-ref', 'HEAD').strip
  end

  # Leaving the administrative entry behind is what accumulates stale worktrees,
  # so removal has to unregister as well as delete.
  def test_cleanup_removes_the_directory_and_the_registration
    pinned = @fixture.commit(:client, 'base')
    captured = nil

    Carbide::Worktree.with(cmd: @cmd, repo: @repo, sha: pinned) do |path|
      captured = path
      assert File.directory?(path)
    end

    refute File.exist?(captured)
    assert_equal 1, @fixture.git(:client, 'worktree', 'list').lines.size
  end

  def test_cleanup_runs_when_the_block_raises
    pinned = @fixture.commit(:client, 'base')
    captured = nil

    assert_raises(RuntimeError) do
      Carbide::Worktree.with(cmd: @cmd, repo: @repo, sha: pinned) do |path|
        captured = path
        raise 'build blew up'
      end
    end

    refute File.exist?(captured)
    assert_equal 1, @fixture.git(:client, 'worktree', 'list').lines.size
  end

  def test_two_worktrees_of_the_same_commit_coexist
    pinned = @fixture.commit(:client, 'base')

    Carbide::Worktree.with(cmd: @cmd, repo: @repo, sha: pinned) do |first|
      Carbide::Worktree.with(cmd: @cmd, repo: @repo, sha: pinned) do |second|
        refute_equal first, second
        assert File.directory?(first)
        assert File.directory?(second)
      end
    end

    assert_equal 1, @fixture.git(:client, 'worktree', 'list').lines.size
  end

  def test_an_unresolvable_sha_raises_and_leaves_nothing_behind
    err = assert_raises(Carbide::Worktree::Error) do
      Carbide::Worktree.with(cmd: @cmd, repo: @repo, sha: 'deadbeefdeadbeef') { |_| nil }
    end

    assert_match(/worktree add/, err.message)
    assert_equal 1, @fixture.git(:client, 'worktree', 'list').lines.size
  end
end
