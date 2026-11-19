defmodule AttestoMCP.Server.DependencyRequirementsTest do
  use ExUnit.Case, async: true

  # AttestoMCP 2.12.1 omits scope from ProtectResource 401 challenges by default.
  test "AttestoMCP requires the 2.12 floor and stays on the 2.x line" do
    case dependency!(:attesto_mcp) do
      {:attesto_mcp, requirement} when is_binary(requirement) ->
        for version <- ~w(2.12.1 2.99.0) do
          assert Version.match?(version, requirement),
                 "expected #{inspect(requirement)} to admit #{version}"
        end

        refused =
          ~w(1.3.0 1.99.0 2.0.0 2.4.0 2.5.0 2.6.0 2.6.99 2.7.0 2.7.99) ++
            ~w(2.8.0 2.8.99 2.9.0 2.9.99 2.10.0 2.10.1 2.10.99 2.11.0 2.11.1 2.11.99 2.12.0 3.0.0)

        for version <- refused do
          refute Version.match?(version, requirement),
                 "expected #{inspect(requirement)} to reject #{version}"
        end

      {:attesto_mcp, opts} when is_list(opts) ->
        assert opts[:path], "expected the explicit source-development dependency"
    end
  end

  test "Ecto admits the patched floor and rejects the next major" do
    {:ecto, requirement, opts} = dependency!(:ecto)
    assert opts[:optional]

    for version <- ~w(3.14.3 3.99.0) do
      assert Version.match?(version, requirement),
             "expected #{inspect(requirement)} to admit #{version}"
    end

    for version <- ~w(3.10.0 3.13.5 3.14.2 4.0.0) do
      refute Version.match?(version, requirement),
             "expected #{inspect(requirement)} to reject #{version}"
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

  test "JSV requires 0.28.0 and stays on the 0.28 line" do
    {:jsv, requirement} = dependency!(:jsv)

    for version <- ~w(0.28.0 0.28.99) do
      assert Version.match?(version, requirement),
             "expected #{inspect(requirement)} to admit #{version}"
    end

    for version <- ~w(0.27.0 0.29.0) do
      refute Version.match?(version, requirement),
             "expected #{inspect(requirement)} to reject #{version}"
    end
  end

  test "idna requires the patched floor and stays on the 8.x line" do
    {:idna, requirement} = dependency!(:idna)

    for version <- ~w(8.0.0 8.99.0) do
      assert Version.match?(version, requirement),
             "expected #{inspect(requirement)} to admit #{version}"
    end

    for version <- ~w(7.1.0 9.0.0) do
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
