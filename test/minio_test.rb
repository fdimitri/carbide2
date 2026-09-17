# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/fake_mc'
require 'carbide_minio'

# ADR-043 §7: the per-cluster serving tier. Ordering (manifest last), the
# tri-state detect, and index regeneration on both write paths.
class MinioTest < Minitest::Test
  def setup
    @mc = Carbide::TestSupport::FakeMc.new
    @forwarder = Carbide::TestSupport::FakeForwarder.new
    @dist = Dir.mktmpdir('carbide-dist-')
  end

  def teardown = FileUtils.rm_rf(@dist)

  def store(mc = @mc, kube_env: {})
    subject = Carbide::Minio.new(cmd: mc, quiet: mc, namespace: 'carbide-system',
                                 service: 'minio', secret: 'minio-credentials',
                                 kube_env: kube_env, mc: 'mcli', forwarder: @forwarder)
    subject.extend(Carbide::TestSupport::QuietLog)
    subject
  end

  def write_dist(files = { 'index.html' => '<html>', 'assets/app.js' => 'console.log(1)' },
                 manifest: { 'family' => 'carbide2-client', 'sha' => 'abc123abc123',
                             'commit_time' => '2026-09-01T00:00:00Z' })
    files.each do |name, content|
      path = File.join(@dist, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    File.write(File.join(@dist, 'manifest.json'), JSON.pretty_generate(manifest))
    @dist
  end

  # --- the mc probe ----------------------------------------------------------

  # On Debian `mc` is Midnight Commander; invoking it does not fail cleanly.
  def test_a_candidate_that_is_not_the_minio_client_is_rejected
    impostor = Carbide::TestSupport::FakeMc.new(mc_name: 'nothing-matches')
    def impostor.run!(*args, **kwargs)
      return Result.new('GNU Midnight Commander 4.8.29', '', 0) if args.first.to_s == 'mc'

      super
    end

    subject = Carbide::Minio.new(cmd: impostor, quiet: impostor, mc: nil,
                                 forwarder: @forwarder)

    assert_raises(Carbide::Minio::Error) { subject.mc_path }
  end

  def test_an_explicit_mc_is_verified_not_trusted
    assert_equal 'mcli', store.mc_path
  end

  # --- credentials and session -----------------------------------------------

  def test_credentials_are_base64_decoded_from_the_secret
    assert_equal %w[root hunter2], store.credentials
  end

  def test_a_missing_secret_is_unreachable_not_empty
    mc = Carbide::TestSupport::FakeMc.new(secret: {})

    assert_raises(Carbide::Minio::Unreachable) { store(mc).credentials }
  end

  def test_the_session_tears_the_port_forward_down_even_when_the_block_raises
    assert_raises(RuntimeError) do
      store.with_session { |_| raise 'upload blew up' }
    end

    assert_equal [true], @forwarder.handles.map(&:stopped)
  end

  def test_kube_env_reaches_the_forwarder
    store(kube_env: { 'KUBECONFIG' => '/home/frank/.carbide/kube/prod-a.yaml' })
      .with_session { |_| nil }

    assert_equal '/home/frank/.carbide/kube/prod-a.yaml', @forwarder.started[:env]['KUBECONFIG']
  end

  # --- upload ordering -------------------------------------------------------

  # mc mirror is a directory sync with no ordering guarantee, so the manifest
  # cannot ride along inside it: an interrupted upload would publish the
  # manifest before the assets it describes.
  def test_the_manifest_is_excluded_from_the_mirror_and_copied_after_it
    write_dist
    subject = store

    subject.with_session { |s| subject.upload(s, 'carbide2-client', 'abc123abc123', @dist) }

    mirror = @mc.mc_calls.find { |argv| argv.include?('mirror') }
    assert_includes mirror, '--exclude=manifest.json'

    verbs = @mc.mc_calls.map { |argv| argv[3] }
    assert_operator verbs.index('mirror'), :<, verbs.index('cp'), 'mirror runs before the manifest cp'
  end

  def test_upload_stores_the_assets_and_the_manifest_under_family_and_sha
    write_dist
    subject = store

    subject.with_session { |s| subject.upload(s, 'carbide2-client', 'abc123abc123', @dist) }

    assert_equal ['carbide2-client/abc123abc123/assets/app.js',
                  'carbide2-client/abc123abc123/index.html',
                  'carbide2-client/abc123abc123/manifest.json'], @mc.keys
  end

  def test_upload_refuses_a_dist_with_no_manifest
    FileUtils.mkdir_p(@dist)
    File.write(File.join(@dist, 'index.html'), '<html>')
    subject = store

    assert_raises(Carbide::Minio::Error) do
      subject.with_session { |s| subject.upload(s, 'carbide2-client', 'abc', @dist) }
    end
  end

  # --- detect ----------------------------------------------------------------

  def test_detect_is_present_only_once_the_manifest_lands
    write_dist
    subject = store

    subject.with_session do |s|
      assert_equal :absent, subject.detect(s, 'carbide2-client', 'abc123abc123')
      subject.upload(s, 'carbide2-client', 'abc123abc123', @dist)
      assert_equal :present, subject.detect(s, 'carbide2-client', 'abc123abc123')
    end
  end

  # "the cluster is down" must not read as "absent, build it".
  def test_detect_reports_unreachable_when_the_failure_is_not_a_missing_object
    mc = Carbide::TestSupport::FakeMc.new(stat_error: 'Unable to initialize new alias from the provided credentials')
    subject = store(mc)

    subject.with_session do |s|
      assert_equal :unreachable, subject.detect(s, 'carbide2-client', 'abc123abc123')
    end
  end

  # detect deliberately does not require the index entry: a manifest present but
  # unindexed is invisible to the loaders and is NOT auto-healed by re-running
  # populate. --force is the recovery.
  def test_detect_ignores_the_index_so_an_unindexed_build_still_reads_present
    write_dist
    subject = store

    subject.with_session do |s|
      subject.upload(s, 'carbide2-client', 'abc123abc123', @dist)

      assert_equal :present, subject.detect(s, 'carbide2-client', 'abc123abc123')
      refute subject.indexed?(s, 'carbide2-client', 'abc123abc123'), 'no reindex ran'
    end
  end

  # --- the index -------------------------------------------------------------

  def test_reindex_rebuilds_from_the_manifests_actually_present
    subject = store

    subject.with_session do |s|
      write_dist(manifest: { 'family' => 'carbide2-client', 'sha' => 'aaaaaaaaaaaa',
                             'commit_time' => '2026-09-01T00:00:00Z' })
      subject.upload(s, 'carbide2-client', 'aaaaaaaaaaaa', @dist)
      write_dist(manifest: { 'family' => 'carbide2-control', 'sha' => 'bbbbbbbbbbbb',
                             'commit_time' => '2026-09-02T00:00:00Z' })
      subject.upload(s, 'carbide2-control', 'bbbbbbbbbbbb', @dist)

      index = subject.reindex(s)

      assert_equal %w[carbide2-client carbide2-control], index['families'].keys.sort
      assert subject.indexed?(s, 'carbide2-client', 'aaaaaaaaaaaa')
    end
  end

  def test_remove_then_reindex_drops_the_build_from_the_index
    subject = store

    subject.with_session do |s|
      write_dist(manifest: { 'family' => 'carbide2-client', 'sha' => 'aaaaaaaaaaaa',
                             'commit_time' => '2026-09-01T00:00:00Z' })
      subject.upload(s, 'carbide2-client', 'aaaaaaaaaaaa', @dist)
      subject.reindex(s)

      subject.remove(s, 'carbide2-client', 'aaaaaaaaaaaa')
      subject.reindex(s)

      refute subject.indexed?(s, 'carbide2-client', 'aaaaaaaaaaaa')
      assert_equal ['registry.json'], @mc.keys
    end
  end

  # The raw listing is the only thing that works when the index is missing or
  # wrong — which is exactly the state detect declines to heal.
  def test_objects_lists_the_bucket_without_consulting_the_index
    write_dist
    subject = store

    subject.with_session do |s|
      subject.upload(s, 'carbide2-client', 'abc123abc123', @dist)

      assert_nil subject.read_index(s), 'precondition: no index object yet'
      assert_includes subject.objects(s), 'carbide2-client/abc123abc123/manifest.json'
    end
  end

  def test_a_corrupt_index_object_reads_as_nil_rather_than_raising
    subject = store

    subject.with_session do |s|
      @mc.objects['registry.json'] = '{not json'

      assert_nil subject.read_index(s)
    end
  end
end
