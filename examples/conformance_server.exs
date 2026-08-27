#!/usr/bin/env elixir

Mix.Task.run("app.start")

defmodule AttestoMCP.ConformanceFixturePlug do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) when is_list(opts) do
    token = Keyword.fetch!(opts, :token)
    plug = Keyword.fetch!(opts, :plug)

    # The official DNS-rebinding scenario is intentionally unauthenticated and
    # varies Origin independently of the pinned resource.  The fixture still
    # authenticates every request, but removes a valid loopback Origin so the
    # production boundary can apply its pinned-resource policy.  Attacker
    # Origins remain untouched and are rejected by that boundary.
    conn =
      case get_req_header(conn, "origin") do
        [origin] when is_binary(origin) ->
          if loopback_origin?(origin), do: delete_req_header(conn, "origin"), else: conn

        _ ->
          conn
      end

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> AttestoMCP.Server.Plug.call(plug)
  end

  defp loopback_origin?(origin) do
    origin in ["http://localhost", "http://127.0.0.1", "http://[::1]"] or
      String.starts_with?(origin, "http://localhost:") or
      String.starts_with?(origin, "http://127.0.0.1:") or
      String.starts_with?(origin, "http://[::1]:")
  end
end

defmodule AttestoMCP.ConformanceFixture do
  @moduledoc false

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"

  def start(command \\ command_from_argv()) do
    {:ok, server} =
      Server.start_link(
        server_name: "attesto-conformance",
        server_version: "0.10.1",
        capabilities: %{"logging" => %{}}
      )

    register(server)

    config = auth_config()
    token = access_token(config)

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        stream_tools: ["test_tool_with_logging", "test_streaming_elicitation"],
        auth: [config: config, resource: @resource]
      )

    {:ok, _apps} = Application.ensure_all_started(:bandit)

    {:ok, bandit} =
      Bandit.start_link(
        plug: {AttestoMCP.ConformanceFixturePlug, token: token, plug: plug},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    url = "http://localhost:#{port}/mcp"

    try do
      # The runner injects this in-process token through the fixture Plug. Never
      # print it: readiness output is routinely captured by CI and proxy logs.
      IO.puts(:stderr, "MCP_CONFORMANCE_READY url=#{url}")
      {url, run_command_or_wait(url, command)}
    after
      stop_fixture_process(bandit)
      stop_fixture_process(server)
    end
  end

  defp stop_fixture_process(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      monitor = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        1_000 ->
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
          after
            1_000 -> :ok
          end
      end
    end
  end

  defp command_from_argv do
    case Enum.drop_while(System.argv(), &(&1 == "--")) do
      ["--fixture-command", era, executable | args]
      when era in ["2025-11-25", "2026-07-28"] ->
        {:command, era, executable, args}

      [] ->
        :wait

      _other ->
        :invalid
    end
  end

  defp run_command_or_wait(url, {:command, era, executable, args})
       when era in ["2025-11-25", "2026-07-28"] and is_binary(executable) and
              is_list(args) do
    args = Enum.map(args, &String.replace(&1, "__MCP_SERVER_URL__", url))

    {output, status} =
      System.cmd(executable, args,
        env: [{"MCP_SERVER_URL", url}, {"MCP_PROTOCOL_ERA", era}],
        stderr_to_stdout: true
      )

    IO.binwrite(output)
    status
  end

  defp run_command_or_wait(_url, :wait) do
    Process.sleep(:infinity)
  end

  defp run_command_or_wait(_url, :invalid) do
    IO.puts(:stderr, "invalid fixture command")
    64
  end

  defp auth_config do
    pem = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_pem() |> elem(1)
    Application.put_env(:attesto, Attesto.Keystore.Static, signing_pem: pem)

    Attesto.Config.new(
      issuer: "https://auth.example.com",
      audience: @resource,
      keystore: Attesto.Keystore.Static,
      principal_kinds: [
        Attesto.PrincipalKind.new("user", "usr_",
          required_claims: [{"client_id", :non_empty_string}]
        )
      ]
    )
  end

  defp access_token(config) do
    principal = %{
      claims: %{"client_id" => "conformance-client"},
      kind: "user",
      scopes: AttestoMCP.Scopes.all(),
      sub: "usr_conformance"
    }

    {:ok, token} = Attesto.Token.mint(config, principal)
    token.access_token
  end

  defp register(server) do
    image =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    audio = Base.encode64(<<82, 73, 70, 70, 4, 0, 0, 0, 87, 65, 86, 69>>)

    tool(server, "test_simple_text", "Simple text diagnostic", %{}, fn _, _ ->
      {:ok,
       %{
         "content" => [
           %{"type" => "text", "text" => "This is a simple text response for testing."}
         ]
       }}
    end)

    tool(
      server,
      "a_custom_header_diagnostic",
      "Custom mirrored header diagnostic",
      %{
        "properties" => %{
          "header_value" => %{"type" => "string", "x-mcp-header" => "header_value"}
        }
      },
      fn args, _ -> {:ok, Map.get(args, "header_value", "header-ok")} end
    )

    tool(server, "test_image_content", "Image diagnostic", %{}, fn _, _ ->
      {:ok, %{"content" => [%{"type" => "image", "data" => image, "mimeType" => "image/png"}]}}
    end)

    tool(server, "test_audio_content", "Audio diagnostic", %{}, fn _, _ ->
      {:ok, %{"content" => [%{"type" => "audio", "data" => audio, "mimeType" => "audio/wav"}]}}
    end)

    tool(server, "test_embedded_resource", "Embedded resource diagnostic", %{}, fn _, _ ->
      {:ok,
       %{
         "content" => [
           %{
             "type" => "resource",
             "resource" => %{
               "uri" => "test://embedded-resource",
               "mimeType" => "text/plain",
               "text" => "This is an embedded resource content."
             }
           }
         ]
       }}
    end)

    tool(server, "test_multiple_content_types", "Mixed content diagnostic", %{}, fn _, _ ->
      {:ok,
       %{
         "content" => [
           %{"type" => "text", "text" => "Multiple content types test:"},
           %{"type" => "image", "data" => image, "mimeType" => "image/png"},
           %{
             "type" => "resource",
             "resource" => %{
               "uri" => "test://mixed-content-resource",
               "mimeType" => "application/json",
               "text" => ~s({"test":"data","value":123})
             }
           }
         ]
       }}
    end)

    tool(server, "test_error_handling", "Error diagnostic", %{}, fn _, _ ->
      {:ok,
       %{
         "isError" => true,
         "content" => [
           %{"type" => "text", "text" => "This tool intentionally returns an error for testing"}
         ]
       }}
    end)

    tool(server, "test_tool_with_progress", "Progress diagnostic", %{}, fn args, context ->
      progress(context, args, 0)
      Process.sleep(60)
      progress(context, args, 50)
      Process.sleep(60)
      progress(context, args, 100)
      {:ok, "Tool execution completed"}
    end)

    tool(server, "test_tool_with_logging", "Logging diagnostic", %{}, fn _, context ->
      notify_logs(context, [
        "Tool execution started",
        "Tool processing data",
        "Tool execution completed"
      ])

      {:ok, "Tool execution completed"}
    end)

    tool(
      server,
      "test_sampling",
      "Sampling diagnostic",
      %{"prompt" => %{"type" => "string"}, "required" => ["prompt"]},
      fn args, context ->
        case context[:client_request].("sampling/createMessage", %{
               "messages" => [
                 %{"role" => "user", "content" => %{"type" => "text", "text" => args["prompt"]}}
               ],
               "maxTokens" => 100
             }) do
          {:ok, response} -> {:ok, "LLM response: #{inspect(response)}"}
          _ -> {:error, :sampling_failed}
        end
      end
    )

    tool(
      server,
      "test_elicitation",
      "Elicitation diagnostic",
      %{"message" => %{"type" => "string"}, "required" => ["message"]},
      fn args, context ->
        request = %{
          "message" => args["message"],
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{
              "username" => %{"type" => "string"},
              "email" => %{"type" => "string"}
            },
            "required" => ["username", "email"]
          }
        }

        case context[:client_request].("elicitation/create", request) do
          {:ok, response} -> {:ok, "User response: #{inspect(response)}"}
          _ -> {:error, :elicitation_failed}
        end
      end
    )

    input_tool(
      server,
      "test_input_required_result_tampered_state",
      "tamper_probe",
      %{
        "method" => "elicitation/create",
        "params" => %{
          "message" => "Provide the probe value",
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}},
            "required" => ["ok"]
          }
        }
      },
      fn _responses -> {:ok, "tamper-ok"} end
    )

    tool(
      server,
      "test_input_required_result_capabilities",
      "Capability-filtered input diagnostic",
      %{},
      fn args, _ ->
        if Map.has_key?(args, "sample_answer") or Map.has_key?(args, "elicitation_answer") do
          {:ok, "capability-filtered"}
        else
          {:input_required,
           %{
             "sample_answer" => %{
               "method" => "sampling/createMessage",
               "params" => %{
                 "messages" => [
                   %{
                     "role" => "user",
                     "content" => %{"type" => "text", "text" => "Provide a sample"}
                   }
                 ],
                 "maxTokens" => 32
               }
             },
             "elicitation_answer" => %{
               "method" => "elicitation/create",
               "params" => %{
                 "message" => "Provide an answer",
                 "requestedSchema" => %{
                   "type" => "object",
                   "properties" => %{"value" => %{"type" => "string"}},
                   "required" => ["value"]
                 }
               }
             }
           }}
        end
      end
    )

    schema_tool(server)
    elicitation_diagnostic_tools(server)

    input_tool(
      server,
      "test_missing_capability",
      "sampling_probe",
      %{
        "method" => "sampling/createMessage",
        "params" => %{
          "messages" => [
            %{"role" => "user", "content" => %{"type" => "text", "text" => "capability probe"}}
          ],
          "maxTokens" => 8
        }
      },
      fn _responses -> {:ok, "capability-ok"} end
    )

    input_tool(
      server,
      "test_streaming_elicitation",
      "streaming elicitation probe",
      %{
        "method" => "elicitation/create",
        "params" => %{
          "message" => "streaming probe",
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{"value" => %{"type" => "string"}},
            "required" => ["value"]
          }
        }
      },
      fn _responses -> {:ok, "streaming-ok"} end
    )

    tool(server, "test_logging_tool", "No-log probe", %{}, fn _, _ -> {:ok, "logging-probe"} end)

    tool(server, "test_trigger_tool_change", "Mutation probe", %{}, fn _, _ ->
      dynamic_name = "dynamic_tool_#{System.unique_integer([:positive])}"

      ensure_ok(
        Server.register_tool(server, dynamic_name, %{
          description: "Dynamically registered diagnostic",
          input_schema: %{"type" => "object"},
          handler: fn _, _ -> {:ok, "dynamic"} end
        })
      )

      {:ok, "triggered"}
    end)

    tool(server, "test_trigger_prompt_change", "Prompt mutation probe", %{}, fn _, _ ->
      dynamic_name = "dynamic_prompt_#{System.unique_integer([:positive])}"

      prompt(server, dynamic_name, "Dynamically registered prompt", [], fn _ ->
        [%{"role" => "user", "content" => %{"type" => "text", "text" => "dynamic"}}]
      end)

      {:ok, "triggered"}
    end)

    input_tool(
      server,
      "test_input_required_result_elicitation",
      "user_name",
      %{
        "method" => "elicitation/create",
        "params" => %{
          "message" => "What is your name?",
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}},
            "required" => ["name"]
          }
        }
      },
      fn responses ->
        name = get_in(responses, ["user_name", "content", "name"]) || "friend"
        {:ok, "Hello, #{name}!"}
      end
    )

    input_tool(
      server,
      "test_input_required_result_sampling",
      "capital_question",
      %{
        "method" => "sampling/createMessage",
        "params" => %{
          "messages" => [
            %{
              "role" => "user",
              "content" => %{"type" => "text", "text" => "What is the capital of France?"}
            }
          ],
          "maxTokens" => 100
        }
      },
      fn responses -> {:ok, inspect(responses)} end
    )

    input_tool(
      server,
      "test_input_required_result_list_roots",
      "client_roots",
      %{"method" => "roots/list", "params" => %{}},
      fn responses -> {:ok, inspect(responses)} end
    )

    input_tool(
      server,
      "test_input_required_result_request_state",
      "confirm",
      %{
        "method" => "elicitation/create",
        "params" => %{
          "message" => "Please confirm",
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{"ok" => %{"type" => "boolean"}},
            "required" => ["ok"]
          }
        }
      },
      fn _ -> {:ok, "state-ok"} end
    )

    multi_input_tool(server)
    multi_round_tool(server)

    ensure_ok(
      Server.register_resource(server, "test://static-text", %{
        description: "Static text resource",
        mime_type: "text/plain",
        handler: fn %{uri: uri}, _ ->
          {:ok,
           %{
             "contents" => [
               %{
                 "uri" => uri,
                 "mimeType" => "text/plain",
                 "text" => "This is the content of the static text resource."
               }
             ]
           }}
        end
      })
    )

    ensure_ok(
      Server.register_resource(server, "test://static-binary", %{
        description: "Static binary resource",
        mime_type: "image/png",
        handler: fn %{uri: uri}, _ ->
          {:ok, %{"contents" => [%{"uri" => uri, "mimeType" => "image/png", "blob" => image}]}}
        end
      })
    )

    ensure_ok(
      Server.register_resource(server, "test://watched-resource", %{
        description: "Watched resource",
        handler: fn %{uri: uri}, _ ->
          {:ok, %{"contents" => [%{"uri" => uri, "text" => "watched"}]}}
        end
      })
    )

    ensure_ok(
      Server.register_resource_template(server, "test://template/{id}/data", %{
        description: "Template resource",
        mime_type: "application/json",
        handler: fn %{uri: uri, params: params}, _ ->
          {:ok,
           %{
             "contents" => [
               %{
                 "uri" => uri,
                 "mimeType" => "application/json",
                 "text" =>
                   Jason.encode!(%{
                     "id" => params["id"],
                     "templateTest" => true,
                     "data" => "Data for ID: #{params["id"]}"
                   })
               }
             ]
           }}
        end
      })
    )

    prompt(server, "test_simple_prompt", "Simple prompt", [], fn _ ->
      [
        %{
          "role" => "user",
          "content" => %{"type" => "text", "text" => "This is a simple prompt for testing."}
        }
      ]
    end)

    prompt(
      server,
      "test_prompt_with_arguments",
      "Prompt with arguments",
      [%{"name" => "arg1", "required" => true}, %{"name" => "arg2", "required" => true}],
      fn args ->
        [
          %{
            "role" => "user",
            "content" => %{
              "type" => "text",
              "text" => "Prompt with arguments: arg1='#{args["arg1"]}', arg2='#{args["arg2"]}'"
            }
          }
        ]
      end
    )

    prompt(
      server,
      "test_prompt_with_embedded_resource",
      "Embedded resource prompt",
      [%{"name" => "resourceUri", "required" => true}],
      fn args ->
        [
          %{
            "role" => "user",
            "content" => %{
              "type" => "resource",
              "resource" => %{
                "uri" => args["resourceUri"],
                "mimeType" => "text/plain",
                "text" => "embedded"
              }
            }
          }
        ]
      end
    )

    prompt(server, "test_prompt_with_image", "Image prompt", [], fn _ ->
      [
        %{
          "role" => "user",
          "content" => %{"type" => "image", "data" => image, "mimeType" => "image/png"}
        },
        %{
          "role" => "user",
          "content" => %{"type" => "text", "text" => "Please analyze the image above."}
        }
      ]
    end)

    prompt_input(server)

    ensure_ok(
      Server.register_completion(server, "test-completion", %{
        ref: %{"type" => "ref/prompt", "name" => "test_prompt_with_arguments"},
        handler: fn _ -> {:ok, ["paris", "park", "party"]} end
      })
    )
  end

  defp tool(server, name, description, schema, handler) do
    schema = Map.put_new(schema, "type", "object")

    ensure_ok(
      Server.register_tool(server, name, %{
        description: description,
        input_schema: schema,
        handler: handler
      })
    )
  end

  defp input_tool(server, name, key, request, complete) do
    tool(server, name, "Input-required diagnostic", %{}, fn args, _ ->
      if Map.has_key?(args, key),
        do: complete.(Map.take(args, [key])),
        else: {:input_required, %{key => request}}
    end)
  end

  defp multi_input_tool(server) do
    tool(
      server,
      "test_input_required_result_multiple_inputs",
      "Multiple inputs diagnostic",
      %{},
      fn args, _ ->
        keys = ["user_name", "greeting", "client_roots"]

        if Enum.all?(keys, &Map.has_key?(args, &1)),
          do: {:ok, "multiple inputs complete"},
          else:
            {:input_required,
             %{
               "user_name" => %{
                 "method" => "elicitation/create",
                 "params" => %{
                   "message" => "What is your name?",
                   "requestedSchema" => %{
                     "type" => "object",
                     "properties" => %{"name" => %{"type" => "string"}},
                     "required" => ["name"]
                   }
                 }
               },
               "greeting" => %{
                 "method" => "sampling/createMessage",
                 "params" => %{
                   "messages" => [
                     %{
                       "role" => "user",
                       "content" => %{"type" => "text", "text" => "Generate a greeting"}
                     }
                   ],
                   "maxTokens" => 50
                 }
               },
               "client_roots" => %{"method" => "roots/list", "params" => %{}}
             }}
      end
    )
  end

  defp multi_round_tool(server) do
    tool(server, "test_input_required_result_multi_round", "Multi-round diagnostic", %{}, fn args,
                                                                                             _ ->
      cond do
        Map.has_key?(args, "step2") ->
          {:ok, "multi-round complete"}

        Map.has_key?(args, "step1") ->
          {:input_required,
           %{
             "step2" => %{
               "method" => "elicitation/create",
               "params" => %{
                 "message" => "Step 2: What is your favorite color?",
                 "requestedSchema" => %{
                   "type" => "object",
                   "properties" => %{"color" => %{"type" => "string"}},
                   "required" => ["color"]
                 }
               }
             }
           }}

        true ->
          {:input_required,
           %{
             "step1" => %{
               "method" => "elicitation/create",
               "params" => %{
                 "message" => "Step 1: What is your name?",
                 "requestedSchema" => %{
                   "type" => "object",
                   "properties" => %{"name" => %{"type" => "string"}},
                   "required" => ["name"]
                 }
               }
             }
           }}
      end
    end)
  end

  defp prompt(server, name, description, arguments, handler) do
    ensure_ok(
      Server.register_prompt(server, name, %{
        description: description,
        arguments: arguments,
        handler: fn %{arguments: args}, _ ->
          case handler.(args) do
            {:input_required, requests} -> {:input_required, requests}
            messages -> {:ok, messages}
          end
        end
      })
    )
  end

  defp prompt_input(server) do
    prompt(server, "test_input_required_result_prompt", "Input prompt", [], fn args ->
      if Map.has_key?(args, "user_context"),
        do: [%{"role" => "user", "content" => %{"type" => "text", "text" => "context accepted"}}],
        else:
          {:input_required,
           %{
             "user_context" => %{
               "method" => "elicitation/create",
               "params" => %{
                 "message" => "What context should the prompt use?",
                 "requestedSchema" => %{
                   "type" => "object",
                   "properties" => %{"context" => %{"type" => "string"}},
                   "required" => ["context"]
                 }
               }
             }
           }}
    end)
  end

  defp progress(context, args, value) do
    token = get_in(args, ["_meta", "progressToken"]) || "progress-test-1"

    if is_function(context[:progress], 3),
      do: context[:progress].(token, value, 100)
  end

  defp notify_logs(context, messages) do
    if is_function(context[:notify], 1) do
      Enum.with_index(messages)
      |> Enum.each(fn {message, index} ->
        if index > 0, do: Process.sleep(60)

        context[:notify].(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/message",
          "params" => %{"level" => "info", "data" => message}
        })
      end)
    end
  end

  defp ensure_ok(:ok), do: :ok
  defp ensure_ok({:ok, _value}), do: :ok

  defp ensure_ok({:error, reason}),
    do: raise("conformance fixture registration failed: #{inspect(reason)}")

  defp schema_tool(server) do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "$defs" => %{
        "address" => %{
          "$anchor" => "addressDef",
          "type" => "object",
          "properties" => %{
            "street" => %{"type" => "string"},
            "city" => %{"type" => "string"}
          }
        }
      },
      "properties" => %{
        "name" => %{"type" => "string"},
        "address" => %{"$ref" => "#/$defs/address"},
        "contactMethod" => %{"type" => "string", "enum" => ["phone", "email"]},
        "phone" => %{"type" => "string"},
        "email" => %{"type" => "string"}
      },
      "allOf" => [%{"anyOf" => [%{"required" => ["phone"]}, %{"required" => ["email"]}]}],
      "if" => %{
        "properties" => %{"contactMethod" => %{"const" => "phone"}},
        "required" => ["contactMethod"]
      },
      "then" => %{"required" => ["phone"]},
      "else" => %{"required" => ["email"]},
      "additionalProperties" => false
    }

    tool(
      server,
      "json_schema_2020_12_tool",
      "Tool with JSON Schema 2020-12 features",
      schema,
      fn _, _ ->
        {:ok, "schema-ok"}
      end
    )
  end

  defp elicitation_diagnostic_tools(server) do
    defaults = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "default" => "John Doe"},
        "age" => %{"type" => "integer", "default" => 30},
        "score" => %{"type" => "number", "default" => 95.5},
        "status" => %{
          "type" => "string",
          "enum" => ["active", "inactive", "pending"],
          "default" => "active"
        },
        "verified" => %{"type" => "boolean", "default" => true}
      },
      "required" => ["name", "age", "score", "status", "verified"]
    }

    enums = %{
      "type" => "object",
      "properties" => %{
        "untitledSingle" => %{"type" => "string", "enum" => ["option1", "option2", "option3"]},
        "titledSingle" => %{
          "type" => "string",
          "oneOf" => [
            %{"const" => "value1", "title" => "First Option"},
            %{"const" => "value2", "title" => "Second Option"}
          ]
        },
        "legacyEnum" => %{
          "type" => "string",
          "enum" => ["opt1", "opt2", "opt3"],
          "enumNames" => ["Option One", "Option Two", "Option Three"]
        },
        "untitledMulti" => %{
          "type" => "array",
          "items" => %{"type" => "string", "enum" => ["option1", "option2", "option3"]}
        },
        "titledMulti" => %{
          "type" => "array",
          "items" => %{
            "anyOf" => [
              %{"const" => "value1", "title" => "First Choice"},
              %{"const" => "value2", "title" => "Second Choice"}
            ]
          }
        }
      },
      "required" => [
        "untitledSingle",
        "titledSingle",
        "legacyEnum",
        "untitledMulti",
        "titledMulti"
      ]
    }

    elicitation_tool(
      server,
      "test_elicitation_sep1034_defaults",
      "Elicitation defaults",
      defaults
    )

    elicitation_tool(server, "test_elicitation_sep1330_enums", "Elicitation enums", enums)
  end

  defp elicitation_tool(server, name, description, requested_schema) do
    tool(server, name, description, %{}, fn _args, context ->
      case context[:client_request].("elicitation/create", %{
             "message" => description,
             "requestedSchema" => requested_schema
           }) do
        {:ok, response} -> {:ok, "Elicitation completed: #{inspect(response)}"}
        _ -> {:error, :elicitation_failed}
      end
    end)
  end
end

if System.get_env("ATTESTO_MCP_FIXTURE_LIBRARY") != "1" do
  {_url, status} = AttestoMCP.ConformanceFixture.start()
  if status != 0, do: System.halt(status)
end
