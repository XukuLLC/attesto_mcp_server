defmodule AttestoMCP.Server.P2BTelemetryTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Stdio
  alias AttestoMCP.Server.Subscriptions

  @modern "2026-07-28"
  @events for event <- [
                [:http_request, :start],
                [:http_request, :stop],
                [:stdio, :start],
                [:stdio, :stop],
                [:request, :start],
                [:request, :stop],
                [:request, :timeout],
                [:request, :exception],
                [:handler, :start],
                [:handler, :stop],
                [:handler, :exception],
                [:auth, :refusal],
                [:stream, :open],
                [:stream, :close],
                [:stream, :backpressure],
                [:stream, :exception],
                [:progress, :emit],
                [:progress, :reject],
                [:cancellation, :request],
                [:cancellation, :stop],
                [:mrtr, :round],
                [:subscription, :open],
                [:subscription, :close],
                [:subscription, :backpressure],
                [:subscription, :suppressed],
                [:cache, :choice],
                [:cache, :invalidation],
                [:protocol, :error],
                [:session, :open],
                [:session, :close],
                [:supervision, :restart]
              ],
              do: [:attesto_mcp_server | event]

  defp modern(params) do
    Map.put_new(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    })
  end

  @tag :g01
  @tag :g14
  @tag :t22
  @tag :t23
  @tag :t29
  @tag :t40
  test "core, adapter, auth, MRTR, progress, cache, and session events are safe" do
    handler_id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(handler_id, @events, &__MODULE__.telemetry_handler/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, server} = Server.start_link(max_concurrency: 8)

    assert :ok =
             Server.register_tool(server, "progress", %{
               handler: fn _, context ->
                 assert :ok = context.progress.("progress-token", 1, 2)

                 assert {:error, :inactive_or_nonmonotonic_token} =
                          context.progress.("progress-token", 0, 2)

                 {:ok, "ok"}
               end
             })

    request = %{
      kind: :request,
      id: 1,
      method: "tools/call",
      params:
        modern(%{
          "name" => "progress",
          "arguments" => %{},
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{},
            "progressToken" => "progress-token"
          }
        })
    }

    assert {1, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(server, request, %{principal: "telemetry"},
               version: @modern,
               on_event: fn _event -> :ok end
             )

    assert_event([:cache, :invalidation])
    assert_event([:request, :start])
    assert_event([:handler, :start])
    assert_event([:progress, :emit])
    assert_event([:progress, :reject])
    assert_event([:handler, :stop])
    assert_event([:request, :stop])

    assert {:ok, session} = Server.new_session(server, "telemetry", "tenant")
    assert :ok = Server.delete_session(server, session.id)
    assert_event([:session, :open])
    assert_event([:session, :close])

    assert :ok = Server.cancel_request(server, "telemetry", "missing")
    assert_event([:cancellation, :request])

    assert :ok =
             Server.register_tool(server, "mrtr", %{
               handler: fn _, _ ->
                 {:input_required,
                  %{
                    "choice" => %{
                      "method" => "elicitation/create",
                      "params" => %{
                        "message" => "choose",
                        "requestedSchema" => %{"type" => "object"}
                      }
                    }
                  }}
               end
             })

    capable =
      modern(%{
        "name" => "mrtr",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
        }
      })

    assert {2, %{"result" => %{"resultType" => "input_required"}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 2, method: "tools/call", params: capable},
               %{principal: "telemetry"},
               version: @modern
             )

    assert_event([:mrtr, :round])

    {:ok, subscriptions} = Subscriptions.start_link([])

    assert {:ok, "safe-sub"} =
             Subscriptions.open(
               subscriptions,
               "telemetry",
               "tenant",
               "safe-sub",
               %{"toolsListChanged" => true},
               self(),
               :safe_sub,
               fn _ -> false end
             )

    assert_receive {:mcp_subscription, :safe_sub, "safe-sub", _}
    assert_event([:subscription, :open])
    assert :ok = Subscriptions.publish_sync(subscriptions, %{"type" => "toolsListChanged"})
    assert_event([:subscription, :suppressed])
    assert :ok = Subscriptions.close(subscriptions, "safe-sub")
    assert_event([:subscription, :close])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [issuer: "https://issuer.example", resource: "https://mcp.example.com/mcp"]
      )

    metadata_conn = conn(:get, "/.well-known/oauth-protected-resource/mcp")
    assert AttestoMCP.Server.Plug.call(metadata_conn, plug).status == 200
    assert_event([:http_request, :start])
    assert_event([:http_request, :stop])

    unauthorized =
      conn(:post, "/mcp", "{}")
      |> put_req_header("accept", "application/json, text/event-stream")

    assert AttestoMCP.Server.Plug.call(unauthorized, plug).status == 401
    assert_event([:auth, :refusal])
    assert_event([:http_request, :start])
    assert_event([:http_request, :stop])

    assert :ok = Stdio.run(server, input: fn -> :eof end, context: %{principal: "stdio"})
    assert_event([:stdio, :start])
    assert_event([:stdio, :stop])
  end

  def telemetry_handler(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp assert_event(suffix) do
    event = [:attesto_mcp_server | suffix]
    assert_receive {:telemetry_event, ^event, _measurements, metadata}, 1_000

    allowed =
      MapSet.new([
        :version,
        :protocol_version,
        :method,
        :transport,
        :status,
        :outcome,
        :duration,
        :count,
        :correlation_id,
        :category,
        :reason,
        :error
      ])

    assert MapSet.subset?(MapSet.new(Map.keys(metadata)), allowed)
    refute Map.has_key?(metadata, :token)
    refute Map.has_key?(metadata, :authorization)
    refute Map.has_key?(metadata, :request_state)
  end
end
