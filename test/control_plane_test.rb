# frozen_string_literal: true

require_relative 'test_helper'
require 'carbide_control_plane'

# helm's --set-string parser splits on commas, so any value carrying one has to
# arrive escaped. These assert the escaping itself rather than the full helm
# invocation: allocate skips the constructor, because the method under test
# reads no instance state and building a real ControlPlane would drag in an
# Images, a cluster interface and a command runner for a string transform.
class ControlPlaneSetStringTest < Minitest::Test
  def setup
    @cp = Carbide::ControlPlane.allocate
  end

  def values_for(key, value)
    args = []
    @cp.send(:push_set_string, args, key, value)
    assert_equal ['--set-string'], args.each_slice(2).map(&:first)
    args[1]
  end

  # The reported failure: helm answered
  #   key "carbide2-shell" has no value (cannot end with ,)
  # and the release never rendered.
  def test_commas_in_a_repo_list_are_escaped
    assert_equal 'registry.repos=carbide2\,carbide2-shell\,carbide2-control\,carbide2-client',
                 values_for('registry.repos', 'carbide2,carbide2-shell,carbide2-control,carbide2-client')
  end

  # Braces open helm's own list literal, so an unescaped one silently changes
  # the parsed type rather than erroring.
  def test_braces_are_escaped
    assert_equal 'registry.password=a\{b\}c', values_for('registry.password', 'a{b}c')
  end

  # Backslash is helm's escape character and must double, or it would escape
  # whatever followed it in the value.
  def test_backslash_is_doubled
    assert_equal "registry.password=a\\\\b", values_for('registry.password', "a\\b")
  end

  # Escaping runs backslash-first; done in the other order the backslashes
  # introduced by the comma rule would themselves be doubled.
  def test_backslash_before_a_comma_survives_both_rules
    assert_equal "p=a\\\\\\,b", values_for('p', "a\\,b")
  end

  # The common case must be untouched — a URL's scheme, colons and slashes are
  # not helm metacharacters, and quoting them would end up in the rendered value.
  def test_ordinary_values_are_unchanged
    assert_equal 'registry.url=https://gitlab.internal.example:5009',
                 values_for('registry.url', 'https://gitlab.internal.example:5009')
  end

  def test_nil_becomes_an_empty_value
    assert_equal 'registry.path=', values_for('registry.path', nil)
  end
end
