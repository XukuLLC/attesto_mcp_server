defmodule AttestoMCP.Server.HostCallbackOrderStartupTest do
  # The suite confirms the 3.0 order globally in test_helper.exs. These tests
  # remove that confirmation and go through real server and plug startup: a
  # non-empty three-tuple is refused before serving anything, and once the
  # order is confirmed the callback's output shows it received its per-call
  # arguments first and its extra argument last.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @modern "2026-07-28"
  @resource "https://mcp.example.com/mcp"

  defmodule Callbacks do
    @moduledoc false

    def task_init(caller, context, parent) do
      send(parent, {:task_init, caller, context.method})
      :ok
    end

    def context(conn, source), do: %{source: source, request_path: conn.request_path}
  end

  setup do
    previous = Application.fetch_env(:attesto_mcp_server, :host_callback_order)
    Application.delete_env(:attesto_mcp_server, :host_callback_order)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:attesto_mcp_server, :host_callback_order, value)
        :error -> Application.delete_env(:attesto_mcp_server, :host_callback_order)
      end
    end)
  end

  test "a server with an unconfirmed handler_task_init refuses to start, then runs it in the 3.0 order" do
    parent = self()
    opts = [handler_task_init: {Callbacks, :task_init, [parent]}]

    {_pid, monitor} = spawn_monitor(fn -> Server.start_link(opts) end)
    assert_receive {:DOWN, ^monitor, :process, _pid, reason}, 1_000
    assert inspect(reason) =~ "Callbacks.task_init/3"
    assert inspect(reason) =~ "host_callback_order: :call_args_first"

    Application.put_env(:attesto_mcp_server, :host_callback_order, :call_args_first)
    {:ok, server} = start_supervised(%{Server.child_spec(opts) | id: make_ref()})

    assert :ok =
             Server.register_tool(server, "worker", %{
               handler: fn _arguments, _context -> {:ok, "ok"} end
             })

    request = %{
      kind: :request,
      id: 1,
      method: "tools/call",
      params: modern_params(%{"name" => "worker", "arguments" => %{}})
    }

    {1, response} = Server.dispatch(server, request, %{principal: "alice"}, version: @modern)
    refute get_in(response, ["result", "isError"])

    # caller and context first, the configured parent last.
    assert_receive {:task_init, caller, "tools/call"}
    assert caller == self()
  end

  test "a plug with an unconfirmed context_builder refuses to initialize, then builds context in the 3.0 order" do
    parent = self()
    {:ok, server} = start_supervised(%{Server.child_spec([]) | id: make_ref()})

    assert :ok =
             Server.register_tool(server, "inspect-context", %{
               handler: fn _arguments, context ->
                 send(parent, {:host_context, context.host_context})
                 {:ok, "ok"}
               end
             })

    config = AttestoMCP.Test.Factory.config()
    scope = AttestoMCP.Scopes.tools_call()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [scope])

    init = fn ->
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        scope_map: %{"tools/call" => [scope]},
        context_builder: {Callbacks, :context, [:mfa]}
      )
    end

    error = assert_raise ArgumentError, init
    assert error.message =~ "Callbacks.context/2"

    Application.put_env(:attesto_mcp_server, :host_callback_order, :call_args_first)
    state = init.()

    assert tool_call(state, token, "inspect-context").status == 200
    # conn first, the configured source last.
    assert_receive {:host_context, %{source: :mfa, request_path: "/mcp"}}
  end

  defp tool_call(state, token, name) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => modern_params(%{"name" => name, "arguments" => %{}})
    }

    :post
    |> conn("/mcp", Jason.encode!(request))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @modern)
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", name)
    |> Server.Plug.call(state)
  end

  defp modern_params(params) do
    Map.put(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    })
  end
end
