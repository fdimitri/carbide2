# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/fake_docker'
require 'carbide_images'
require 'carbide_registry'

# ADR-043 §4/§5 as they land in the image path: tags come from Carbide::Identity,
# refs are materialized in worktrees rather than checked out in place, and both
# dirty gates are enforced in the mechanism.
class ImagesTest < Minitest::Test
  def setup
    @fixture = Carbide::TestSupport::GitFixture.new
    File.write(File.join(@fixture.root, 'manifest.yaml'),
               "version: 0.6.0-rc1\ncodename: magnum\n")
    # The meta root has to be a repo too: META_SHA is HEAD of it.
    system('git', 'init', '-q', @fixture.root)
    system('git', '-C', @fixture.root, 'config', 'user.email', 'test@carbide.invalid')
    system('git', '-C', @fixture.root, 'config', 'user.name', 'Carbide Test')
    system('git', '-C', @fixture.root, 'add', 'manifest.yaml')
    system('git', '-C', @fixture.root, 'commit', '-q', '-m', 'meta')
  end

  def teardown = @fixture.destroy

  # A real Carbide::Registry over the fake runner: prefix/ref construction and
  # the tri-state detect are the things under test, and neither needs a daemon.
  def registry(docker, host: 'registry.test', port: '5000', serve: false)
    Carbide::Registry.new(cmd: docker, quiet: docker, host: host, port: port, serve: serve)
  end

  def images(docker = nil, registry: nil)
    docker ||= Carbide::TestSupport::FakeDocker.new
    subject = Carbide::Images.new(cmd: docker, quiet: docker, root: @fixture.root,
                                  registry: registry)
    subject.extend(Carbide::TestSupport::QuietLog)
    subject.identity.extend(Carbide::TestSupport::QuietLog)
    [subject, docker]
  end

  # --- tags come from Identity ----------------------------------------------

  def test_workspace_tag_is_the_server_worker_pair
    subject, = images

    assert_equal "#{@fixture.short_head(:server)}-#{@fixture.short_head(:worker)}",
                 subject.image_tags[:workspace]
  end

  def test_shell_tag_is_the_dockerfile_blob_not_the_server_sha
    subject, = images

    refute_equal @fixture.short_head(:server), subject.image_tags[:shell]
    assert_equal 12, subject.image_tags[:shell].length
  end

  def test_a_dirty_tree_tags_dirty
    @fixture.write(:control, 'app.rb', "changed\n")
    subject, = images

    assert subject.image_tags[:control].end_with?('-dirty')
    assert subject.dirty?(:control)
  end

  # --- the build-dirty gate --------------------------------------------------

  def test_build_refuses_a_dirty_tree_without_allow_dirty
    @fixture.write(:worker, 'w.rb', "dirty\n")
    subject, = images

    err = assert_raises(Carbide::Images::DirtyRefused) do
      subject.build(components: [:workspace], quiet: true)
    end
    assert_match(/worker dirty/, err.message, 'names which half of the composite')
    assert_match(/--allow-dirty/, err.message)
  end

  def test_build_proceeds_with_allow_dirty_and_tags_dirty
    @fixture.write(:worker, 'w.rb', "dirty\n")
    docker = Carbide::TestSupport::FakeDocker.new
    subject, = images(docker, registry: registry(docker))

    built = subject.build(components: [:workspace], quiet: true, allow_dirty: true)

    assert built[:workspace].end_with?('-dirty'), built[:workspace]
    tags = docker.docker_commands('buildx', 'build').first.flag_values('-t')
    assert_includes tags, built[:workspace]
  end

  # :dev is a mutable pointer the containerd-import path overwrites every build,
  # so it deliberately does not carry the suffix. With no registry configured
  # that leaves a dirty build gated but otherwise unrecorded.
  def test_the_local_dev_tag_is_unaffected_by_dirtiness
    @fixture.write(:worker, 'w.rb', "dirty\n")
    subject, docker = images

    subject.build(components: [:workspace], quiet: true, allow_dirty: true)

    assert_equal ['carbide2:dev'], docker.docker_commands('buildx', 'build').first.flag_values('-t')
  end

  def test_shell_is_never_gated_because_it_cannot_be_dirty
    @fixture.write(:server, 'Dockerfile.shell', "FROM scratch\n")
    subject, = images

    subject.build(components: [:shell], quiet: true) # must not raise
    refute subject.dirty?(:shell)
  end

  # --- refs are worktrees, not in-place checkouts ----------------------------

  def test_a_ref_override_builds_from_a_worktree_not_the_submodule
    @fixture.write(:control, 'app.rb', "v1\n")
    pinned = @fixture.commit(:control, 'v1')
    @fixture.write(:control, 'app.rb', "v2 uncommitted\n")

    subject, docker = images
    subject.build(components: [:control], refs: { control: pinned }, quiet: true)

    context = docker.docker_commands('buildx', 'build').first.argv.last
    refute_equal @fixture.dir(:control), context, 'must not build the submodule in place'
    assert_match(%r{/carbide-wt-}, context)
  end

  def test_a_ref_override_leaves_the_submodule_checkout_untouched
    branch = @fixture.git(:control, 'rev-parse', '--abbrev-ref', 'HEAD').strip
    pinned = @fixture.commit(:control, 'a commit')
    @fixture.write(:control, 'app.rb', "uncommitted work\n")

    subject, = images
    subject.build(components: [:control], refs: { control: pinned }, quiet: true)

    assert_equal branch, @fixture.git(:control, 'rev-parse', '--abbrev-ref', 'HEAD').strip
    assert_equal "uncommitted work\n", File.read(File.join(@fixture.dir(:control), 'app.rb')),
                 'the working tree survives the build'
  end

  def test_a_ref_override_is_clean_even_when_the_tree_is_dirty
    pinned = @fixture.commit(:control, 'a commit')
    @fixture.write(:control, 'app.rb', "dirty\n")

    subject, = images

    assert subject.image_tags[:control].end_with?('-dirty')
    refute subject.tags_for(control: pinned)[:control].end_with?('-dirty')
    # ...so the gate does not fire for the pinned build.
    subject.build(components: [:control], refs: { control: pinned }, quiet: true)
  end

  def test_the_worktree_is_removed_after_the_build
    pinned = @fixture.commit(:control, 'a commit')
    subject, docker = images
    subject.build(components: [:control], refs: { control: pinned }, quiet: true)

    context = docker.docker_commands('buildx', 'build').first.argv.last

    refute File.exist?(context)
    assert_equal 1, @fixture.git(:control, 'worktree', 'list').lines.size
  end

  def test_two_ref_overrides_compose
    server_ref = @fixture.commit(:server, 'server move')
    worker_ref = @fixture.commit(:worker, 'worker move')

    subject, docker = images
    subject.build(components: [:workspace],
                  refs: { server: server_ref, worker: worker_ref }, quiet: true)

    build = docker.docker_commands('buildx', 'build').first
    worker_context = build.flag_values('--build-context').first

    assert_match(%r{/carbide-wt-}, build.argv.last, 'server context is a worktree')
    assert_match(%r{worker=.*/carbide-wt-}, worker_context, 'worker context is a worktree')
  end

  # --- metadata --------------------------------------------------------------

  def test_build_time_is_identical_in_the_label_and_the_build_arg
    subject, docker = images
    subject.build(components: %i[workspace control], quiet: true)

    docker.docker_commands('buildx', 'build').each do |build|
      next if build.argv.none? { |a| a.start_with?('BUILD_TIME=') }

      from_arg   = build.argv.find { |a| a.start_with?('BUILD_TIME=') }.split('=', 2).last
      from_label = build.argv.find { |a| a.start_with?('org.carbide.build_time=') }
                        .split('=', 2).last
      assert_equal from_arg, from_label
    end
  end

  def test_version_and_codename_come_from_the_manifest
    subject, docker = images
    subject.build(components: [:control], quiet: true)

    argv = docker.docker_commands('buildx', 'build').first.argv

    assert_includes argv, 'org.carbide.version=0.6.0-rc1'
    assert_includes argv, 'VERSION=0.6.0-rc1'
    assert_includes argv, 'CODENAME=magnum'
  end

  def test_sha_build_args_stay_bare_on_a_dirty_build
    @fixture.write(:control, 'app.rb', "dirty\n")
    docker = Carbide::TestSupport::FakeDocker.new
    subject, = images(docker, registry: registry(docker))
    subject.build(components: [:control], quiet: true, allow_dirty: true)

    argv = docker.docker_commands('buildx', 'build').first.argv
    control_sha = argv.find { |a| a.start_with?('CONTROL_SHA=') }

    refute_includes control_sha, 'dirty', 'the *_SHA args are commit provenance'
    assert(argv.any? { |a| a.end_with?('-dirty') }, 'dirtiness lives in the tag')
  end

  # --- registry interaction --------------------------------------------------

  def test_a_present_clean_tag_is_skipped
    docker = Carbide::TestSupport::FakeDocker.new
    subject, = images(docker, registry: registry(docker))
    docker.registry_tags[subject.image_ref(:control)] = true

    subject.build(components: [:control], quiet: true)

    assert_empty docker.docker_commands('buildx', 'build')
  end

  # <sha>-dirty names a class of working tree, not an instance, so its presence
  # is not information and must never short-circuit a build.
  def test_a_present_dirty_tag_is_not_skipped
    @fixture.write(:control, 'app.rb', "dirty\n")
    docker = Carbide::TestSupport::FakeDocker.new
    subject, = images(docker, registry: registry(docker))
    docker.registry_tags[subject.image_ref(:control)] = true

    subject.build(components: [:control], quiet: true, allow_dirty: true)

    assert_equal 1, docker.docker_commands('buildx', 'build').length
  end

  def test_all_present_is_false_while_anything_is_dirty
    docker = Carbide::TestSupport::FakeDocker.new
    subject, = images(docker, registry: registry(docker))
    Carbide::Images::ALL.each { |c| docker.registry_tags[subject.image_ref(c)] = true }

    assert subject.all_present?

    @fixture.write(:worker, 'w.rb', "dirty\n")
    fresh, = images(Carbide::TestSupport::FakeDocker.new.tap do |d|
      d.registry_tags.merge!(docker.registry_tags)
    end, registry: registry(docker))

    refute fresh.all_present?
  end

  # The push-dirty gate lives in the mechanism, so a caller that skips the CLI
  # cannot seed a shared store with an unidentifiable artifact.
  def test_push_refuses_a_dirty_tag_even_when_called_directly
    @fixture.write(:control, 'app.rb', "dirty\n")
    docker = Carbide::TestSupport::FakeDocker.new
    subject, = images(docker, registry: registry(docker))
    docker.present_images << subject.image_ref(:control)

    assert_raises(Carbide::Images::DirtyRefused) do
      subject.push(components: [:control])
    end
    assert_empty docker.docker_commands('push')
  end

  def test_push_refuses_a_tag_the_local_daemon_does_not_have
    docker = Carbide::TestSupport::FakeDocker.new
    subject, = images(docker, registry: registry(docker))

    err = assert_raises(Carbide::Images::Error) { subject.push(components: [:control]) }

    assert_match(/not present locally/, err.message)
    assert_match(/ImagePullBackOff/, err.message)
    assert_empty docker.docker_commands('push')
  end

  # --- detect ----------------------------------------------------------------

  def test_detect_is_tri_state
    docker = Carbide::TestSupport::FakeDocker.new
    subject, = images(docker, registry: registry(docker))
    docker.registry_tags[subject.image_ref(:control)] = true

    assert_equal :present, subject.detect(:control)
    assert_equal :absent,  subject.detect(:shell)
  end

  # A registry that is down, or one that answers 401 because login has not run,
  # must not read as "absent, build it".
  def test_detect_reports_unreachable_rather_than_absent
    docker = Carbide::TestSupport::FakeDocker.new(manifest_error: 'unauthorized: authentication required')
    subject, = images(docker, registry: registry(docker))

    assert_equal :unreachable, subject.detect(:control)
  end

  def test_detect_without_a_registry_is_unreachable_not_absent
    subject, = images

    assert_equal :unreachable, subject.detect(:control)
  end
end
