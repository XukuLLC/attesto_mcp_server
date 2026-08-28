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
    parent = self()

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
                 send(parent, {:handler_called, account})
                 {:ok, "accepted"}
               end
             })

    assert :ok =
             Server.register_prompt(server, "secure-prompt", %{
               handler: fn _, _ -> {:ok, %{"messages" => []}} end
             })

    assert :ok =
             Server.register_resource_template(server, "urn:secure/{id}", %{
               handler: fn _, _ -> {:ok, %{}} end
             })

    assert :ok =
             Server.register_completion(server, "secure-prompt-completion", %{
               ref: %{"type" => "ref/prompt", "name" => "secure-prompt"},
               handler: fn _, _ ->
                 send(parent, :completion_handler_called)
                 {:ok, ["secret"]}
               end
             })

    assert :ok =
             Server.register_completion(server, "secure-resource-completion", %{
               ref: %{"type" => "ref/resource", "uri" => "urn:secure/{id}"},
               handler: fn _, _ ->
                 send(parent, :completion_handler_called)
                 {:ok, ["secret"]}
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

    conn =
      call(
        server,
        config,
        token,
        "tools/call",
        %{"name" => "secure", "arguments" => %{"account" => "denied"}},
        scopes: [],
        param_header: "=?base64?ZGVuaWVk?="
      )

    assert conn.status == 403
    [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~s(error="insufficient_scope")
    assert challenge =~ ~s(scope="mcp:tools:call")

    assert challenge =~
             ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp")

    refute_receive {:handler_called, _}
  end

  test "matching Origin is accepted", %{config: config, server: server} do
    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()]
      )

    response =
      call(
        server,
        config,
        token,
        "tools/call",
        %{"name" => "secure", "arguments" => %{"account" => "acct-42"}},
        scopes: [AttestoMCP.Scopes.tools_call()],
        param_header: "=?base64?YWNjdC00Mg==?=",
        origins: ["https://mcp.example.com"]
      )

    assert response.status == 200
    assert_receive {:handler_called, "acct-42"}
  end

  test "mismatched Origin is forbidden before dispatch", %{config: config, server: server} do
    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()]
      )

    response =
      call(
        server,
        config,
        token,
        "tools/call",
        %{"name" => "secure", "arguments" => %{"account" => "acct-42"}},
        scopes: [AttestoMCP.Scopes.tools_call()],
        param_header: "=?base64?YWNjdC00Mg==?=",
        origins: ["https://other.example.com"]
      )

    assert response.status == 403
    assert response.resp_body == "forbidden origin"
    refute_receive {:handler_called, _}
  end

  test "malformed and duplicate Origin headers fail closed", %{
    config: config,
    server: server
  } do
    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()]
      )

    for origins <- [
          ["not-an-origin"],
          ["https://mcp.example.com", "https://mcp.example.com"]
        ] do
      response =
        call(
          server,
          config,
          token,
          "tools/call",
          %{"name" => "secure", "arguments" => %{"account" => "acct-42"}},
          scopes: [AttestoMCP.Scopes.tools_call()],
          param_header: "=?base64?YWNjdC00Mg==?=",
          origins: origins
        )

      assert response.status == 403
      assert response.resp_body == "forbidden origin"
    end

    refute_receive {:handler_called, _}
  end

  test "request header budgets return 431 before dispatch", %{
    config: config,
    server: server
  } do
    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()]
      )

    cases = [
      excessive_count: for(index <- 1..65, do: {"x-count-#{index}", "v"}),
      oversized_value: [{"x-large-value", String.duplicate("v", 8_193)}],
      oversized_name: [{String.duplicate("x", 257), "v"}],
      excessive_aggregate:
        for(index <- 1..8, do: {"x-aggregate-#{index}", String.duplicate("v", 8_192)})
    ]

    for {_budget, extra_headers} <- cases do
      response =
        call(
          server,
          config,
          token,
          "tools/call",
          %{"name" => "secure", "arguments" => %{"account" => "acct-42"}},
          scopes: [AttestoMCP.Scopes.tools_call()],
          param_header: "=?base64?YWNjdC00Mg==?=",
          extra_headers: extra_headers
        )

      assert response.status == 431
      assert response.resp_body == "request headers too large"
    end

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

  test "completion scope defaults fail closed and a method override governs both ref types", %{
    config: config,
    server: server
  } do
    refs = [
      {%{"type" => "ref/prompt", "name" => "secure-prompt"}, AttestoMCP.Scopes.prompts_read()},
      {%{"type" => "ref/resource", "uri" => "urn:secure/{id}"},
       AttestoMCP.Scopes.resources_read()}
    ]

    zero_scope_token = AttestoMCP.Test.Factory.access_token(config, scopes: [])

    for {ref, expected_scope} <- refs do
      response =
        call(
          server,
          config,
          zero_scope_token,
          "completion/complete",
          %{"ref" => ref, "argument" => %{"name" => "id", "value" => "1"}},
          scopes: []
        )

      assert response.status == 403
      assert [challenge] = get_resp_header(response, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ ~s(scope="#{expected_scope}")
    end

    refute_receive :completion_handler_called

    override_scope = "mcp:completion:custom"

    override_token =
      AttestoMCP.Test.Factory.access_token(config, scopes: [override_scope])

    for {ref, _expected_scope} <- refs do
      response =
        call(
          server,
          config,
          override_token,
          "completion/complete",
          %{"ref" => ref, "argument" => %{"name" => "id", "value" => "1"}},
          scope_map: %{"completion/complete" => [override_scope]}
        )

      assert response.status == 200
      assert Jason.decode!(response.resp_body)["result"]["completion"]["values"] == ["secret"]
    end

    assert_receive :completion_handler_called
    assert_receive :completion_handler_called
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

  test "non-object modern metadata returns a protocol error and the endpoint recovers", %{
    config: config,
    server: server
  } do
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [])

    rejected = call(server, config, token, "initialize", %{}, scopes: [], meta: 5)
    assert rejected.status == 400
    assert Jason.decode!(rejected.resp_body)["error"]["code"] == -32602

    tools_scope = AttestoMCP.Scopes.tools_read()
    tools_token = AttestoMCP.Test.Factory.access_token(config, scopes: [tools_scope])
    recovered = call(server, config, tools_token, "tools/list", %{}, scopes: [tools_scope])
    assert recovered.status == 200
    assert is_list(Jason.decode!(recovered.resp_body)["result"]["tools"])
  end

  defp call(server, config, token, method, params, opts) do
    meta =
      case Keyword.fetch(opts, :meta) do
        {:ok, value} ->
          value

        :error ->
          %{
            "io.modelcontextprotocol/protocolVersion" => @version,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
      end

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
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

    origin_headers =
      opts
      |> Keyword.get(:origins, [])
      |> Enum.map(&{"origin", &1})

    conn = %{
      conn
      | req_headers: origin_headers ++ Keyword.get(opts, :extra_headers, []) ++ conn.req_headers
    }

    conn =
      case mixed_headers do
        [{name, value}] -> %{conn | req_headers: [{name, value} | conn.req_headers]}
        _ -> conn
      end

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        scope_map:
          opts[:scope_map] ||
            %{
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
