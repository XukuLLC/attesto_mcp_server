defmodule AttestoMCP.Server.PlugAuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @version "2026-07-28"

  setup do
    {:ok, server} =
      DynamicSupervisor.start_child(
        AttestoMCP.Server.DynamicSupervisor,
        {Server, []}
      )

    {:ok, config: AttestoMCP.Test.Factory.config(), server: server}
  end

  setup %{server: server} do
    assert :ok =
             Server.register_tool(server, "secure", %{
               input_schema: %{
                 "type" => "object",
                 "properties" => %{
                   "account" => %{
                     "type" => "string",
                     "x-mcp-header" => "account"
                   }
                 }
               },
               handler: fn %{"account" => account}, _ ->
                 send(self(), {:handler_called, account})
                 {:ok, "accepted"}
               end
             })

    on_exit(fn ->
      DynamicSupervisor.terminate_child(AttestoMCP.Server.DynamicSupervisor, server)
    end)

    :ok
  end

  test "valid token without scope gets a complete insufficient-scope challenge", %{
    config: config,
    server: server
  } do
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [])
    conn = call(server, config, token, "tools/list", %{}, scopes: [])

    assert conn.status == 403
    [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~s(error="insufficient_scope")
    assert challenge =~ ~s(scope="mcp:tools:read")

    assert challenge =~
             ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp")

    refute_receive {:handler_called, _}
  end

  test "scoped token succeeds and enforces registered x-mcp-header declarations", %{
    config: config,
    server: server
  } do
    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()]
      )

    params = %{"name" => "secure", "arguments" => %{"account" => "acct-42"}}

    missing =
      call(server, config, token, "tools/call", params, scopes: [AttestoMCP.Scopes.tools_call()])

    assert missing.status == 400
    assert Jason.decode!(missing.resp_body)["error"]["code"] == -32020

    mismatch =
      call(
        server,
        config,
        token,
        "tools/call",
        params,
        scopes: [AttestoMCP.Scopes.tools_call()],
        param_header: "wrong"
      )

    assert mismatch.status == 400
    assert Jason.decode!(mismatch.resp_body)["error"]["code"] == -32020

    valid =
      call(
        server,
        config,
        token,
        "tools/call",
        params,
        scopes: [AttestoMCP.Scopes.tools_call()],
        param_header: "=?base64?YWNjdC00Mg==?=",
        mixed_case: true
      )

    assert valid.status == 200
    assert Jason.decode!(valid.resp_body)["result"]["resultType"] == "complete"
  end

  test "protocol and method mirror headers remain literal", %{config: config, server: server} do
    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()]
      )

    encoded = "=?base64?MjAyNi0wNy0yOA==?="

    version =
      call(server, config, token, "tools/call", %{"name" => "secure", "arguments" => %{}},
        scopes: [AttestoMCP.Scopes.tools_call()],
        version_header: encoded
      )

    method =
      call(server, config, token, "tools/call", %{"name" => "secure", "arguments" => %{}},
        scopes: [AttestoMCP.Scopes.tools_call()],
        method_header: "=?base64?dG9vbHMvY2FsbA==?="
      )

    assert version.status == 400
    assert method.status == 400
    assert Jason.decode!(version.resp_body)["error"]["code"] == -32020
    assert Jason.decode!(method.resp_body)["error"]["code"] == -32020
  end

  test "POST requires application/json and reports 415 in the negotiated era", %{
    config: config,
    server: server
  } do
    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()]
      )

    for content_type <- [nil, "text/plain"] do
      conn =
        call(server, config, token, "tools/call", %{"name" => "secure", "arguments" => %{}},
          scopes: [AttestoMCP.Scopes.tools_call()],
          content_type: content_type
        )

      assert conn.status == 415
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32020
    end
  end

  defp call(server, config, token, method, params, opts) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" =>
        Map.put(
          params,
          "_meta",
          %{
            "io.modelcontextprotocol/protocolVersion" => @version,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        )
    }

    content_type =
      if Keyword.has_key?(opts, :content_type), do: opts[:content_type], else: "application/json"

    headers = [
      {"authorization", "Bearer " <> token},
      {"content-type", content_type},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", opts[:version_header] || @version},
      {"mcp-method", opts[:method_header] || method},
      {"mcp-name", if(method == "tools/call", do: "secure", else: nil)}
    ]

    headers =
      headers
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> maybe_param_header(opts)

    conn = conn(:post, "/mcp", Jason.encode!(request))

    {mixed_headers, normal_headers} =
      Enum.split_with(headers, fn {name, _value} ->
        String.downcase(name) == "mcp-param-account"
      end)

    conn = put_req_headers(conn, normal_headers)

    conn =
      case mixed_headers do
        [{name, value}] -> %{conn | req_headers: [{name, value} | conn.req_headers]}
        _ -> conn
      end

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        scope_map: %{
          "tools/list" => opts[:scopes] || [],
          "tools/call" => opts[:scopes] || []
        },
        auth: [config: config, resource: @resource]
      )

    AttestoMCP.Server.Plug.call(conn, plug)
  end

  defp maybe_param_header(headers, opts) do
    case Keyword.fetch(opts, :param_header) do
      {:ok, value} ->
        name = if opts[:mixed_case], do: "mCp-PaRaM-account", else: "mcp-param-account"
        headers ++ [{name, value}]

      :error ->
        headers
    end
  end

  defp put_req_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
  end
end
