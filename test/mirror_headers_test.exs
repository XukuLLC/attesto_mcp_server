defmodule AttestoMCP.Server.MirrorHeadersTest do
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

    config = AttestoMCP.Test.Factory.config()

    on_exit(fn ->
      DynamicSupervisor.terminate_child(AttestoMCP.Server.DynamicSupervisor, server)
    end)

    {:ok, server: server, config: config}
  end

  test "modern routing mirrors accept exact values and reject missing or mismatched headers", %{
    server: server,
    config: config
  } do
    assert :ok =
             Server.register_tool(server, "mirror-tool", %{
               handler: fn _arguments, _context -> {:ok, "tool"} end
             })

    assert :ok =
             Server.register_prompt(server, "mirror-prompt", %{
               arguments: [],
               handler: fn _input, _context ->
                 {:ok,
                  [%{"role" => "user", "content" => %{"type" => "text", "text" => "prompt"}}]}
               end
             })

    assert :ok =
             Server.register_resource(server, "urn:mirror:resource", %{
               handler: fn %{uri: uri}, _context ->
                 {:ok, %{"contents" => [%{"uri" => uri, "text" => "resource"}]}}
               end
             })

    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = selected_definition_plug(server, config)

    selected = [
      {"tools/call", %{"name" => "mirror-tool", "arguments" => %{}}, "mirror-tool"},
      {"prompts/get", %{"name" => "mirror-prompt", "arguments" => %{}}, "mirror-prompt"},
      {"resources/read", %{"uri" => "urn:mirror:resource"}, "urn:mirror:resource"}
    ]

    for {method, params, expected_name} <- selected do
      assert selected_call(plug, token, method, params, expected_name).status == 200

      for supplied_name <- [:omit, "wrong-definition", {:duplicate, expected_name}] do
        rejected = selected_call(plug, token, method, params, supplied_name)
        assert rejected.status == 400

        assert %{
                 "error" => %{
                   "code" => -32020,
                   "data" => %{"reason" => "body_header_mismatch"}
                 }
               } = Jason.decode!(rejected.resp_body)
      end
    end
  end

  test "modern protocol-version and method mirrors are required and exact", %{
    server: server,
    config: config
  } do
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = selected_definition_plug(server, config)
    params = %{}

    assert selected_call(plug, token, "tools/list", params, :omit).status == 200

    for {body_method, overrides} <- [
          {"tools/list", [protocol_version: :omit]},
          {"tools/list", [protocol_version: :omit, session_id: "stale-session"]},
          {"tools/list", [protocol_version: "2025-11-25"]},
          {"tools/list", [protocol_version: {:duplicate, @version}]},
          {"tools/list", [method: :omit]},
          {"tools/list", [method: "resources/list"]},
          {"tools/list", [method: {:duplicate, "tools/list"}]},
          {"ping", [protocol_version: :omit]},
          {"ping", [protocol_version: "2025-11-25"]}
        ] do
      rejected = selected_call(plug, token, body_method, params, :omit, overrides)
      assert rejected.status == 400

      assert %{
               "error" => %{
                 "code" => -32020,
                 "data" => %{"reason" => "body_header_mismatch"}
               }
             } = Jason.decode!(rejected.resp_body)
    end
  end

  test "trims OWS and accepts strict padded sentinel values", %{server: server, config: config} do
    register_tool(server, "secure", %{
      "type" => "object",
      "properties" => %{
        "account" => %{"type" => "string", "x-mcp-header" => "account"}
      }
    })

    token = token(config)

    conn =
      call(
        server,
        config,
        token,
        "secure",
        %{"account" => "acct-42"},
        "  secure  ",
        [{"mcp-param-account", "  =?base64?YWNjdC00Mg==?=  "}]
      )

    assert conn.status == 200

    invalid_padding =
      call(
        server,
        config,
        token,
        "secure",
        %{"account" => "Hello"},
        "secure",
        [{"mcp-param-account", "=?base64?SGVsbG8?="}]
      )

    assert invalid_padding.status == 400
    assert Jason.decode!(invalid_padding.resp_body)["error"]["code"] == -32020
  end

  test "missing sentinel delimiters are compared literally", %{server: server, config: config} do
    register_tool(server, "literal", %{
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => "string", "x-mcp-header" => "value"}
      }
    })

    token = token(config)

    for value <- ["SGVsbG8=", "=?base64?SGVsbG8="] do
      conn =
        call(
          server,
          config,
          token,
          "literal",
          %{"value" => value},
          "literal",
          [{"mcp-param-value", value}]
        )

      assert conn.status == 200
    end
  end

  test "nested declarations extract the exact argument path", %{server: server, config: config} do
    register_tool(server, "nested", %{
      "type" => "object",
      "properties" => %{
        "outer" => %{
          "type" => "object",
          "properties" => %{
            "inner" => %{"type" => "string", "x-mcp-header" => "nested"}
          }
        }
      }
    })

    token = token(config)

    valid =
      call(
        server,
        config,
        token,
        "nested",
        %{"outer" => %{"inner" => "value"}},
        "nested",
        [{"mcp-param-nested", "=?base64?dmFsdWU=?="}]
      )

    assert valid.status == 200

    mismatch =
      call(
        server,
        config,
        token,
        "nested",
        %{"outer" => %{"inner" => "value"}},
        "nested",
        [{"mcp-param-nested", "other"}]
      )

    assert mismatch.status == 400
    assert Jason.decode!(mismatch.resp_body)["error"]["code"] == -32020
  end

  test "an absent optional annotated value does not require a header", %{
    server: server,
    config: config
  } do
    register_tool(server, "optional_header", %{
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => "string", "x-mcp-header" => "optional"}
      }
    })

    token = token(config)

    absent = call(server, config, token, "optional_header", %{}, "optional_header", [])
    assert absent.status == 200

    unexpected =
      call(
        server,
        config,
        token,
        "optional_header",
        %{},
        "optional_header",
        [{"mcp-param-optional", "unexpected"}]
      )

    assert unexpected.status == 400
    assert Jason.decode!(unexpected.resp_body)["error"]["code"] == -32020
  end

  test "integer mirror values use bounded numeric equality", %{server: server, config: config} do
    register_tool(server, "integer_header", %{
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => "integer", "x-mcp-header" => "value"}
      }
    })

    token = token(config)
    max = 9_007_199_254_740_991

    for {body, header} <- [{42.0, "42"}, {-42, "-42"}, {max, Integer.to_string(max)}] do
      conn =
        call(server, config, token, "integer_header", %{"value" => body}, "integer_header", [
          {"mcp-param-value", header}
        ])

      assert conn.status == 200
    end

    rejected =
      call(
        server,
        config,
        token,
        "integer_header",
        %{"value" => max + 1},
        "integer_header",
        [{"mcp-param-value", Integer.to_string(max + 1)}]
      )

    assert rejected.status == 400
    assert Jason.decode!(rejected.resp_body)["error"]["code"] == -32020
  end

  test "registration rejects unsupported or unreachable declarations", %{server: server} do
    schemas = [
      %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "number", "x-mcp-header" => "n"}}
      },
      %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string", "x-mcp-header" => true}}
      },
      %{"type" => "object", "items" => %{"type" => "string", "x-mcp-header" => "item"}},
      %{"type" => "object", "anyOf" => [%{"x-mcp-header" => "choice"}]},
      %{
        "type" => "object",
        "properties" => %{
          "first" => %{"type" => "string", "x-mcp-header" => "same"},
          "second" => %{"type" => "string", "x-mcp-header" => "same"}
        }
      },
      %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string", "x-mcp-header" => "Mcp-Param-full"}}
      },
      %{
        "type" => "object",
        "properties" => %{
          "value" => %{
            "type" => "string",
            "annotations" => %{"x-mcp-header" => "alias"}
          }
        }
      },
      %{"type" => "object", "not" => %{"x-mcp-header" => "not"}},
      %{
        "type" => "object",
        "contains" => %{"type" => "string", "x-mcp-header" => "contains"}
      },
      %{
        "type" => "object",
        "patternProperties" => %{".*" => %{"x-mcp-header" => "pattern"}}
      },
      %{
        "type" => "object",
        "propertyNames" => %{"x-mcp-header" => "property"}
      },
      %{
        "type" => "object",
        "unevaluatedProperties" => %{"x-mcp-header" => "unevaluated"}
      },
      %{
        "type" => "object",
        "dependentSchemas" => %{"value" => %{"x-mcp-header" => "dependent"}}
      }
    ]

    Enum.each(Enum.with_index(schemas), fn {schema, index} ->
      assert {:error, _reason} =
               Server.register_tool(server, "invalid_header_#{index}", %{
                 description: "invalid header fixture",
                 input_schema: schema,
                 handler: fn _, _ -> {:ok, "unreachable"} end
               })
    end)
  end

  defp register_tool(server, name, schema) do
    assert :ok =
             Server.register_tool(server, name, %{
               description: "mirror header fixture",
               input_schema: schema,
               handler: fn _, _ -> {:ok, "accepted"} end
             })
  end

  defp token(config),
    do: AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_call()])

  defp selected_definition_plug(server, config) do
    AttestoMCP.Server.Plug.init(
      server: server,
      path: "/mcp",
      auth: [config: config, resource: @resource]
    )
  end

  defp selected_call(plug, token, body_method, params, mcp_name, overrides \\ []) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => body_method,
      "params" =>
        %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @version,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
        |> Map.merge(params)
    }

    conn =
      conn(:post, "/mcp", Jason.encode!(request))
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> maybe_put_mirror_header(
        "mcp-protocol-version",
        Keyword.get(overrides, :protocol_version, @version)
      )
      |> maybe_put_mirror_header("mcp-method", Keyword.get(overrides, :method, body_method))
      |> maybe_put_mirror_header("mcp-name", mcp_name)
      |> maybe_put_mirror_header("mcp-session-id", Keyword.get(overrides, :session_id, :omit))

    AttestoMCP.Server.Plug.call(conn, plug)
  end

  defp maybe_put_mirror_header(conn, _name, :omit), do: conn

  defp maybe_put_mirror_header(conn, name, {:duplicate, value}),
    do: prepend_req_headers(conn, [{name, value}, {name, value}])

  defp maybe_put_mirror_header(conn, name, value), do: put_req_header(conn, name, value)

  defp call(server, config, token, name, arguments, mcp_name, extra_headers) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => name,
        "arguments" => arguments,
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    headers = [
      {"authorization", "Bearer " <> token},
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", @version},
      {"mcp-method", "tools/call"},
      {"mcp-name", mcp_name}
      | extra_headers
    ]

    conn = conn(:post, "/mcp", Jason.encode!(request))
    conn = Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        scope_map: %{"tools/call" => [AttestoMCP.Scopes.tools_call()]},
        auth: [config: config, resource: @resource]
      )

    AttestoMCP.Server.Plug.call(conn, plug)
  end
end
