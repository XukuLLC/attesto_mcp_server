defmodule AttestoMCP.StdioExample.Boot do
  @moduledoc false

  def install! do
    original_group_leader = Process.group_leader()
    stderr_group_leader = Process.whereis(:standard_error)

    unless is_pid(stderr_group_leader) do
      raise "standard error group leader is unavailable"
    end

    # Mix and compiler workers write through their inherited group leader. A
    # forwarding group leader preserves every IO reply while routing all cold
    # install diagnostics to stderr; stdout remains exclusively JSON-RPC.
    proxy = spawn_link(fn -> forward_io(stderr_group_leader) end)
    Process.group_leader(self(), proxy)

    try do
      Mix.start()
      Mix.shell(Mix.Shell.Quiet)

      # A caller may use MIX_BUILD_PATH for its own test lane.  Mix.install
      # must retain its independent install cache instead of looking for the
      # project's dependency apps in that build tree (which is especially
      # visible on the Elixir 1.18/OTP 27 lane).  Restore the variable after
      # installation so the launcher does not mutate its caller's environment
      # beyond the duration of dependency setup.
      build_path = System.get_env("MIX_BUILD_PATH")
      System.delete_env("MIX_BUILD_PATH")

      try do
        Mix.install([{:attesto_mcp_server, path: Path.expand("..", __DIR__)}], verbose: false)
      after
        if build_path, do: System.put_env("MIX_BUILD_PATH", build_path)
      end
    after
      Process.group_leader(self(), original_group_leader)
      Process.exit(proxy, :normal)
    end
  end

  defp forward_io(stderr) do
    receive do
      {:io_request, from, _reply_as, _request} = message when is_pid(from) ->
        send(stderr, message)
        forward_io(stderr)

      message ->
        send(stderr, message)
        forward_io(stderr)
    end
  end
end

AttestoMCP.StdioExample.Boot.install!()

{:ok, server} = AttestoMCP.Server.start_link(name: :attesto_mcp_stdio_example)

:ok =
  AttestoMCP.Server.register_tool(server, "echo", %{
    description: "Return its input",
    input_schema: %{"type" => "object"},
    handler: fn params, _context -> {:ok, params} end
  })

AttestoMCP.Server.Stdio.run(server, context: %{principal: "stdio-example", tenant: "local"})
