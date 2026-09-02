defmodule AttestoMCP.Server.OutputArgumentErgonomicsTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Content, Output, Result}

  @modern "2026-07-28"

  defmodule Reporter do
    def report(parent, report), do: send(parent, {:output_report, report})
  end

  test "strict output remains the default and opt-in protocols encode common Elixir values" do
    json_value = %{
      state: :ready,
      recorded_on: ~D[2026-09-01],
      amount: Decimal.new("12.50")
    }

    jason_value = %{
      state: :ready,
      recorded_on: ~D[2026-09-01],
      amount: Decimal.new("12.50")
    }

    assert {:error, :not_json} = Output.canonicalize(json_value)
    assert {:error, :not_json} = Output.canonicalize(jason_value)

    expected = %{
      "state" => "ready",
      "recorded_on" => "2026-09-01",
      "amount" => "12.50"
    }

    assert {:ok, ^expected} =
             Output.canonicalize(json_value, output_canonicalization: :json)

    assert {:ok, ^expected} =
             Output.canonicalize(jason_value, output_canonicalization: :jason)

    assert Result.tool(Content.text("done"),
             structured_content: jason_value,
             output_canonicalization: :jason
           )["structuredContent"] == expected
  end

  test "protocol encoding is bounded before invocation and again before decoding" do
    oversized_input = MapSet.new([String.duplicate("s", 600)])

    assert {:error,
            %Output.CanonicalizationError{
              path: "",
              reason: :encoder_input_limit,
              value_type: {:struct, MapSet},
              encoder: :jason
            }} =
             Output.canonicalize_detailed(oversized_input,
               max_bytes: 512,
               output_canonicalization: :jason
             )

    escaping_output = MapSet.new([String.duplicate(<<0>>, 100)])

    assert {:error,
            %Output.CanonicalizationError{
              path: "",
              reason: :max_bytes,
              value_type: {:struct, MapSet},
              encoder: :jason
            }} =
             Output.canonicalize_detailed(escaping_output,
               max_bytes: 512,
               output_canonicalization: :jason
             )
  end

  test "encoder failures expose only path and category diagnostics" do
    assert {:error,
            %Output.CanonicalizationError{
              path: "/record",
              reason: :encoder_failure,
              value_type: {:struct, URI},
              encoder: :jason,
              encoder_exception: Protocol.UndefinedError
            } = error} =
             Output.canonicalize_detailed(
               %{"record" => URI.parse("https://private.example.test/record")},
               output_canonicalization: :jason
             )

    refute Map.has_key?(Map.from_struct(error), :value)
    refute Exception.message(error) =~ "private.example.test"
  end

  test "server option canonicalizes structured tool output and validates its schema" do
    server =
      start_server(
        output_canonicalization: :jason,
        registrations: [
          {:tool, "record",
           %{
             input_schema: %{"type" => "object"},
             output_schema: %{
               "type" => "object",
               "properties" => %{
                 "state" => %{"type" => "string"},
                 "recorded_on" => %{"type" => "string", "format" => "date"},
                 "amount" => %{"type" => "string"}
               },
               "required" => ["state", "recorded_on", "amount"]
             },
             handler: fn _arguments, _context ->
               {:ok,
                %{
                  state: :ready,
                  recorded_on: ~D[2026-09-01],
                  amount: Decimal.new("12.50")
                }}
             end
           }}
        ]
      )

    response = call_tool(server, 1, "record", %{})

    assert get_in(response, ["result", "structuredContent"]) == %{
             "state" => "ready",
             "recorded_on" => "2026-09-01",
             "amount" => "12.50"
           }

    assert get_in(response, ["result", "isError"]) == false
  end

  test "handler result constructor inherits the supervised server settings" do
    parent = self()
    payload = String.duplicate("x", 2_010_000)

    server =
      start_server(
        max_json_bytes: 2_100_000,
        output_canonicalization: :jason,
        registrations: [
          {:tool, "context-result",
           %{
             input_schema: %{"type" => "object"},
             handler: fn _arguments, context ->
               send(parent, {
                 :result_context,
                 Map.take(context, [:max_json_bytes, :output_canonicalization])
               })

               {:ok,
                Result.tool_from_context(Content.text("done"), context,
                  structured_content: %{state: :ready, payload: payload},
                  is_error: false
                )}
             end
           }}
        ]
      )

    response = call_tool(server, 8, "context-result", %{})

    assert get_in(response, ["result", "structuredContent", "state"]) == "ready"
    assert get_in(response, ["result", "structuredContent", "payload"]) == payload
    assert get_in(response, ["result", "isError"]) == false

    assert_receive {:result_context,
                    %{max_json_bytes: 2_100_000, output_canonicalization: :jason}}
  end

  test "the trusted reporter receives the first rejected path without changing the client error" do
    parent = self()

    server =
      start_server(
        exception_reporter: {Reporter, :report, [parent]},
        registrations: [
          {:tool, "invalid-output",
           %{
             input_schema: %{"type" => "object"},
             handler: fn _arguments, _context ->
               {:ok, %{"safe" => true, "a/b~c" => [%{"secret" => self()}]}}
             end
           }}
        ]
      )

    response = call_tool(server, 2, "invalid-output", %{})

    assert get_in(response, ["result", "isError"]) == true
    refute inspect(response) =~ "a~1b~0c"
    refute inspect(response) =~ "pid"

    assert_receive {:output_report,
                    %{
                      source: :output_canonicalization,
                      reason: %Output.CanonicalizationError{
                        path: "/a~1b~0c/0/secret",
                        reason: :unsupported_value,
                        value_type: :pid,
                        encoder: :strict
                      }
                    }}
  end

  test "constructor failures preserve the private canonicalization diagnostic" do
    parent = self()

    server =
      start_server(
        exception_reporter: {Reporter, :report, [parent]},
        registrations: [
          {:tool, "invalid-constructor-output",
           %{
             input_schema: %{"type" => "object"},
             handler: fn _arguments, _context ->
               {:ok,
                Result.tool(Content.text("not returned"),
                  structured_content: %{"record" => %{"private" => self()}}
                )}
             end
           }}
        ]
      )

    response = call_tool(server, 3, "invalid-constructor-output", %{})

    assert get_in(response, ["error", "code"]) == -32603
    assert get_in(response, ["error", "data", "reason"]) == "handler_failure"

    assert_receive {:output_report,
                    %{
                      source: :handler,
                      reason: %ArgumentError{message: diagnostic}
                    }}

    assert diagnostic =~ "/structuredContent/record/private"
    assert diagnostic =~ "unsupported_value"
    refute inspect(response) =~ "structuredContent"
    refute inspect(response) =~ "pid"
  end

  test "rejected diagnostic paths are bounded and escape control characters" do
    parent = self()
    property = String.duplicate("x", 2_000) <> <<0, 1, 9, 10, 13, 31, 127>>

    server =
      start_server(
        exception_reporter: {Reporter, :report, [parent]},
        registrations: [
          {:tool, "bounded-diagnostic-path",
           %{
             input_schema: %{"type" => "object"},
             handler: fn _arguments, _context ->
               {:ok, %{property => %{"secret" => self()}}}
             end
           }}
        ]
      )

    response = call_tool(server, 2, "bounded-diagnostic-path", %{})

    assert get_in(response, ["result", "isError"]) == true

    assert get_in(response, ["result", "content"]) == [
             %{"type" => "text", "text" => "tool output was invalid"}
           ]

    assert_receive {:output_report, %{reason: %Output.CanonicalizationError{path: path}}}

    assert byte_size(path) <= 512
    assert String.valid?(path)
    refute Enum.any?(0..31, &String.contains?(path, <<&1>>))
    refute String.contains?(path, <<0x7F>>)
    assert String.contains?(path, "[path-truncated:")
  end

  test "atom-key mode runs after validation and converts only existing declared property keys" do
    parent = self()
    dynamic_declared = "declared_#{System.unique_integer([:positive])}"
    dynamic_client = "client_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(dynamic_declared) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(dynamic_client) end

    schema = %{
      "type" => "object",
      "properties" => %{
        "limit" => %{"type" => "integer"},
        "filter" => %{
          "type" => "object",
          "properties" => %{"state" => %{"type" => "string"}}
        },
        "rows" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{"item_id" => %{"type" => "string"}}
          }
        },
        "tuple" => %{
          "type" => "array",
          "prefixItems" => [
            %{
              "type" => "object",
              "properties" => %{"left" => %{"type" => "string"}}
            }
          ],
          "items" => %{
            "type" => "object",
            "properties" => %{"tail" => %{"type" => "string"}}
          }
        },
        "free" => %{"type" => "object", "additionalProperties" => true},
        "choice" => %{
          "oneOf" => [
            %{
              "type" => "object",
              "properties" => %{"branch" => %{"const" => "selected"}},
              "required" => ["branch"]
            },
            %{"type" => "string"}
          ]
        },
        dynamic_declared => %{"type" => "string"}
      },
      "required" => ["limit"],
      "additionalProperties" => true
    }

    server =
      start_server(
        tool_argument_keys: :atoms,
        registrations: [
          {:tool, "atom-arguments",
           %{
             input_schema: schema,
             handler: fn arguments, _context ->
               send(parent, {:arguments, arguments})
               {:ok, "ok"}
             end
           }}
        ]
      )

    arguments = %{
      "limit" => 10,
      "filter" => %{"state" => "active"},
      "rows" => [%{"item_id" => "one"}],
      "tuple" => [%{"left" => "first"}, %{"tail" => "rest"}],
      "free" => %{dynamic_client => true},
      "choice" => %{"branch" => "selected"},
      dynamic_declared => "kept",
      dynamic_client => "also kept"
    }

    response = call_tool(server, 3, "atom-arguments", arguments)
    assert get_in(response, ["result", "isError"]) == false

    assert_receive {:arguments, received}
    assert received[:limit] == 10
    assert received[:filter][:state] == "active"
    assert received[:rows] == [%{item_id: "one"}]
    assert received[:tuple] == [%{left: "first"}, %{tail: "rest"}]
    assert received[:free] == %{dynamic_client => true}
    assert received[:choice] == %{"branch" => "selected"}
    assert received[dynamic_declared] == "kept"
    assert received[dynamic_client] == "also kept"

    assert_raise ArgumentError, fn -> String.to_existing_atom(dynamic_declared) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(dynamic_client) end

    invalid = call_tool(server, 4, "atom-arguments", %{"limit" => "not-an-integer"})
    assert get_in(invalid, ["error", "data", "reason"]) == "tool_arguments_invalid"
    refute_receive {:arguments, _arguments}
  end

  test "string-key mode remains the default and invalid option values fail at startup" do
    parent = self()

    server =
      start_server(
        registrations: [
          {:tool, "string-arguments",
           %{
             input_schema: %{
               "type" => "object",
               "properties" => %{"limit" => %{"type" => "integer"}}
             },
             handler: fn arguments, _context ->
               send(parent, {:default_arguments, arguments})
               {:ok, "ok"}
             end
           }}
        ]
      )

    _response = call_tool(server, 5, "string-arguments", %{"limit" => 2})
    assert_receive {:default_arguments, %{"limit" => 2}}

    assert {:error, {%ArgumentError{}, _stacktrace}} =
             GenServer.start(Server, output_canonicalization: :automatic)

    assert {:error, {%ArgumentError{}, _stacktrace}} =
             GenServer.start(Server, tool_argument_keys: :unsafe_atoms)
  end

  test "loads unloaded MFA and external capture modules before atom conversion" do
    fixture = Path.expand("support/unloaded_atom_handlers.ex", __DIR__)

    output_dir =
      Path.join(
        System.tmp_dir!(),
        "attesto_mcp_server_unloaded_#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    File.mkdir_p!(output_dir)

    mfa_module = String.to_atom("Elixir.AttestoMCP.Server.UnloadedMFAHandler")
    capture_module = String.to_atom("Elixir.AttestoMCP.Server.UnloadedCaptureHandler")
    mfa_key = "unloaded_mfa_argument"
    capture_key = "unloaded_capture_argument"

    on_exit(fn ->
      for module <- [mfa_module, capture_module] do
        :code.delete(module)
        :code.purge(module)
      end

      Code.delete_path(String.to_charlist(output_dir))
      File.rm_rf!(output_dir)
    end)

    elixir_bin = Path.expand("../../bin", to_string(:code.lib_dir(:elixir)))
    elixirc = Path.join(elixir_bin, "elixirc")
    path = elixir_bin <> ":" <> System.get_env("PATH", "")

    {_output, 0} =
      System.cmd(elixirc, [fixture, "-o", output_dir],
        env: [{"PATH", path}],
        stderr_to_stdout: true
      )

    Code.prepend_path(String.to_charlist(output_dir))

    assert :code.is_loaded(mfa_module) == false
    assert :code.is_loaded(capture_module) == false
    assert_raise ArgumentError, fn -> String.to_existing_atom(mfa_key) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(capture_key) end

    mfa_server =
      start_server(
        tool_argument_keys: :atoms,
        registrations: [
          {:tool, "unloaded-mfa",
           %{
             input_schema: %{
               "type" => "object",
               "properties" => %{mfa_key => %{"type" => "string"}},
               "required" => [mfa_key]
             },
             handler: {mfa_module, :handle}
           }}
        ]
      )

    assert :code.is_loaded(mfa_module) == false
    mfa_response = call_tool(mfa_server, 6, "unloaded-mfa", %{mfa_key => "ok"})
    assert get_in(mfa_response, ["result", "structuredContent", "atom_key?"]) == true

    capture_handler = Function.capture(capture_module, :handle, 2)
    assert is_function(capture_handler, 2)
    assert :code.is_loaded(capture_module) == false

    capture_server =
      start_server(
        tool_argument_keys: :atoms,
        registrations: [
          {:tool, "unloaded-capture",
           %{
             input_schema: %{
               "type" => "object",
               "properties" => %{capture_key => %{"type" => "string"}},
               "required" => [capture_key]
             },
             handler: capture_handler
           }}
        ]
      )

    capture_response = call_tool(capture_server, 7, "unloaded-capture", %{capture_key => "ok"})
    assert get_in(capture_response, ["result", "structuredContent", "atom_key?"]) == true
  end

  defp start_server(opts) do
    start_supervised!(%{Server.child_spec(opts) | id: make_ref()})
  end

  defp call_tool(server, id, name, arguments) do
    request = %{
      kind: :request,
      id: id,
      method: "tools/call",
      params:
        modern_params(%{
          "name" => name,
          "arguments" => arguments
        })
    }

    {^id, response} =
      Server.dispatch(server, request, %{principal: "test-user"}, version: @modern)

    response
  end

  defp modern_params(params) do
    Map.put(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    })
  end
end
