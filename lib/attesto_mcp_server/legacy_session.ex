defmodule AttestoMCP.Server.LegacySession do
  @moduledoc false

  alias AttestoMCP.Server

  @untouched_methods ["resources/subscribe", "resources/unsubscribe"]

  @doc false
  def lookup(server, id, principal, tenant, request, opts \\ []) do
    method = if is_map(request), do: request[:method] || request["method"], else: nil
    touch? = method not in @untouched_methods and Keyword.get(opts, :touch, true)

    if touch?,
      do: Server.get_session(server, id, principal, tenant),
      else: Server.peek_session(server, id, principal, tenant)
  end
end
