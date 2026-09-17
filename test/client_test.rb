# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/fake_docker'
require 'carbide_client'
require 'carbide_registry'

# ADR-043 §2 and §11: one source, two served families held as data, with the
# manifest composed at publish time rather than build time.
class ClientTest < Minitest::Test
  def setup
    @fixture = Carbide::TestSupport::GitFixture.new
    seed_client_source
    @docker = FakeNode.new
  end

  def teardown = @fixture.destroy

  # Fakes the node container by creating the dist the build would have produced,
  # so the argv assertions below run against a build that "worked".
  class FakeNode < Carbide::TestSupport::FakeDocker
    def fake_docker(argv)
      produce_dist(argv) if argv[1] == 'run'
      super
    end

    def produce_dist(argv)
      script = argv.last
      out = argv.each_cons(2).find { |f, v| f == '-v' && v.end_with?(':/out') }&.last.to_s.split(':').first
      return unless (mode = script[/--outDir \/out\/dist-(\w+)/, 1])

      dir = File.join(out, "dist-#{mode}")
      FileUtils.mkdir_p(File.join(dir, 'assets'))
      File.write(File.join(dir, 'index.html'), "<html>#{mode}</html>")
      File.write(File.join(dir, 'assets', 'app.js'), 'console.log(1)')
    end
  end

  def seed_client_source
    @fixture.write(:client, 'package.json', JSON.pretty_generate(
                                              'name' => 'carbide2-client', 'version' => '0.5.0'
                                            ))
    @fixture.write(:client, 'src/version.js', "export const CODENAME = 'Ferrari'\n")
    @fixture.write(:client, '.gitignore', "node_modules\ndist\n")
    @fixture.commit(:client, 'client source')
  end

  def client(registry: nil)
    subject = Carbide::Client.new(cmd: @docker, quiet: @docker, root: @fixture.root,
                                  registry: registry)
    subject.extend(Carbide::TestSupport::QuietLog)
    subject.identity.extend(Carbide::TestSupport::QuietLog)
    subject
  end

  def registry
    Carbide::Registry.new(cmd: @docker, quiet: @docker, host: 'registry.test', port: '5000')
  end

  # --- families as data ------------------------------------------------------

  def test_both_families_are_built_from_one_source
    built = nil
    client.build { |b| built = b.merge(dists: b[:dists].transform_values { |d| File.exist?(d) }) }

    assert_equal %w[carbide2-client carbide2-control], built[:dists].keys.sort
    assert built[:dists].values.all?
  end

  def test_npm_ci_runs_once_for_two_builds
    client.build { |_| nil }

    scripts = @docker.docker_commands('run').map { |r| r.argv.last }

    assert_equal 1, scripts.count { |s| s.include?('npm ci') }
    assert_equal 2, scripts.count { |s| s.include?('vite build') }
  end

  def test_each_family_gets_its_own_absolute_base
    client.build { |_| nil }

    scripts = @docker.docker_commands('run').map { |r| r.argv.last }
    sha = @fixture.short_head(:client)

    assert(scripts.any? { |s| s.include?("--base=/clients/carbide2-client/#{sha}/") })
    assert(scripts.any? { |s| s.include?("--base=/clients/carbide2-control/#{sha}/") })
  end

  # --- the build must not dirty the checkout ---------------------------------

  # dist-workspace / dist-control are not in the client's .gitignore, and an
  # untracked-but-not-ignored file is dirty by this tool's own rule — so a build
  # writing them into the working tree would make the NEXT build tag itself
  # -dirty because of the previous one.
  def test_output_is_written_outside_the_checkout
    client.build { |_| nil }

    @docker.docker_commands('run').each do |run|
      out_mount = run.flag_values('-v').find { |v| v.end_with?(':/out') }
      refute_nil out_mount
      refute out_mount.start_with?(@fixture.dir(:client)), "#{out_mount} is inside the checkout"
    end
  end

  def test_npm_home_points_outside_the_checkout_too
    client.build { |_| nil }

    @docker.docker_commands('run').each do |run|
      assert_includes run.argv, 'HOME=/out'
    end
  end

  def test_the_working_tree_is_still_clean_after_a_build
    subject = client
    subject.build { |_| nil }

    refute subject.dirty?, 'the build left something untracked in the checkout'
  end

  # --- dirty ------------------------------------------------------------------

  def test_build_refuses_a_dirty_tree_without_allow_dirty
    @fixture.write(:client, 'src/App.vue', "<template/>\n")

    err = assert_raises(Carbide::Client::Error) { client.build { |_| nil } }
    assert_match(/--allow-dirty/, err.message)
  end

  def test_a_dirty_build_carries_the_suffix_into_the_base_path
    @fixture.write(:client, 'src/App.vue', "<template/>\n")
    built = nil
    client.build(allow_dirty: true) { |b| built = b }

    assert built[:sha].end_with?('-dirty')
    scripts = @docker.docker_commands('run').map { |r| r.argv.last }
    assert(scripts.any? { |s| s.include?("--base=/clients/carbide2-client/#{built[:sha]}/") })
  end

  def test_an_explicit_ref_builds_a_worktree_and_is_clean
    pinned = @fixture.commit(:client, 'pinned')
    @fixture.write(:client, 'src/App.vue', "dirty\n")

    built = nil
    client.build(refs: { client: pinned }) { |b| built = b }

    assert_equal pinned[0, 12], built[:sha]
    app_mount = @docker.docker_commands('run').first.flag_values('-v').find { |v| v.end_with?(':/app') }
    assert_match(%r{/carbide-client-}, app_mount)
  end

  # --- version and the manifest ----------------------------------------------

  def test_version_and_codename_come_from_the_client_not_the_meta_release
    built = nil
    client.build { |b| built = b }

    assert_equal '0.5.0', built[:version]
    assert_equal 'Ferrari', built[:codename]
  end

  def test_the_manifest_is_written_at_publish_time_not_by_the_build
    subject = client
    subject.build do |built|
      dist = built[:dists].fetch('carbide2-client')

      refute File.exist?(File.join(dist, 'manifest.json')), 'build must not stamp it'

      subject.stamp_manifests(built, label: 'rc3')
      doc = JSON.parse(File.read(File.join(dist, 'manifest.json')))

      assert_equal 'carbide2-client', doc['family']
      assert_equal 'workspace', doc['mode']
      assert_equal 'rc3', doc['label']
      assert_equal '0.5.0', doc['version']
      assert_equal "/clients/carbide2-client/#{built[:sha]}/", doc['base']
    end
  end

  def test_both_families_share_one_build_time
    subject = client
    subject.build do |built|
      subject.stamp_manifests(built)
      times = built[:dists].values.map do |d|
        JSON.parse(File.read(File.join(d, 'manifest.json')))['build_time']
      end

      assert_equal 1, times.uniq.length
    end
  end

  def test_the_label_defaults_to_the_sha
    subject = client
    subject.build do |built|
      subject.stamp_manifests(built)
      doc = JSON.parse(File.read(File.join(built[:dists].fetch('carbide2-client'), 'manifest.json')))

      assert_equal built[:sha], doc['label']
    end
  end

  # Nothing enforces floors; they are written through exactly as given.
  def test_floors_are_passed_through_untouched
    subject = client
    subject.build do |built|
      subject.stamp_manifests(built, floors: { 'protocol' => '5' })
      doc = JSON.parse(File.read(File.join(built[:dists].fetch('carbide2-client'), 'manifest.json')))

      assert_equal({ 'protocol' => '5' }, doc['floors'])
    end
  end

  # --- the registry cache ----------------------------------------------------

  def test_the_cache_artifact_is_one_image_per_sha_with_a_directory_per_family
    subject = client(registry: registry)
    subject.build do |built|
      subject.cache_push(built)

      build_cmd = @docker.docker_commands('build').first
      context = build_cmd.argv.last
      # The context is gone by now, so assert on what was sent to build.
      assert_includes build_cmd.argv, subject.cache_ref(built[:sha])
      assert_includes build_cmd.argv, '--label'
      refute_nil context
    end
  end

  def test_cache_push_refuses_a_dirty_sha
    @fixture.write(:client, 'src/App.vue', "dirty\n")
    subject = client(registry: registry)

    subject.build(allow_dirty: true) do |built|
      assert_raises(Carbide::Client::Error) { subject.cache_push(built) }
      assert_empty @docker.docker_commands('push')
    end
  end

  def test_cache_pull_extracts_one_directory_per_family
    subject = client(registry: registry)
    Dir.mktmpdir do |into|
      dists = subject.cache_pull('abc123abc123', into: into)

      assert_equal %w[carbide2-client carbide2-control], dists.keys.sort
      copies = @docker.docker_commands('cp').map { |r| r.argv[2] }
      assert(copies.any? { |c| c.end_with?(':/workspace/.') })
      assert(copies.any? { |c| c.end_with?(':/control/.') })
    end
  end

  def test_cache_detect_is_tri_state
    subject = client(registry: registry)
    @docker.registry_tags["registry.test:5000/carbide2-client:abc123abc123"] = true

    assert_equal :present, subject.cache_detect('abc123abc123')
    assert_equal :absent, subject.cache_detect('ffffffffffff')
  end

  def test_cache_detect_without_a_registry_is_unreachable
    assert_equal :unreachable, client.cache_detect('abc123abc123')
  end
end
