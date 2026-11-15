defmodule AttestoMCP.Server.DeadlineLoop do
  @moduledoc false

  @doc false
  @spec remaining_ms(integer()) :: integer()
  def remaining_ms(deadline), do: deadline - System.monotonic_time(:millisecond)

  @doc false
  @spec past?(integer()) :: boolean()
  def past?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  @doc false
  @spec before?(integer()) :: boolean()
  def before?(deadline), do: System.monotonic_time(:millisecond) < deadline

  # The deadline is checked before entering `receive` because a waiting
  # mailbox message takes precedence over an expired `after` clause, which
  # would otherwise keep a steady event stream open past its deadline.
  @doc false
  @spec run(
          integer(),
          state,
          (state, pos_integer() -> {:cont, state} | {:done, result}),
          (state -> result)
        ) ::
          result
        when state: var, result: var
  def run(deadline, state, on_wait, on_timeout)
      when is_integer(deadline) and is_function(on_wait, 2) and is_function(on_timeout, 1) do
    remaining = remaining_ms(deadline)

    if remaining > 0 do
      case on_wait.(state, remaining) do
        {:cont, next_state} -> run(deadline, next_state, on_wait, on_timeout)
        {:done, result} -> result
      end
    else
      on_timeout.(state)
    end
  end
end
