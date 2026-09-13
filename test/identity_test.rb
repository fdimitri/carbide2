# frozen_string_literal: true

require_relative 'test_helper'
require 'carbide_identity'

# ADR-043 §4 (identity per subject) and §5 (clean vs dirty).
class IdentityTest < Minitest::Test
  def setup
    @fixture = Carbide::TestSupport::GitFixture.new
    @cmd = Carbide::TestSupport::ShellRunner.new
    @identity = Carbide::Identity.new(cmd: @cmd, root: @fixture.root)
    @identity.extend(Carbide::TestSupport::QuietLog)
  end

  def teardown = @fixture.destroy

  # --- single-source subjects ------------------------------------------------

  def test_clean_client_is_its_short_head_with_no_suffix
    state = @identity.state(:client)

    assert_equal @fixture.short_head(:client), state[:sha]
    assert_equal 12, state[:sha].length
    refute state[:dirty]
    assert_equal state[:sha], state[:tag]
  end

  def test_modified_tracked_file_is_dirty
    @fixture.write(:client, 'README', "changed\n")

    state = @identity.state(:client)

    assert state[:dirty]
    assert_equal "#{state[:sha]}-dirty", state[:tag]
  end

  # git describe --dirty would call this clean; the file is built into the
  # artifact all the same, which is why the test is status --porcelain.
  def test_untracked_but_not_ignored_file_is_dirty
    @fixture.write(:client, 'src/new_thing.js', "export const x = 1\n")

    assert @identity.state(:client)[:dirty]
  end

  def test_ignored_file_is_not_dirty
    @fixture.write(:client, '.gitignore', "node_modules/\n")
    @fixture.commit(:client, 'add gitignore')
    @fixture.write(:client, 'node_modules/pkg/index.js', "module.exports = 1\n")

    refute @identity.state(:client)[:dirty]
  end

  # The invariant that makes --source=auto usable: an explicit ref is
  # materialized in a detached worktree, so the working tree cannot reach it.
  def test_explicit_ref_is_clean_even_when_the_working_tree_is_dirty
    target = @fixture.commit(:client, 'a commit to name')
    @fixture.write(:client, 'README', "uncommitted\n")

    assert @identity.state(:client)[:dirty], 'precondition: the tree is dirty'

    state = @identity.state(:client, refs: { client: target })

    refute state[:dirty]
    assert_equal target[0, 12], state[:sha]
    assert_equal state[:sha], state[:tag]
  end

  def test_unresolvable_ref_raises
    err = assert_raises(Carbide::Identity::Error) do
      Carbide::Identity.new(cmd: @cmd, root: @fixture.root, fetch_missing: false)
                       .state(:client, refs: { client: 'no-such-ref' })
    end
    assert_match(/cannot resolve 'no-such-ref'/, err.message)
  end

  def test_unknown_subject_raises
    assert_raises(Carbide::Identity::Error) { @identity.state(:frontend) }
  end

  def test_missing_checkout_raises_with_the_submodule_hint
    FileUtils.rm_rf(@fixture.dir(:client))

    err = assert_raises(Carbide::Identity::Error) { @identity.state(:client) }
    assert_match(/git submodule update --init/, err.message)
  end

  # --- workspace: the composite ----------------------------------------------

  def test_workspace_tag_is_the_pair_and_state_keeps_both_halves
    state = @identity.state(:workspace)

    assert_equal @fixture.short_head(:server), state[:server][:sha]
    assert_equal @fixture.short_head(:worker), state[:worker][:sha]
    assert_equal "#{state[:server][:sha]}-#{state[:worker][:sha]}", state[:tag]
    refute state[:dirty]
  end

  def test_workspace_is_dirty_when_only_the_worker_is
    @fixture.write(:worker, 'worker.rb', "puts 1\n")

    state = @identity.state(:workspace)

    refute state[:server][:dirty]
    assert state[:worker][:dirty]
    assert state[:dirty]
    assert_equal "#{state[:server][:sha]}-#{state[:worker][:sha]}-dirty", state[:tag]
  end

  def test_workspace_dirty_on_both_sides_still_carries_one_suffix
    @fixture.write(:server, 'server.rb', "puts 1\n")
    @fixture.write(:worker, 'worker.rb', "puts 1\n")

    tag = @identity.tag(:workspace)

    assert_equal 1, tag.scan('-dirty').length
    assert tag.end_with?('-dirty')
  end

  def test_workspace_takes_a_ref_per_component
    server_ref = @fixture.commit(:server, 'server moves')
    @fixture.write(:worker, 'worker.rb', "dirty\n")

    state = @identity.state(:workspace, refs: { server: server_ref })

    assert_equal server_ref[0, 12], state[:server][:sha]
    refute state[:server][:dirty], 'the pinned half is clean'
    assert state[:worker][:dirty], 'the unpinned half still reports the tree'
    assert state[:dirty]
  end

  # --- shell: content-addressed, never dirty ---------------------------------

  def test_shell_has_no_dirty_key_at_all
    state = @identity.state(:shell)

    refute state.key?(:dirty)
    assert_equal state[:sha], state[:tag]
    refute @identity.dirty?(:shell)
  end

  def test_shell_hash_changes_on_an_uncommitted_edit_without_a_suffix
    before = @identity.tag(:shell)
    @fixture.write(:server, 'Dockerfile.shell', "FROM debian:trixie\n")
    after = @identity.tag(:shell)

    refute_equal before, after
    refute after.include?('dirty')
  end

  # An unrelated commit in the server repo must not move the shell tag — that is
  # the whole point of hashing the file rather than the repo: a docs or app
  # commit should not rebuild a ~4GB image.
  def test_shell_hash_is_unmoved_by_an_unrelated_commit
    before = @identity.tag(:shell)
    @fixture.write(:server, 'app/models/thing.rb', "class Thing; end\n")
    @fixture.commit(:server, 'unrelated change')

    assert_equal before, @identity.tag(:shell)
  end

  def test_shell_with_an_explicit_ref_reads_the_committed_blob_not_the_tree
    @fixture.write(:server, 'Dockerfile.shell', "FROM debian:trixie\n")
    pinned = @fixture.commit(:server, 'bump base image')
    committed = @identity.tag(:shell)

    @fixture.write(:server, 'Dockerfile.shell', "FROM scratch\n")
    refute_equal committed, @identity.tag(:shell), 'precondition: the tree differs'

    assert_equal committed, @identity.tag(:shell, refs: { server: pinned })
  end
end
