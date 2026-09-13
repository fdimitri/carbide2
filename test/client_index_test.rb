# frozen_string_literal: true

require_relative 'test_helper'
require 'carbide_client_index'

# ADR-043 §7: clients/registry.json, rebuilt from scratch on every publish and
# every removal. Pure, so the ordering rules are testable without a bucket.
class ClientIndexTest < Minitest::Test
  NOW = Time.utc(2026, 9, 13, 4, 5, 6)

  def manifest(family:, sha:, commit_time: nil, build_time: nil, **rest)
    { 'family' => family, 'sha' => sha, 'mode' => family == 'carbide2-control' ? 'control' : 'workspace',
      'commit_time' => commit_time, 'build_time' => build_time }.compact.merge(rest)
  end

  def test_groups_by_family
    index = Carbide::ClientIndex.build([
      manifest(family: 'carbide2-client',  sha: 'aaaaaaaaaaaa', commit_time: '2026-09-01T00:00:00Z'),
      manifest(family: 'carbide2-control', sha: 'bbbbbbbbbbbb', commit_time: '2026-09-02T00:00:00Z')
    ], now: NOW)

    assert_equal %w[carbide2-client carbide2-control], Carbide::ClientIndex.families(index).sort
    assert_equal %w[aaaaaaaaaaaa], Carbide::ClientIndex.shas(index, 'carbide2-client')
  end

  # build_time is just when the script ran, so building an OLD commit today
  # would otherwise look newer than the tip.
  def test_orders_newest_first_by_commit_time_not_build_time
    old_commit_built_today = manifest(family: 'carbide2-client', sha: 'old000000000',
                                      commit_time: '2026-01-01T00:00:00Z',
                                      build_time: '2026-09-13T00:00:00Z')
    tip = manifest(family: 'carbide2-client', sha: 'tip000000000',
                   commit_time: '2026-09-12T00:00:00Z',
                   build_time: '2026-09-12T00:00:00Z')

    index = Carbide::ClientIndex.build([old_commit_built_today, tip], now: NOW)

    assert_equal %w[tip000000000 old000000000], Carbide::ClientIndex.shas(index, 'carbide2-client')
  end

  def test_falls_back_to_build_time_for_manifests_without_commit_time
    legacy = manifest(family: 'carbide2-client', sha: 'legacy000000', build_time: '2026-09-05T00:00:00Z')
    newer  = manifest(family: 'carbide2-client', sha: 'newer0000000', commit_time: '2026-09-06T00:00:00Z')

    index = Carbide::ClientIndex.build([legacy, newer], now: NOW)

    assert_equal %w[newer0000000 legacy000000], Carbide::ClientIndex.shas(index, 'carbide2-client')
  end

  # The jq version tie-broke on reverse *input* order, i.e. on however mc
  # happened to list the bucket. Two regenerations of an unchanged bucket must
  # produce identical bytes, or a diff means nothing.
  def test_ties_break_deterministically_regardless_of_input_order
    same_time = '2026-09-10T00:00:00Z'
    a = manifest(family: 'carbide2-client', sha: 'aaaaaaaaaaaa', commit_time: same_time)
    b = manifest(family: 'carbide2-client', sha: 'bbbbbbbbbbbb', commit_time: same_time)

    one = Carbide::ClientIndex.build([a, b], now: NOW)
    two = Carbide::ClientIndex.build([b, a], now: NOW)

    assert_equal Carbide::ClientIndex.shas(one, 'carbide2-client'),
                 Carbide::ClientIndex.shas(two, 'carbide2-client')
    assert_equal Carbide::ClientIndex.dump(one), Carbide::ClientIndex.dump(two)
  end

  def test_empty_bucket_yields_an_empty_families_map
    index = Carbide::ClientIndex.build([], now: NOW)

    assert_equal({}, index['families'])
    assert_equal '2026-09-13T04:05:06Z', index['generated']
  end

  # A manifest with no family cannot be served from /clients/<family>/<sha>/, so
  # a corrupt or partial upload must not take the rest of the index with it.
  def test_a_manifest_without_a_family_is_dropped_not_indexed_under_nil
    index = Carbide::ClientIndex.build([
      manifest(family: 'carbide2-client', sha: 'aaaaaaaaaaaa', commit_time: '2026-09-01T00:00:00Z'),
      { 'sha' => 'orphan000000', 'commit_time' => '2026-09-02T00:00:00Z' },
      nil
    ], now: NOW)

    assert_equal %w[carbide2-client], Carbide::ClientIndex.families(index)
    refute_includes Carbide::ClientIndex.dump(index), 'orphan000000'
  end

  def test_includes_answers_the_serving_layer_question
    index = Carbide::ClientIndex.build([
      manifest(family: 'carbide2-client', sha: 'aaaaaaaaaaaa', commit_time: '2026-09-01T00:00:00Z')
    ], now: NOW)

    assert Carbide::ClientIndex.includes?(index, 'carbide2-client', 'aaaaaaaaaaaa')
    refute Carbide::ClientIndex.includes?(index, 'carbide2-client', 'bbbbbbbbbbbb')
    refute Carbide::ClientIndex.includes?(index, 'carbide2-control', 'aaaaaaaaaaaa')
  end

  def test_generated_is_zulu_seconds_matching_the_existing_object
    index = Carbide::ClientIndex.build([], now: Time.at(0))

    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, index['generated'])
  end

  def test_build_does_not_mutate_the_caller_s_time
    now = Time.now
    zone_before = now.zone
    Carbide::ClientIndex.build([], now: now)

    assert_equal zone_before, now.zone
  end

  def test_round_trips_through_dump_and_parse
    index = Carbide::ClientIndex.build([
      manifest(family: 'carbide2-client', sha: 'aaaaaaaaaaaa', commit_time: '2026-09-01T00:00:00Z',
               'label' => 'rc3', 'version' => '0.6.0-rc1')
    ], now: NOW)

    assert_equal index, Carbide::ClientIndex.parse(Carbide::ClientIndex.dump(index))
  end

  def test_parse_returns_nil_on_a_corrupt_object
    assert_nil Carbide::ClientIndex.parse('{not json')
  end
end
