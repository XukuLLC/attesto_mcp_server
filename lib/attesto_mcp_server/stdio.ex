defmodule AttestoMCP.Server.Stdio do
  @moduledoc "Line-delimited stdio adapter over the shared protocol core."

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Error, JSONRPC, Schema, Telemetry}

  @legacy "2025-11-25"
  @legacy_versions [@legacy, "2025-06-18"]
  @adapter_only_options [
    :context,
    :input,
    :principal,
    :tenant,
    :scopes,
    :on_server_request,
    :eof_grace_ms
  ]

  @doc "Run until stdin reaches EOF. Only compact JSON-RPC messages go to stdout."
  @spec run(pid() | atom(), keyword()) :: term()
  def run(server, opts \\ []) do
    Telemetry.execute([:stdio, :start], %{system_time: System.system_time()}, %{transport: :stdio})

    context = Keyword.get(opts, :context, stdio_context(opts))
    # The default stays conservative because the live-pipe fallback reads one
    # byte at a time to guarantee prompt newline delivery without retaining an
    # unterminated peer frame. Hosts handling larger bounded frames must opt in.
    json_budget = Server.options(server)[:max_json_bytes] || Schema.default_instance_bytes()
    max = Keyword.get(opts, :max_message_bytes, min(64_000, json_budget))

    unless is_integer(max) and max >= Schema.min_allowed_instance_bytes() and max <= json_budget do
      raise ArgumentError,
            ":max_message_bytes must be between #{Schema.min_allowed_instance_bytes()} and #{json_budget}"
    end

    input = Keyword.get(opts, :input, fn -> read_bounded_frame(max) end)

    unless is_function(input, 0) do
      raise ArgumentError, ":input must be a zero-arity function"
    end

    with {:ok, legacy_session} <-
           AttestoMCP.Server.new_session(
             server,
             context_principal(context),
             Map.get(context, :tenant) || Map.get(context, "tenant")
           ) do
      context = Map.put(context, :legacy_session_id, legacy_session.id)
      parent = self()

      {reader, reader_monitor} = spawn_monitor(fn -> read_loop(parent, input) end)
      Process.put(:attesto_mcp_stdio_pending, %{})
      # A stdio frame has its own transport ceiling.  Keep output under the
      # declared frame bound even when the server's value/schema budget is
      # larger.
      Process.put(:attesto_mcp_stdio_json_budget, max)

      try do
        loop(server, context, opts, max, reader, reader_monitor, %{})
      after
        stop_pending(Process.get(:attesto_mcp_stdio_pending, %{}))
        Process.delete(:attesto_mcp_stdio_pending)
        Process.delete(:attesto_mcp_stdio_json_budget)
        AttestoMCP.Server.delete_session(server, legacy_session.id)
        if Process.alive?(reader), do: Process.exit(reader, :kill)
        Process.demonitor(reader_monitor, [:flush])

        Telemetry.execute([:stdio, :stop], %{count: 1}, %{
          transport: :stdio,
          outcome: :closed
        })
      end
    else
      {:error, :session_store_unavailable} ->
        Telemetry.execute([:stdio, :stop], %{count: 1}, %{
          transport: :stdio,
          outcome: :unavailable
        })

        {:error, :session_store_unavailable}

      {:error, reason}
      when reason in [:nonportable_binding, :binding_too_large, :record_too_large] ->
        Telemetry.execute([:stdio, :stop], %{count: 1}, %{
          transport: :stdio,
          outcome: :rejected
        })

        {:error, reason}

      {:error, _reason} ->
        Telemetry.execute([:stdio, :stop], %{count: 1}, %{
          transport: :stdio,
          outcome: :unavailable
        })

        {:error, :session_store_unavailable}
    end
  end

  @doc "Starts a server, runs until EOF, and raises on an adapter startup failure."
  @spec main(keyword()) :: :ok | no_return()
  def main(opts \\ []) do
    # Adapter controls belong to run/2. Keep them out of server startup so a
    # normal command-line invocation can provide identity/input callbacks
    # without weakening the server's unknown-option validation.
    server_opts = Keyword.drop(opts, @adapter_only_options)
    {:ok, server} = AttestoMCP.Server.start_link(server_opts)

    try do
      case run(server, opts) do
        :ok -> :ok
        {:error, reason} -> raise RuntimeError, "stdio adapter failed: #{reason}"
      end
    after
      if Process.alive?(server), do: GenServer.stop(server)
    end
  end

  defp read_loop(parent, input) do
    try do
      case input.() do
        :eof ->
          send(parent, :stdio_eof)

        {:error, reason} ->
          send(parent, {:stdio_error, reason})

        {:oversized, reason} ->
          send(parent, {:stdio_oversized, reason})
          read_loop(parent, input)

        line when is_binary(line) ->
          send(parent, {:stdio_line, line})
          read_loop(parent, input)

        _other ->
          send(parent, {:stdio_error, :invalid_reader_result})
      end
    rescue
      _ -> send(parent, {:stdio_error, :reader_failure})
    catch
      :exit, _ -> send(parent, {:stdio_error, :reader_failure})
      _, _ -> send(parent, {:stdio_error, :reader_failure})
    end
  end

  defp read_bounded_frame(max) when is_integer(max) and max > 0 do
    read_bounded_frame(max, [], 0, false)
  end

  # Keep the one-byte read contract for live pipes (a larger IO.read can wait
  # for the requested size on OTP 27), but retain chunks as iodata.  Repeated
  # binary concatenation here made a near-limit frame quadratic on the floor
  # runtime and could make the peer close before the response was produced.
  defp read_bounded_frame(max, chunks, size, discarding) do
    case IO.read(:stdio, 1) do
      :eof ->
        cond do
          discarding -> {:oversized, :message_too_large}
          size == 0 -> :eof
          true -> IO.iodata_to_binary(Enum.reverse(chunks))
        end

      {:error, reason} ->
        {:error, reason}

      "\n" ->
        if discarding or size + 1 > max,
          do: {:oversized, :message_too_large},
          else: IO.iodata_to_binary(Enum.reverse(["\n" | chunks]))

      chunk when is_binary(chunk) ->
        if discarding do
          read_bounded_frame(max, [], 0, true)
        else
          next_size = size + byte_size(chunk)

          if next_size > max do
            read_bounded_frame(max, [], 0, true)
          else
            read_bounded_frame(max, [chunk | chunks], next_size, false)
          end
        end
    end
  end

  defp loop(server, context, opts, max, reader, reader_monitor, pending) do
    Process.put(:attesto_mcp_stdio_pending, pending)

    receive do
      {:stdio_line, line} ->
        pending = handle_line(server, context, opts, max, line, pending)
        loop(server, context, opts, max, reader, reader_monitor, pending)

      {:stdio_event, work_ref, event} ->
        if pending_ref?(pending, work_ref), do: write(event)
        loop(server, context, opts, max, reader, reader_monitor, pending)

      {:stdio_subscription_event, work_ref, subscription_id, event} ->
        case pending_entry(pending, work_ref) do
          %{pid: worker} ->
            write(event)
            send(worker, {:stdio_subscription_ack, subscription_id, :ok})

          _ ->
            :ok
        end

        loop(server, context, opts, max, reader, reader_monitor, pending)

      {:mcp_legacy_event, stream_ref, _event_id, event} ->
        if is_function(opts[:on_server_request], 1) and
             event["method"] in ["sampling/createMessage", "elicitation/create", "roots/list"] do
          safe_server_request_callback(opts[:on_server_request], event)
        end

        write(event)
        AttestoMCP.Server.ack_legacy_stream(server, stream_ref)
        loop(server, context, opts, max, reader, reader_monitor, pending)

      {:stdio_result, work_ref, result} ->
        case take_ref(pending, work_ref) do
          {:ok, id, pending} ->
            if result != :notification, do: write(result_response(id, result))
            loop(server, context, opts, max, reader, reader_monitor, pending)

          :missing ->
            loop(server, context, opts, max, reader, reader_monitor, pending)
        end

      {:DOWN, ^reader_monitor, :process, ^reader, reason} ->
        if reason == :normal do
          receive do
            :stdio_eof ->
              deadline =
                System.monotonic_time(:millisecond) +
                  (Keyword.get(opts, :eof_grace_ms) || 100)

              drain_pending(pending, deadline)
              :ok

            {:stdio_error, _reason} ->
              IO.puts(:stderr, "stdio input error")
              stop_pending(pending)
              :ok
          after
            0 ->
              loop(server, context, opts, max, reader, reader_monitor, pending)
          end
        else
          IO.puts(:stderr, "stdio reader stopped")
          stop_pending(pending)
          :ok
        end

      {:DOWN, monitor, :process, _pid, _reason} ->
        case take_monitor(pending, monitor) do
          {:ok, id, pending} ->
            if not is_nil(id),
              do:
                write(JSONRPC.error_response(id, Error.internal(%{"reason" => "worker_failure"})))

            loop(server, context, opts, max, reader, reader_monitor, pending)

          :missing ->
            loop(server, context, opts, max, reader, reader_monitor, pending)
        end

      :stdio_eof ->
        deadline = System.monotonic_time(:millisecond) + (Keyword.get(opts, :eof_grace_ms) || 100)
        drain_pending(pending, deadline)
        :ok

      {:stdio_error, _reason} ->
        IO.puts(:stderr, "stdio input error")
        stop_pending(pending)
        :ok

      {:stdio_oversized, reason} ->
        write(JSONRPC.error_response(nil, Error.parse(%{"reason" => to_string(reason)})))
        loop(server, context, opts, max, reader, reader_monitor, pending)
    end
  end

  defp handle_line(server, context, opts, max, line, pending) do
    line = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")

    case JSONRPC.decode(line, max_bytes: max) do
      {:ok, %{kind: :notification, method: "notifications/cancelled", params: params}} ->
        cancel_request(server, context, pending, params)

      {:ok, %{kind: :notification, method: "notifications/initialized"} = request} ->
        if legacy_version?(version_for(request)) and mark_legacy_initialized(server, context) do
          start_worker(server, context, opts, request, pending)
        else
          pending
        end

      {:ok, %{kind: :response} = response} ->
        route_legacy_response(server, context, response)
        pending

      {:ok, request} ->
        start_worker(server, context, opts, request, pending)

      {:error, error} ->
        write(JSONRPC.error_response(JSONRPC.recover_id(line, max_bytes: max), error))
        pending
    end
  end

  defp start_worker(server, context, opts, request, pending) do
    parent = self()
    work_ref = make_ref()
    id = Map.get(request, :id)
    key = if is_nil(id), do: {:notification, work_ref}, else: id

    case legacy_not_ready?(server, context, request) do
      true ->
        if not is_nil(id),
          do:
            write(
              JSONRPC.error_response(
                id,
                Error.invalid_request(%{"reason" => "initialized_notification_required"})
              )
            )

        pending

      readiness when readiness in [false, :session_store_unavailable] ->
        # Keep a readiness outage attached to this request even if the
        # request-context lookup below happens to recover. The core dispatch
        # still performs validation and authorization before returning its
        # neutral store-unavailable response; it must never reach a handler.
        context =
          if readiness == :session_store_unavailable,
            do: Map.put(context, :session_store_unavailable, true),
            else: context

        case allow_rate(server, context, request) do
          :ok ->
            if not is_nil(id) and Map.has_key?(pending, key) do
              write(
                JSONRPC.error_response(id, Error.invalid_request(%{"reason" => "duplicate_id"}))
              )

              pending
            else
              start_worker_process(
                server,
                context,
                opts,
                request,
                pending,
                id,
                key,
                parent,
                work_ref
              )
            end

          {:error, :rate_limited} ->
            if not is_nil(id),
              do: write(JSONRPC.error_response(id, Error.rate_limited()))

            pending
        end
    end
  end

  defp allow_rate(server, context, request) do
    category =
      case Map.get(request, :method) do
        "completion/complete" ->
          :completion

        "subscriptions/listen" ->
          :subscriptions

        _ ->
          :calls
      end

    key = {:principal, context_principal(context), :stdio}
    AttestoMCP.Server.allow_rate(server, key, category)
  rescue
    _ -> {:error, :rate_limited}
  end

  defp start_worker_process(server, context, opts, request, pending, id, key, parent, work_ref) do
    request_context = request_context(server, context, request)

    {pid, monitor} =
      spawn_monitor(fn ->
        on_event = fn event -> send(parent, {:stdio_event, work_ref, event}) end

        result =
          AttestoMCP.Server.dispatch(server, request, request_context,
            transport: :stdio,
            version: dispatch_version_for(request, request_context),
            owner: self(),
            on_event: on_event,
            request_ref: work_ref,
            timeout: Keyword.get(opts, :request_timeout) || 30_000
          )

        case result do
          {response_id, response} when request.method == "subscriptions/listen" ->
            case get_in(response, ["result", "_meta", "io.modelcontextprotocol/subscriptionId"]) do
              subscription_id when is_binary(subscription_id) or is_integer(subscription_id) ->
                subscription_loop(
                  server,
                  parent,
                  work_ref,
                  response_id,
                  response,
                  subscription_id,
                  Keyword.get(opts, :subscription_timeout) || 300_000
                )

              _ ->
                send(parent, {:stdio_result, work_ref, result})
            end

          _ ->
            send(parent, {:stdio_result, work_ref, result})
        end
      end)

    Map.put(pending, key, %{id: id, pid: pid, monitor: monitor, ref: work_ref})
  end

  defp cancel_request(server, context, pending, params) do
    request_id = params["requestId"] || params["request_id"]

    case pending[request_id] do
      %{pid: owner} when is_pid(owner) ->
        AttestoMCP.Server.cancel_request(server, context_principal(context), request_id, owner)
        AttestoMCP.Server.cancel_subscription(server, request_id, owner)

      _ ->
        :ok
    end

    pending
  end

  defp subscription_loop(
         server,
         parent,
         work_ref,
         response_id,
         response,
         subscription_id,
         timeout
       ) do
    receive do
      {:mcp_subscription, ^work_ref, ^subscription_id, event} ->
        send(parent, {:stdio_subscription_event, work_ref, subscription_id, event})

        receive do
          {:stdio_subscription_ack, ^subscription_id, :ok} ->
            AttestoMCP.Server.ack_subscription(server, subscription_id, self())

            subscription_loop(
              server,
              parent,
              work_ref,
              response_id,
              response,
              subscription_id,
              timeout
            )

          {:stdio_subscription_ack, ^subscription_id, {:error, _reason}} ->
            AttestoMCP.Server.close_subscription(server, subscription_id, self())
            send(parent, {:stdio_result, work_ref, {response_id, response}})
        after
          timeout ->
            AttestoMCP.Server.close_subscription(server, subscription_id, self())
            send(parent, {:stdio_result, work_ref, {response_id, response}})
        end

      {:mcp_subscription_cancel, ^subscription_id} ->
        send(parent, {:stdio_result, work_ref, {response_id, response}})

      {:mcp_subscription_close, ^subscription_id} ->
        send(parent, {:stdio_result, work_ref, {response_id, response}})

      _other ->
        subscription_loop(
          server,
          parent,
          work_ref,
          response_id,
          response,
          subscription_id,
          timeout
        )
    after
      timeout ->
        AttestoMCP.Server.close_subscription(server, subscription_id, self())
        send(parent, {:stdio_result, work_ref, {response_id, response}})
    end
  end

  defp context_principal(context) do
    Map.get(
      context,
      :principal_binding,
      Map.get(
        context,
        "principal_binding",
        Map.get(context, :principal, Map.get(context, "principal"))
      )
    )
  end

  defp request_context(server, context, request) do
    if legacy_version?(version_for(request)) do
      session_id = context[:legacy_session_id]
      tenant = Map.get(context, :tenant) || Map.get(context, "tenant")

      case legacy_session_lookup(
             server,
             session_id,
             context_principal(context),
             tenant,
             request
           ) do
        {:ok, session} ->
          context
          |> Map.put(:session_id, session_id)
          |> Map.put(:protocol_version, session.version)
          |> Map.put(
            :legacy_session_state,
            if(is_nil(session.version), do: :unnegotiated, else: :negotiated)
          )
          |> Map.put(:logging_level, session.logging_level)

        {:error, :session_store_unavailable} ->
          context
          |> Map.put(:session_id, session_id)
          |> Map.put(:protocol_version, nil)
          |> Map.put(:legacy_session_state, :unavailable)
          |> Map.put(:session_store_unavailable, true)

        _ ->
          context
          |> Map.put(:session_id, session_id)
          |> Map.put(:protocol_version, nil)
          |> Map.put(:legacy_session_state, :unavailable)
      end
    else
      Map.delete(context, :session_id)
    end
  end

  defp mark_legacy_initialized(server, context) do
    mark_legacy_initialized(
      server,
      context,
      System.monotonic_time(:millisecond) + 100
    )
  end

  defp mark_legacy_initialized(server, context, deadline) do
    session_id = context[:legacy_session_id]

    case AttestoMCP.Server.get_session(
           server,
           session_id,
           context_principal(context),
           Map.get(context, :tenant) || Map.get(context, "tenant")
         ) do
      {:ok, %{version: version}} when version in @legacy_versions ->
        case AttestoMCP.Server.mark_initialized(server, session_id) do
          :ok ->
            _ =
              AttestoMCP.Server.open_legacy_stream(
                server,
                session_id,
                context_principal(context),
                Map.get(context, :tenant) || Map.get(context, "tenant"),
                self()
              )

            true

          {:error, _reason} ->
            false
        end

      {:ok, %{version: nil}} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          mark_legacy_initialized(server, context, deadline)
        else
          false
        end

      _ ->
        false
    end
  end

  defp route_legacy_response(server, context, response) do
    result =
      AttestoMCP.Server.deliver_client_response(
        server,
        context[:legacy_session_id],
        context_principal(context),
        Map.get(context, :tenant) || Map.get(context, "tenant"),
        response
      )

    case result do
      :ok ->
        :ok

      {:error, {:client_error, _error}} ->
        :ok

      {:error, :invalid_response} ->
        write(
          JSONRPC.error_response(
            response.id,
            Error.invalid_request(%{"reason" => "invalid_client_response"})
          )
        )

      {:error, :not_found} ->
        write(
          JSONRPC.error_response(
            response.id,
            Error.invalid_request(%{"reason" => "unsolicited_response"})
          )
        )

      {:error, :session_store_unavailable} ->
        write(JSONRPC.error_response(response.id, Error.session_store_unavailable()))
    end

    :ok
  end

  defp legacy_not_ready?(server, context, request) do
    if legacy_version?(version_for(request)) and
         request.method not in ["initialize", "ping", "notifications/initialized"] do
      case legacy_session_lookup(
             server,
             context[:legacy_session_id],
             context_principal(context),
             Map.get(context, :tenant) || Map.get(context, "tenant"),
             request
           ) do
        {:ok, session} -> not session.initialized
        # A backing-store outage must not create a transient window in which
        # a legacy request can run before request_context/3 checks the store.
        {:error, :session_store_unavailable} -> :session_store_unavailable
        _ -> true
      end
    else
      false
    end
  end

  defp legacy_session_lookup(server, id, principal, tenant, %{method: method})
       when method in ["resources/subscribe", "resources/unsubscribe"],
       do: AttestoMCP.Server.peek_session(server, id, principal, tenant)

  defp legacy_session_lookup(server, id, principal, tenant, _request),
    do: AttestoMCP.Server.get_session(server, id, principal, tenant)

  defp take_ref(pending, ref) do
    case Enum.find(pending, fn {_id, entry} -> entry.ref == ref end) do
      {key, entry} ->
        Process.demonitor(entry.monitor, [:flush])
        {:ok, entry.id, Map.delete(pending, key)}

      nil ->
        :missing
    end
  end

  defp take_monitor(pending, monitor) do
    case Enum.find(pending, fn {_id, entry} -> entry.monitor == monitor end) do
      {key, entry} -> {:ok, entry.id, Map.delete(pending, key)}
      nil -> :missing
    end
  end

  defp pending_ref?(pending, ref), do: Enum.any?(pending, fn {_id, entry} -> entry.ref == ref end)

  defp pending_entry(pending, ref),
    do: Enum.find_value(pending, fn {_id, entry} -> if entry.ref == ref, do: entry end)

  defp result_response(_id, {response_id, response}),
    do: response || JSONRPC.response(response_id, %{})

  defp result_response(id, _),
    do: JSONRPC.error_response(id, Error.internal(%{"reason" => "worker_failure"}))

  defp stop_pending(pending) do
    Enum.each(pending, fn {_id, entry} ->
      Process.exit(entry.pid, :kill)
      Process.demonitor(entry.monitor, [:flush])
    end)
  end

  # EOF is a transport loss for active work, but already-completed responses
  # must not be discarded merely because the reader delivered EOF first.  A
  # short, explicit grace window drains ready results; anything still active
  # is then cancelled and reclaimed by the server's owner monitor.
  defp drain_pending(pending, _deadline) when map_size(pending) == 0, do: :ok

  defp drain_pending(pending, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      stop_pending(pending)
      :ok
    else
      receive do
        {:stdio_event, work_ref, event} ->
          if pending_ref?(pending, work_ref), do: write(event)
          drain_pending(pending, deadline)

        {:stdio_subscription_event, work_ref, subscription_id, event} ->
          case pending_entry(pending, work_ref) do
            %{pid: worker} ->
              write(event)
              send(worker, {:stdio_subscription_ack, subscription_id, :ok})

            _ ->
              :ok
          end

          drain_pending(pending, deadline)

        {:stdio_result, work_ref, result} ->
          case take_ref(pending, work_ref) do
            {:ok, id, pending} ->
              if result != :notification, do: write(result_response(id, result))
              drain_pending(pending, deadline)

            :missing ->
              drain_pending(pending, deadline)
          end

        {:DOWN, monitor, :process, _pid, _reason} ->
          case take_monitor(pending, monitor) do
            {:ok, id, pending} ->
              if not is_nil(id),
                do:
                  write(
                    JSONRPC.error_response(id, Error.internal(%{"reason" => "worker_failure"}))
                  )

              drain_pending(pending, deadline)

            :missing ->
              drain_pending(pending, deadline)
          end
      after
        remaining ->
          stop_pending(pending)
          :ok
      end
    end
  end

  defp write(message) do
    max_bytes = Process.get(:attesto_mcp_stdio_json_budget, Schema.default_instance_bytes())
    encoded = JSONRPC.encode(message, max_bytes: max_bytes)

    encoded =
      if byte_size(encoded) + 1 <= max_bytes do
        encoded
      else
        bounded_frame_error(message, max_bytes)
      end

    IO.write(encoded <> "\n")
  end

  defp bounded_frame_error(message, max_bytes) do
    error = frame_error(message)
    encoded = Jason.encode!(error)

    if byte_size(encoded) + 1 <= max_bytes do
      encoded
    else
      Jason.encode!(%{error | "id" => nil})
    end
  end

  defp frame_error(message) do
    id = Map.get(message, "id")

    %{
      "jsonrpc" => "2.0",
      "id" => if(is_binary(id) or is_integer(id), do: id, else: nil),
      "error" => %{"code" => -32603, "message" => "Internal error"}
    }
  end

  defp safe_server_request_callback(callback, event) when is_function(callback, 1) do
    try do
      callback.(event)
    rescue
      _ -> IO.puts(:stderr, "stdio server-request callback failed")
    catch
      _, _ -> IO.puts(:stderr, "stdio server-request callback failed")
    end
  end

  defp safe_server_request_callback(_callback, _event), do: :ok

  defp version_for(%{method: "initialize", params: params}) when is_map(params) do
    modern = metadata_value(params, "io.modelcontextprotocol/protocolVersion")
    requested = params["protocolVersion"]

    cond do
      is_binary(modern) -> "2026-07-28"
      requested in @legacy_versions -> requested
      true -> @legacy
    end
  end

  defp version_for(%{method: "initialize"}), do: @legacy
  defp version_for(%{method: "notifications/initialized"}), do: @legacy

  defp version_for(%{params: params}) do
    metadata_value(params, "io.modelcontextprotocol/protocolVersion") || @legacy
  end

  defp dispatch_version_for(%{method: "initialize"} = request, _context),
    do: version_for(request)

  defp dispatch_version_for(request, context) do
    version = version_for(request)

    cond do
      not legacy_version?(version) -> version
      context[:session_store_unavailable] == true -> @legacy
      context[:protocol_version] in @legacy_versions -> context[:protocol_version]
      request.method == "ping" -> @legacy
      true -> nil
    end
  end

  defp legacy_version?(version), do: version in @legacy_versions

  defp metadata_value(params, key) do
    case Map.get(params, "_meta") do
      metadata when is_map(metadata) -> Map.get(metadata, key)
      _ -> nil
    end
  end

  defp stdio_context(opts) do
    %{
      principal: Keyword.get(opts, :principal, System.get_env("ATTESTO_MCP_PRINCIPAL", "stdio")),
      tenant: Keyword.get(opts, :tenant, System.get_env("ATTESTO_MCP_TENANT")),
      scopes: Keyword.get(opts, :scopes, []),
      credentials: :environment
    }
  end
end
