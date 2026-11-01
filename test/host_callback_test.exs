defmodule AttestoMCP.Server.HostCallbackTest do
  # Changes application env, so not async.
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.HostCallback

  defmodule Target do
    def echo(first, second, extra), do: [first, second, extra]
    def allow(_context, _group), do: true
    def allow_all(_context), do: true
  end

  setup do
    previous = Application.fetch_env(:attesto_mcp_server, :host_callback_order)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:attesto_mcp_server, :host_callback_order, value)
        :error -> Application.delete_env(:attesto_mcp_server, :host_callback_order)
      end
    end)
  end

  test "a three-tuple receives the per-call arguments first and extra_args after them" do
    assert HostCallback.invoke({Target, :echo, [:extra]}, [:first, :second]) == [
             :first,
             :second,
             :extra
           ]

    assert HostCallback.valid?({Target, :echo, [:extra]}, 2)
    refute HostCallback.valid?({Target, :echo, [:extra]}, 3)
  end

  test "without confirmation, a three-tuple with extra_args is refused and names no argument value" do
    Application.delete_env(:attesto_mcp_server, :host_callback_order)

    error =
      assert_raise ArgumentError, fn ->
        HostCallback.valid?({Target, :echo, ["secret-token"]}, 2)
      end

    assert error.message =~ "AttestoMCP.Server.HostCallbackTest.Target.echo/3"
    assert error.message =~ "host_callback_order: :call_args_first"
    refute error.message =~ "secret-token"
  end

  test "without confirmation, functions, two-tuples and empty extra_args are accepted" do
    Application.delete_env(:attesto_mcp_server, :host_callback_order)

    assert HostCallback.valid?(fn _context -> true end, 1)
    assert HostCallback.valid?({Target, :allow_all}, 1)
    assert HostCallback.valid?({Target, :allow_all, []}, 1)
  end

  test "the confirmation in application config is accepted by the server, and only with its one value" do
    Application.put_env(:attesto_mcp_server, :host_callback_order, :call_args_first)
    assert {:ok, _server} = start_supervised({Server, server_name: "confirmed-order"})

    Application.put_env(:attesto_mcp_server, :host_callback_order, :extra_args_first)

    assert_raise ArgumentError, ~r/:host_callback_order must be :call_args_first/, fn ->
      AttestoMCP.Server.Options.normalize([])
    end
  end

  test "without confirmation, a tool's authorize three-tuple is refused at registration" do
    Application.delete_env(:attesto_mcp_server, :host_callback_order)
    server = start_supervised!({Server, server_name: "host-callback-order"})

    tool = fn authorize ->
      %{
        input_schema: %{"type" => "object"},
        handler: fn _, _ -> {:ok, "ok"} end,
        authorize: authorize
      }
    end

    assert {:error, {:callback_order_unconfirmed, :authorize}} =
             Server.register_tool(server, "unconfirmed", tool.({Target, :allow, ["operators"]}))

    assert :ok = Server.register_tool(server, "empty-extra", tool.({Target, :allow_all, []}))

    Application.put_env(:attesto_mcp_server, :host_callback_order, :call_args_first)
    assert :ok = Server.register_tool(server, "confirmed", tool.({Target, :allow, ["operators"]}))
  end
end
