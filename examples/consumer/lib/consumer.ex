defmodule AttestoMCP.ExternalConsumer do
  @moduledoc "Clean external-consumer compilation exercise for both adapters."

  alias AttestoMCP.Server.API

  @spec build_server() :: {:ok, pid()}
  def build_server do
    with {:ok, server} <- API.start_link([]),
         :ok <- API.register_tool(server, "echo", %{handler: fn args, _ -> {:ok, args} end}),
         :ok <- API.register_resource(server, "urn:consumer", %{handler: fn _, _ -> {:ok, []} end}),
         :ok <- API.register_resource_template(server, "urn:consumer/{id}", %{handler: fn _, _ -> {:ok, []} end}),
         :ok <- API.register_prompt(server, "consumer_prompt", %{handler: fn _, _ -> {:ok, []} end}),
         :ok <-
           API.register_completion(server, "consumer_completion", %{
             ref: %{"type" => "ref/prompt", "name" => "consumer_prompt"},
             handler: fn _, _ -> {:ok, []} end
           }) do
      {:ok, server}
    end
  end

  @spec plug(pid()) :: map()
  def plug(server) do
    AttestoMCP.Server.Plug.init(
      server: server,
      path: "/mcp",
      auth: [
        resource: "https://consumer.example/mcp",
        issuer: "https://issuer.example"
      ]
    )
  end

  @spec stdio(pid()) :: term()
  def stdio(server), do: AttestoMCP.Server.Stdio.run(server, input: fn -> :eof end, context: %{principal: "consumer"})
end
