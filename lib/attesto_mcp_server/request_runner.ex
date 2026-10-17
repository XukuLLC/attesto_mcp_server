defmodule AttestoMCP.Server.RequestRunner do
  @moduledoc false

  alias AttestoMCP.Server.{Error, Subscriptions, Telemetry}

  @doc false
  def start(supervisor, callback), do: Task.Supervisor.start_child(supervisor, callback)

  @doc false
  def detached_delivery(on_event, true) when is_function(on_event, 1) do
    fn event ->
      try do
        case on_event.(event) do
          {:error, _reason} -> :ok
          result -> result
        end
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end
  end

  def detached_delivery(on_event, _detached), do: on_event

  @doc false
  def await(ref, task, timeout, on_event, subscriptions, keepalive_ms) do
    task_monitor = Process.monitor(task)
    started = System.monotonic_time(:millisecond)

    keepalive_timer =
      if is_integer(keepalive_ms) and keepalive_ms > 0,
        do: Process.send_after(self(), {ref, :keepalive}, keepalive_ms)

    try do
      await_loop(
        ref,
        task,
        task_monitor,
        timeout,
        on_event,
        subscriptions,
        started,
        keepalive_ms,
        keepalive_timer
      )
    rescue
      _ ->
        kill(task, task_monitor)
        {:error, Error.internal(%{"reason" => "event_delivery_failure"})}
    catch
      _, _ ->
        kill(task, task_monitor)
        {:error, Error.internal(%{"reason" => "event_delivery_failure"})}
    end
  end

  @doc false
  def kill(task, task_monitor) do
    Process.unlink(task)
    Process.exit(task, :kill)
    reap(task_monitor, task)
  end

  defp await_loop(
         ref,
         task,
         task_monitor,
         timeout,
         on_event,
         subscriptions,
         started,
         keepalive_ms,
         keepalive_timer
       ) do
    receive do
      {^ref, :keepalive} ->
        delivery = deliver(on_event, :keepalive)

        next_timer =
          if is_integer(keepalive_ms) and keepalive_ms > 0,
            do: Process.send_after(self(), {ref, :keepalive}, keepalive_ms)

        continue_or_stop(
          delivery,
          ref,
          task,
          task_monitor,
          timeout,
          on_event,
          subscriptions,
          started,
          keepalive_ms,
          next_timer
        )

      {^ref, :progress, delivery_ref, event} ->
        delivery = deliver(on_event, event)
        send(task, {ref, :progress_ack, delivery_ref, delivery})

        continue_or_stop(
          delivery,
          ref,
          task,
          task_monitor,
          timeout,
          on_event,
          subscriptions,
          started,
          keepalive_ms,
          keepalive_timer
        )

      {^ref, :progress, event} ->
        delivery = deliver(on_event, event)

        continue_or_stop(
          delivery,
          ref,
          task,
          task_monitor,
          timeout,
          on_event,
          subscriptions,
          started,
          keepalive_ms,
          keepalive_timer
        )

      {^ref, :progress_error, _reason} ->
        stop_after_delivery_failure(task, task_monitor, keepalive_timer, ref)

      {^ref, :notification, delivery_ref, event} ->
        delivery = deliver(on_event, event)
        send(task, {ref, :notification_ack, delivery_ref, delivery})

        continue_or_stop(
          delivery,
          ref,
          task,
          task_monitor,
          timeout,
          on_event,
          subscriptions,
          started,
          keepalive_ms,
          keepalive_timer
        )

      {:mcp_subscription, ^ref, id, event} ->
        delivery = deliver(on_event, event)
        Subscriptions.ack(subscriptions, id, self())

        continue_or_stop(
          delivery,
          ref,
          task,
          task_monitor,
          timeout,
          on_event,
          subscriptions,
          started,
          keepalive_ms,
          keepalive_timer
        )

      {^ref, :cancelled} ->
        cancel_keepalive_timer(keepalive_timer, ref)
        kill(task, task_monitor)
        {:error, Error.cancelled()}

      {^ref, :result, result} ->
        cancel_keepalive_timer(keepalive_timer, ref)
        reap(task_monitor, task)
        result

      {:DOWN, ^task_monitor, :process, ^task, _reason} ->
        cancel_keepalive_timer(keepalive_timer, ref)
        {:error, Error.internal(%{"reason" => "handler_exit"})}
    after
      max(timeout - (System.monotonic_time(:millisecond) - started), 0) ->
        Telemetry.execute([:request, :timeout], %{count: 1}, %{outcome: :timeout})
        cancel_keepalive_timer(keepalive_timer, ref)
        kill(task, task_monitor)
        {:error, Error.internal(%{"reason" => "timeout"})}
    end
  end

  defp continue_or_stop(
         :ok,
         ref,
         task,
         task_monitor,
         timeout,
         on_event,
         subscriptions,
         started,
         keepalive_ms,
         keepalive_timer
       ) do
    await_loop(
      ref,
      task,
      task_monitor,
      timeout,
      on_event,
      subscriptions,
      started,
      keepalive_ms,
      keepalive_timer
    )
  end

  defp continue_or_stop(
         {:error, _reason},
         ref,
         task,
         task_monitor,
         _timeout,
         _on_event,
         _subscriptions,
         _started,
         _keepalive_ms,
         keepalive_timer
       ),
       do: stop_after_delivery_failure(task, task_monitor, keepalive_timer, ref)

  defp deliver(on_event, event) when is_function(on_event, 1) do
    try do
      case on_event.(event) do
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end
    rescue
      _ -> {:error, :delivery_callback_failed}
    catch
      _, _ -> {:error, :delivery_callback_failed}
    end
  end

  defp deliver(_on_event, _event), do: :ok

  defp stop_after_delivery_failure(task, task_monitor, keepalive_timer, ref) do
    Telemetry.execute([:stream, :exception], %{count: 1}, %{
      transport: :core,
      outcome: :delivery_failed
    })

    cancel_keepalive_timer(keepalive_timer, ref)
    kill(task, task_monitor)
    {:error, Error.internal(%{"reason" => "event_delivery_failure"})}
  end

  defp cancel_keepalive_timer(nil, _ref), do: :ok

  defp cancel_keepalive_timer(timer, ref) do
    _ = Process.cancel_timer(timer)

    receive do
      {^ref, :keepalive} -> :ok
    after
      0 -> :ok
    end
  end

  defp reap(task_monitor, task) do
    receive do
      {:DOWN, ^task_monitor, :process, ^task, _reason} -> :ok
    after
      5_000 ->
        Process.demonitor(task_monitor, [:flush])
        :ok
    end
  end
end
