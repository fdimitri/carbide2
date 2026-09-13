# frozen_string_literal: true

require_relative 'test_helper'
require 'carbide_kubeconfig'

# ADR-043 §9: per-cluster kubeconfigs keyed by cluster.name, with all three
# names rewritten so "context == cluster.name" holds on every backend.
class KubeconfigTest < Minitest::Test
  # What k3s writes: cluster, user AND context are all `default`, on every
  # cluster, which is why context names cannot address a fleet.
  K3S = <<~YAML
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        certificate-authority-data: Y2Ex
        server: https://127.0.0.1:6443
      name: default
    users:
    - name: default
      user:
        client-certificate-data: Y2VydA==
        client-key-data: a2V5
    contexts:
    - context:
        cluster: default
        user: default
      name: default
    current-context: default
  YAML

  # What k3d writes: unique per cluster, but the user is admin@k3d-<name> — three
  # different names, not one repeated.
  K3D = <<~YAML
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        certificate-authority-data: Y2Ex
        server: https://0.0.0.0:6443
      name: k3d-carbide-dev
    users:
    - name: admin@k3d-carbide-dev
      user:
        client-certificate-data: Y2VydA==
    contexts:
    - context:
        cluster: k3d-carbide-dev
        user: admin@k3d-carbide-dev
      name: k3d-carbide-dev
    current-context: k3d-carbide-dev
  YAML

  def setup
    @dir = Dir.mktmpdir('carbide-kube-')
    @cmd = Carbide::TestSupport::ShellRunner.new
  end

  def teardown = FileUtils.rm_rf(@dir)

  def kubeconfig(name: 'prod-a', override: nil)
    subject = Carbide::Kubeconfig.new(cmd: @cmd, cluster_name: name, dir: @dir, override: override)
    subject.extend(Carbide::TestSupport::QuietLog)
    subject
  end

  # --- the path --------------------------------------------------------------

  def test_the_path_is_derived_from_the_cluster_name
    assert_equal File.join(@dir, 'prod-a.yaml'), kubeconfig.path
  end

  # The escape hatch is a flag, not a config key: a frozen cluster.yaml is read
  # by every node of the cluster, so an absolute path in it is a per-box fact in
  # a per-cluster file.
  def test_an_override_wins_over_the_derived_path
    assert_equal '/tmp/foreign.yaml', kubeconfig(override: '/tmp/foreign.yaml').path
  end

  def test_env_is_empty_until_the_file_exists
    subject = kubeconfig

    assert_empty subject.env
    subject.write!(K3S)
    assert_equal({ 'KUBECONFIG' => subject.path }, subject.env)
  end

  def test_readable_path_falls_back_to_the_default_kubeconfig
    assert_equal File.expand_path('~/.kube/config'), kubeconfig.readable_path
  end

  # --- the rename ------------------------------------------------------------

  def test_k3s_all_three_names_become_the_cluster_name
    doc = YAML.safe_load(File.read(kubeconfig.write!(K3S)))

    assert_equal ['prod-a'], doc['clusters'].map { |c| c['name'] }
    assert_equal ['prod-a'], doc['users'].map { |u| u['name'] }
    assert_equal ['prod-a'], doc['contexts'].map { |c| c['name'] }
    assert_equal 'prod-a', doc['current-context']
    assert_equal 'prod-a', doc.dig('contexts', 0, 'context', 'cluster')
    assert_equal 'prod-a', doc.dig('contexts', 0, 'context', 'user')
  end

  def test_k3d_three_different_source_names_all_become_the_cluster_name
    doc = YAML.safe_load(File.read(kubeconfig(name: 'dev').write!(K3D)))

    assert_equal ['dev'], doc['clusters'].map { |c| c['name'] }
    assert_equal ['dev'], doc['users'].map { |u| u['name'] }, 'admin@k3d-... is renamed too'
    assert_equal 'dev', doc['current-context']
  end

  def test_credentials_and_server_survive_the_rename
    doc = YAML.safe_load(File.read(kubeconfig.write!(K3S)))

    assert_equal 'https://127.0.0.1:6443', doc.dig('clusters', 0, 'cluster', 'server')
    assert_equal 'Y2Ex', doc.dig('clusters', 0, 'cluster', 'certificate-authority-data')
    assert_equal 'a2V5', doc.dig('users', 0, 'user', 'client-key-data')
  end

  # Two k3s clusters merged naively share a `default` cluster entry and
  # kubectl's merge is first-wins, so the second is silently unreachable. After
  # the rename there is nothing left to collide.
  def test_two_clusters_written_from_identical_sources_do_not_collide
    a = YAML.safe_load(File.read(kubeconfig(name: 'prod-a').write!(K3S)))
    b = YAML.safe_load(File.read(kubeconfig(name: 'prod-b').write!(K3S)))

    names = (a['clusters'] + b['clusters']).map { |c| c['name'] }

    assert_equal names, names.uniq
    assert_equal %w[prod-a prod-b], names.sort
  end

  def test_the_file_is_written_owner_only
    path = kubeconfig.write!(K3S)

    assert_equal '600', format('%o', File.stat(path).mode & 0o777)
  end

  # --- refusals --------------------------------------------------------------

  def test_a_merged_file_with_no_usable_current_context_is_refused
    merged = YAML.safe_load(K3D)
    merged['contexts'] << { 'name' => 'other', 'context' => { 'cluster' => 'other', 'user' => 'other' } }
    merged['current-context'] = 'neither'

    err = assert_raises(Carbide::Kubeconfig::Error) { kubeconfig.write!(YAML.dump(merged)) }
    assert_match(/2 contexts and no usable current-context/, err.message)
  end

  def test_a_merged_file_uses_its_current_context
    merged = YAML.safe_load(K3D)
    merged['clusters'] << { 'name' => 'other', 'cluster' => { 'server' => 'https://elsewhere' } }
    merged['users'] << { 'name' => 'other', 'user' => {} }
    merged['contexts'] << { 'name' => 'other', 'context' => { 'cluster' => 'other', 'user' => 'other' } }

    doc = YAML.safe_load(File.read(kubeconfig.write!(YAML.dump(merged))))

    assert_equal 'https://0.0.0.0:6443', doc.dig('clusters', 0, 'cluster', 'server')
  end

  def test_a_context_naming_a_missing_cluster_is_refused
    broken = YAML.safe_load(K3S)
    broken['clusters'] = []

    assert_raises(Carbide::Kubeconfig::Error) { kubeconfig.write!(YAML.dump(broken)) }
  end

  def test_junk_is_refused_rather_than_written
    assert_raises(Carbide::Kubeconfig::Error) { kubeconfig.write!('not: [a, kubeconfig') }
    refute File.exist?(kubeconfig.path)
  end
end
