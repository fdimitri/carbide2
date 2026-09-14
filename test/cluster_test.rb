# frozen_string_literal: true

require_relative 'test_helper'
require 'carbide_cluster'

# Carbide::Cluster#verify_pull! — the node-side check.
#
# Every one of these cases was a real deploy that got no useful signal: the
# refusal arrived as `helm --wait` expiring after five minutes, naming nothing.
# The errors asserted below are containerd's actual words from those runs.
class ClusterVerifyPullTest < Minitest::Test
  # A runner that answers `crictl pull` from a canned table and records argv.
  # Nothing here shells out — the point is which command is built and how its
  # failure text is read, and neither needs a node.
  class FakeCrictl < Carbide::TestSupport::ShellRunner
    def initialize(failures: {})
      super()
      @failures = failures # ref => stderr text
      @pulls = []
    end

    attr_reader :pulls

    def run!(*args, stdin: nil, env: {})
      argv = args.map(&:to_s)
      return super unless argv.include?('pull')

      @pulls << argv
      ref = argv.last
      err = @failures[ref]
      return Result.new('', err, 1) if err

      Result.new("Image is up to date for #{ref}\n", '', 0)
    end
  end

  def cluster(runner, backend: 'k3d')
    Carbide::Cluster.new(cmd: runner, quiet: runner, backend: backend,
                         name: 'carbide-experimental', server_root: '/tmp')
  end

  REF = 'reg.example:5009/ns/carbide2-control:abc123def456'

  def refusal(failures, backend: 'k3d', **creds)
    runner = FakeCrictl.new(failures: failures)
    err = assert_raises(Carbide::Cluster::PullRefused) do
      cluster(runner, backend: backend).verify_pull!([REF], **creds)
    end
    err.message
  end

  def test_a_pullable_ref_passes_quietly
    runner = FakeCrictl.new
    assert_nil cluster(runner).verify_pull!([REF])
    assert_equal 1, runner.pulls.size
  end

  # The one that cost an afternoon: the HOST resolved the registry and the node
  # did not, so every host-side check passed.
  def test_dns_failure_says_the_node_cannot_resolve
    message = refusal({ REF => 'failed to do request: Head "https://reg.example:5009/v2/": ' \
                             'dial tcp: lookup reg.example: no such host' })

    assert_includes message, REF
    assert_includes message, 'cannot resolve'
    assert_includes message, 'no such host'
  end

  def test_tls_failure_points_at_the_node_trust_store
    message = refusal({ REF => 'failed to verify certificate: x509: certificate signed by unknown authority' })

    assert_includes message, 'trust'
    assert_includes message, 'x509'
  end

  def test_auth_failure_is_not_reported_as_absent
    message = refusal({ REF => 'unexpected status from HEAD request: 401 Unauthorized' })

    assert_includes message, 'credentials'
    refute_includes message, 'build and push'
  end

  def test_a_missing_tag_says_to_build_it
    message = refusal({ REF => 'failed to resolve reference: not found' })

    assert_includes message, 'build and push'
  end

  # An unrecognized failure must still refuse, carrying containerd's own words
  # rather than a guess.
  def test_an_unclassified_failure_still_refuses
    message = refusal({ REF => 'some containerd error nobody has seen before' })

    assert_includes message, 'refused the pull'
    assert_includes message, 'nobody has seen before'
  end

  def test_credentials_are_passed_when_configured
    runner = FakeCrictl.new
    cluster(runner).verify_pull!([REF], username: 'u', password: 'p')

    assert_includes runner.pulls.first, '--creds'
    assert_includes runner.pulls.first, 'u:p'
  end

  # An anonymous registry must not get an empty --creds, which crictl rejects.
  def test_no_credentials_flag_without_a_username
    runner = FakeCrictl.new
    cluster(runner).verify_pull!([REF])

    refute_includes runner.pulls.first, '--creds'
  end

  # k3d's containerd is inside the node container; k3s's is on this host.
  def test_k3d_pulls_inside_the_node_container
    runner = FakeCrictl.new
    cluster(runner, backend: 'k3d').verify_pull!([REF])

    assert_equal %w[docker exec k3d-carbide-experimental-server-0 crictl pull], runner.pulls.first.first(5)
  end

  def test_k3s_pulls_on_the_host
    runner = FakeCrictl.new
    cluster(runner, backend: 'k3s').verify_pull!([REF])

    assert_equal %w[sudo k3s crictl pull], runner.pulls.first.first(4)
  end

  # node.backend none has no node to pull into; the check is not applicable
  # rather than failing.
  def test_backend_none_checks_nothing
    runner = FakeCrictl.new
    assert_nil cluster(runner, backend: 'none').verify_pull!([REF])
    assert_empty runner.pulls
  end

  def test_every_ref_is_checked_and_the_first_failure_names_itself
    other = 'reg.example:5009/ns/carbide2:zzz'
    runner = FakeCrictl.new(failures: { other => 'not found' })
    err = assert_raises(Carbide::Cluster::PullRefused) do
      cluster(runner).verify_pull!([REF, other])
    end

    assert_includes err.message, other
    assert_equal 2, runner.pulls.size
  end
end
