# frozen_string_literal: true

require_relative 'test_helper'
require 'carbide_node'

# The containerd registry config deploy.rb writes into a k3d node.
#
# The bug these pin: with registry.ca empty, the generator emitted the endpoint
# key with a null body — configuring nothing, while still differing from the
# node's file often enough to trigger a write and a node restart on every
# deploy. Observed in a real node as:
#
#   configs:
#     "10.250.0.54:5009":
class NodeRegistriesYamlTest < Minitest::Test
  Reg = Struct.new(:endpoint, :ca_path, keyword_init: true)

  def node(ca_path: nil, endpoint: '10.250.0.54:5009', pull: true)
    n = Carbide::Node.allocate
    n.instance_variable_set(:@registry, Reg.new(endpoint: endpoint, ca_path: ca_path))
    n.instance_variable_set(:@pull, pull)
    n.instance_variable_set(:@name, 'carbide-experimental')
    n
  end

  def yaml_for(**kwargs) = node(**kwargs).send(:k3d_registries_yaml, kwargs[:ca_path])

  def test_no_ca_writes_nothing_at_all
    assert_equal '', yaml_for(ca_path: nil)
  end

  # The specific shape that shipped: a key with no value under it.
  def test_the_endpoint_key_is_never_emitted_without_a_body
    refute_match(/configs:/, yaml_for(ca_path: nil))
    refute_match(/10\.250\.0\.54/, yaml_for(ca_path: nil))
  end

  def test_a_ca_produces_a_tls_block_under_the_endpoint
    out = yaml_for(ca_path: '/tmp/ca.pem')

    assert_includes out, 'configs:'
    assert_includes out, '"10.250.0.54:5009":'
    assert_includes out, 'tls:'
    assert_includes out, 'ca_file:'
  end

  # Whatever is emitted has to parse, and the endpoint's value has to be a
  # mapping rather than null — that was the actual defect.
  def test_the_emitted_document_parses_with_a_mapping_under_the_endpoint
    require 'yaml'
    doc = YAML.safe_load(yaml_for(ca_path: '/tmp/ca.pem'))

    assert_kind_of Hash, doc['configs']['10.250.0.54:5009']
    refute_nil doc['configs']['10.250.0.54:5009']['tls']
  end

  # k3d's create-time flag must not point at an empty file either.
  def test_create_args_are_empty_when_there_is_nothing_to_configure
    assert_empty node(ca_path: nil).send(:k3d_registry_create_args)
  end

  def test_create_args_mount_the_ca_and_name_the_config
    args = node(ca_path: '/tmp/ca.pem').send(:k3d_registry_create_args)

    assert_includes args, '--registry-config'
    assert_includes args, '--volume'
    assert(args.any? { |a| a.to_s.start_with?('/tmp/ca.pem:') })
  end

  # A box that does not pull has no reason to configure a registry at all.
  def test_create_args_are_empty_when_this_box_does_not_pull
    assert_empty node(ca_path: '/tmp/ca.pem', pull: false).send(:k3d_registry_create_args)
  end
end
