defmodule AttestoMCP.Server.ConformanceRunnerTest do
  use ExUnit.Case, async: false

  @script Path.expand("../scripts/run_conformance_fixture.sh", __DIR__)
  @fixture Path.expand("../examples/conformance_server.exs", __DIR__)

  test "fixture runner hides credentials and cleans up after success and failure" do
    load_fixture_library()
    runner = temporary_runner()
    on_exit(fn -> File.rm_rf!(runner) end)

    {success_url, success_status} = run_fixture(runner, "0")
    assert success_status == 0
    assert_fixture_stopped(success_url)

    {failure_url, failure_status} = run_fixture(runner, "7")
    assert failure_status == 7
    assert_fixture_stopped(failure_url)

    source = File.read!(@script)
    assert source =~ "--fixture-command"
    assert source =~ "__MCP_SERVER_URL__"
    refute source =~ "--expected-failures"
  end

  test "fixture readiness source never includes an access token" do
    source = File.read!(Path.expand("../examples/conformance_server.exs", __DIR__))

    refute Regex.match?(~r/MCP_CONFORMANCE_READY[^\n]*token/i, source)
    assert source =~ "MCP_CONFORMANCE_READY url="
  end

  defp temporary_runner do
    runner =
      Path.join(System.tmp_dir!(), "attesto-mcp-runner-#{System.unique_integer([:positive])}")

    dist = Path.join(runner, "dist")
    File.mkdir_p!(dist)

    File.write!(
      Path.join(dist, "index.js"),
      "process.exit(Number(process.argv.at(-1) || 0));\n"
    )

    runner
  end

  defp load_fixture_library do
    previous = System.get_env("ATTESTO_MCP_FIXTURE_LIBRARY")
    System.put_env("ATTESTO_MCP_FIXTURE_LIBRARY", "1")

    try do
      Code.require_file(@fixture)
    after
      if previous,
        do: System.put_env("ATTESTO_MCP_FIXTURE_LIBRARY", previous),
        else: System.delete_env("ATTESTO_MCP_FIXTURE_LIBRARY")
    end
  end

  defp run_fixture(runner, exit_code) do
    apply(AttestoMCP.ConformanceFixture, :start, [
      {:command, "2025-11-25", "node", [Path.join(runner, "dist/index.js"), exit_code]}
    ])
  end

  defp assert_fixture_stopped(url) do
    %URI{host: host, port: port} = URI.parse(url)
    assert {:error, _reason} = :gen_tcp.connect(String.to_charlist(host), port, [:binary], 250)
  end
end
