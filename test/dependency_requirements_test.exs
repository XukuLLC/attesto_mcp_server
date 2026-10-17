defmodule AttestoMCP.Server.DependencyRequirementsTest do
  use ExUnit.Case, async: true

  test "AttestoMCP retains its 1.3 floor and admits the coordinated 2.x line" do
    case dependency!(:attesto_mcp) do
      {:attesto_mcp, requirement} when is_binary(requirement) ->
        for version <- ~w(1.3.0 1.99.0 2.0.0 2.99.0) do
          assert Version.match?(version, requirement),
                 "expected #{inspect(requirement)} to admit #{version}"
        end

        for version <- ~w(1.2.99 3.0.0) do
          refute Version.match?(version, requirement),
                 "expected #{inspect(requirement)} to reject #{version}"
        end

      {:attesto_mcp, opts} when is_list(opts) ->
        assert opts[:path], "expected the explicit source-development dependency"
    end
  end

  test "JSV admits the supported 0.24 and 0.25 lines" do
    {:jsv, requirement} = dependency!(:jsv)

    for version <- ~w(0.24.0 0.24.99 0.25.0 0.25.99) do
      assert Version.match?(version, requirement),
             "expected #{inspect(requirement)} to admit #{version}"
    end

    for version <- ~w(0.23.99 0.26.0) do
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
