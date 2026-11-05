defmodule AttestoMCP.Server.DependencyRequirementsTest do
  use ExUnit.Case, async: true

  test "AttestoMCP requires the 2.2.3 floor and admits the coordinated 2.x line" do
    case dependency!(:attesto_mcp) do
      {:attesto_mcp, requirement} when is_binary(requirement) ->
        for version <- ~w(2.2.3 2.99.0) do
          assert Version.match?(version, requirement),
                 "expected #{inspect(requirement)} to admit #{version}"
        end

        for version <- ~w(1.3.0 1.99.0 2.0.0 2.2.2 3.0.0) do
          refute Version.match?(version, requirement),
                 "expected #{inspect(requirement)} to reject #{version}"
        end

      {:attesto_mcp, opts} when is_list(opts) ->
        assert opts[:path], "expected the explicit source-development dependency"
    end
  end

  test "JOSE admits the patched floor and rejects the next major" do
    {:jose, requirement} = dependency!(:jose)

    for version <- ~w(1.11.13 1.99.0) do
      assert Version.match?(version, requirement),
             "expected #{inspect(requirement)} to admit #{version}"
    end

    for version <- ~w(1.11.12 2.0.0) do
      refute Version.match?(version, requirement),
             "expected #{inspect(requirement)} to reject #{version}"
    end
  end

  # GHSA-cvmg-hgv6-jqcp / CVE-2026-117680: every JSV release before 0.26.2
  # reports a regex whose backtracking budget ran out as a non-match, which
  # `not`, `anyOf`, `oneOf`, `if` and `contains` invert into acceptance.
  test "JSV requires the 0.26.2 security floor and stays on the 0.26 line" do
    {:jsv, requirement} = dependency!(:jsv)

    for version <- ~w(0.26.2 0.26.99) do
      assert Version.match?(version, requirement),
             "expected #{inspect(requirement)} to admit #{version}"
    end

    for version <- ~w(0.24.0 0.25.0 0.25.99 0.26.0 0.26.1 0.27.0) do
      refute Version.match?(version, requirement),
             "expected #{inspect(requirement)} to reject #{version}"
    end
  end

  defp dependency!(app) do
    AttestoMCP.Server.MixProject.project()
    |> Keyword.fetch!(:deps)
    |> Enum.find(&(elem(&1, 0) == app))
  end
end
