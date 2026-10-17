defmodule AttestoMCP.Server.ProtocolTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server.Protocol

  @modern "2026-07-28"
  @legacy "2025-11-25"

  test "classifies HTTP requests from exact headers, metadata, and session presence" do
    request = %{method: "tools/list", params: %{}}

    assert Protocol.era(request, headers: [@modern]) == @modern
    assert Protocol.era(request, headers: [@legacy]) == @legacy
    assert Protocol.era(request, headers: [], session?: true) == @legacy
    assert Protocol.era(request, headers: []) == @modern

    modern =
      put_in(request, [:params, "_meta"], %{
        "io.modelcontextprotocol/protocolVersion" => @modern
      })

    assert Protocol.era(modern, headers: []) == @modern
  end

  test "initialize routes metadata envelopes through modern validation" do
    initialize = fn version ->
      %{
        method: "initialize",
        params: %{
          "protocolVersion" => @legacy,
          "_meta" => %{"io.modelcontextprotocol/protocolVersion" => version}
        }
      }
    end

    assert Protocol.version(initialize.(@modern)) == @modern
    assert Protocol.version(initialize.("future-version")) == @modern
    assert Protocol.era(initialize.("future-version"), headers: []) == @legacy
  end

  test "transport-neutral inference preserves unsupported revisions for validation" do
    request = %{
      method: "tools/list",
      params: %{
        "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "future-version"}
      }
    }

    assert Protocol.version(request) == "future-version"
    assert Protocol.era(request, default: @modern) == "future-version"
  end
end
