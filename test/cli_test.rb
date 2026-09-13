# frozen_string_literal: true

require_relative 'test_helper'
require 'stringio'
require_relative 'support/fake_docker'
require 'carbide_cli'

# ADR-043 §1-§3: the grammar, the parse-time context rules, and the exit codes.
# These are the parts of the CLI that have to be right before any of it runs.
class CliTest < Minitest::Test
  def setup
    @fixture = Carbide::TestSupport::GitFixture.new
    @defaults = File.join(@fixture.root, 'defaults.yaml')
    File.write(@defaults, <<~YAML)
      cluster:
        name: test-cluster
      control:
        namespace: carbide-system
      registry:
        mode: generic
        host: ''
        port: '5000'
        path: ''
        repos: ''
        catalog: auto
        username: ''
        password: ''
        pull-secret: ''
        ca: ''
        serve: false
      images:
        build: true
        shell: true
        push: false
        consume: auto
      minio:
        namespace: ''
        service: minio
        secret: minio-credentials
        mc: ''
      client-build:
        node-image: ''
    YAML
    @out = StringIO.new
    @err = StringIO.new
    @runner = Carbide::TestSupport::FakeDocker.new
  end

  def teardown = @fixture.destroy

  def run_cli(*argv, env: {})
    Dir.chdir(@fixture.root) do
      Carbide::CLI.run(argv, root: @fixture.root, defaults_path: @defaults,
                       out: @out, err: @err, cmd: @runner, quiet: @runner)
    end
  end

  def stderr = @err.string
  def stdout = @out.string

  # --- the grammar is enforced at parse --------------------------------------

  def test_no_arguments_prints_usage_as_a_usage_error
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli
    assert_match(/Usage: carcli/, stderr)
  end

  def test_an_unknown_subject_is_a_usage_error
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli('frontend', 'build')
    assert_match(/unknown subject 'frontend'/, stderr)
  end

  def test_an_unknown_verb_names_the_verbs_the_subject_has
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli('client', 'deploy')
    assert_match(/client has no verb 'deploy'/, stderr)
    assert_match(/state, build, populate/, stderr)
  end

  # The whole point of subject-dependent contexts: images are registry-only, so
  # this is a parse error rather than something that fails after a long build.
  def test_an_image_subject_refuses_the_minio_store_at_parse
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli('workspace', 'populate', 'minio')
    assert_match(/no store 'minio'/, stderr)
    assert_match(/workspace has: registry/, stderr)
  end

  def test_the_client_accepts_minio
    refute_equal Carbide::CLI::EXIT_USAGE, run_cli('client', 'detect', 'minio')
  end

  def test_a_verb_that_needs_a_store_says_so
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli('client', 'populate')
    assert_match(/needs a store \(registry \| minio \| both\)/, stderr)
  end

  def test_a_verb_that_takes_no_store_refuses_one
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli('client', 'state', 'minio')
    assert_match(/takes no store/, stderr)
  end

  # `both` names two stores, so it is meaningless for the verbs that act on one.
  def test_both_is_refused_for_detect_and_rm
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli('client', 'detect', 'both')
    assert_match(/'both' names two stores/, stderr)
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli('client', 'rm', 'both', 'abc')
  end

  def test_registry_has_its_own_verbs_and_no_store
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli('registry', 'populate', 'minio')
    assert_match(/registry has no verb 'populate'/, stderr)
  end

  def test_an_unknown_flag_is_a_usage_error_not_a_crash
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli('client', 'state', '--nope')
    assert_match(/invalid option/, stderr)
  end

  def test_an_invalid_source_value_is_rejected
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli('client', 'state', '--source', 'minio')
    assert_match(/--source/, stderr)
  end

  # --- --ref on a composite subject ------------------------------------------

  # workspace is server + worker, which is exactly why a single --ref cannot
  # address it.
  def test_ref_is_refused_for_a_composite_subject
    assert_equal Carbide::CLI::EXIT_USAGE, run_cli('workspace', 'state', '--ref', 'main')
    assert_match(/--ref cannot address it/, stderr)
    assert_match(/--server-ref/, stderr)
  end

  def test_ref_is_accepted_for_a_single_source_subject
    assert_equal Carbide::CLI::EXIT_OK, run_cli('client', 'state', '--ref', 'HEAD')
  end

  # --- state -----------------------------------------------------------------

  def test_state_prints_the_structured_identity_as_json
    assert_equal Carbide::CLI::EXIT_OK, run_cli('client', 'state', '--json')
    doc = JSON.parse(stdout)

    assert_equal 'client', doc['subject']
    assert_equal @fixture.short_head(:client), doc['sha']
    refute doc['dirty']
  end

  def test_state_is_tab_separated_by_default
    run_cli('client', 'state')

    assert_match(/^sha\t#{@fixture.short_head(:client)}$/, stdout)
  end

  def test_workspace_state_keeps_both_halves
    run_cli('workspace', 'state', '--json')
    doc = JSON.parse(stdout)

    assert_equal @fixture.short_head(:server), doc.dig('server', 'sha')
    assert_equal @fixture.short_head(:worker), doc.dig('worker', 'sha')
  end

  def test_shell_state_has_no_dirty_key
    run_cli('shell', 'state', '--json')

    refute JSON.parse(stdout).key?('dirty')
  end

  # --- exit codes ------------------------------------------------------------

  # detect's tri-state is only usable from a script as an exit code, and "the
  # registry is not configured" is unreachable, not absent.
  def test_detect_against_an_unconfigured_registry_is_unreachable
    assert_equal Carbide::CLI::EXIT_UNREACHABLE, run_cli('client', 'detect', 'registry')
    assert_match(/unreachable/, stdout)
  end

  def test_a_config_error_exits_4
    assert_equal Carbide::CLI::EXIT_CONFIG, run_cli('client', 'populate', 'registry')
    assert_match(/needs registry.host/, stderr)
  end

  def test_a_missing_config_file_exits_4_rather_than_aborting
    assert_equal Carbide::CLI::EXIT_CONFIG, run_cli('client', 'state', '--config', 'nope.yaml')
    assert_match(/config file not found/, stderr)
  end

  def test_an_unknown_config_key_names_it
    path = File.join(@fixture.root, 'bad.yaml')
    File.write(path, "registry:\n  hostt: nope\n")

    assert_equal Carbide::CLI::EXIT_CONFIG, run_cli('client', 'state', '--config', path)
    assert_match(/unknown key.*registry\.hostt/, stderr)
  end

  # The build-dirty gate is a refusal, not a failure: CI has to tell "you need a
  # flag" from "it broke".
  def test_a_dirty_build_without_the_flag_exits_5
    @fixture.write(:client, 'src/App.vue', "dirty\n")

    assert_equal Carbide::CLI::EXIT_REFUSED, run_cli('client', 'build')
    assert_match(/--allow-dirty/, stderr)
  end

  # --- the resolution line ---------------------------------------------------

  def test_every_run_prints_one_resolution_line_before_any_work
    run_cli('client', 'populate', 'registry')

    assert_match(/^resolved: subject=client source=auto target=registry dirty=no cluster=test-cluster/, stderr)
  end

  def test_the_resolution_line_names_the_config_layers_that_applied
    run_cli('client', 'build')

    assert_match(/config=defaults\.yaml/, stderr)
  end

  def test_the_resolution_line_reports_dirtiness
    @fixture.write(:client, 'src/App.vue', "dirty\n")
    run_cli('client', 'build', '--allow-dirty')

    assert_match(/dirty=yes/, stderr)
  end
end
