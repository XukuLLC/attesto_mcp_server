defmodule AttestoMCP.Server.P12OptionContractTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Stdio

  @modern "2026-07-28"

  test "atom cache scope is normalized and produces the configured public result" do
    {:ok, server} =
      Server.start_link(
        cache_scope: :public,
        allow_public_cache: true
      )

    request = %{
      kind: :request,
      id: 1,
      method: "tools/list",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    assert {1, %{"result" => %{"cacheScope" => "public"}}} =
             Server.dispatch(server, request, %{principal: "cache-user", public_catalog: true},
               version: @modern
             )
  end

  test "stdio main keeps adapter options out of server startup" do
    output =
      capture_io(fn ->
        assert :ok =
                 Stdio.main(
                   input: fn -> :eof end,
                   eof_grace_ms: 10,
                   context: %{principal: "stdio-context"},
                   principal: "stdio-options",
                   tenant: "local",
                   scopes: ["mcp:tools:read"],
                   on_server_request: fn _event -> :ok end,
                   max_concurrency: 1
                 )
      end)

    assert output == ""
  end
end
