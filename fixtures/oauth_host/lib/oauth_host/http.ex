defmodule OAuthHost.HTTP do
  @moduledoc false
  @behaviour Plug

  def init(state), do: state

  def call(conn, state) do
    host = Agent.get(state, & &1)

    conn
    |> Plug.Conn.register_before_send(&record_response(&1, host.owner))
    |> OAuthHost.call(host)
  end

  defp record_response(conn, owner) do
    # Capture only status and OAuth error names, never tokens or code values.
    error =
      if conn.status >= 400 do
        case Jason.decode(conn.resp_body) do
          {:ok, %{"error" => error}} when is_binary(error) -> error
          _ -> nil
        end
      end

    send(
      owner,
      {:oauth_network_response, conn.method, conn.request_path, conn.status, error}
    )

    conn
  end
end
