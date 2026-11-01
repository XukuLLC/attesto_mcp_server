Code.require_file("support/async.ex", __DIR__)
Code.require_file("support/http_client.ex", __DIR__)
Code.require_file("support/owned_port.ex", __DIR__)
Code.require_file("support/server_case.ex", __DIR__)

# The suite's three-tuple callbacks are written for the 3.0 argument order.
Application.put_env(:attesto_mcp_server, :host_callback_order, :call_args_first)

ExUnit.start()
