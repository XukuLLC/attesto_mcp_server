defmodule AttestoMCP.Server.TestSupport.Async do
  @moduledoc false

  def eventually(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    attempts = Keyword.get(opts, :attempts, 100)
    interval_ms = Keyword.get(opts, :interval_ms, 10)
    catch_exit? = Keyword.get(opts, :catch_exit, false)
    final_check? = Keyword.get(opts, :final_check, false)

    true = is_integer(attempts) and attempts >= 0
    true = is_integer(interval_ms) and interval_ms >= 0

    do_eventually(fun, attempts, interval_ms, catch_exit?, final_check?)
  end

  defp do_eventually(fun, 0, _interval_ms, catch_exit?, true),
    do: invoke(fun, catch_exit?)

  defp do_eventually(_fun, 0, _interval_ms, _catch_exit?, false), do: false

  defp do_eventually(fun, attempts, interval_ms, catch_exit?, final_check?) do
    if invoke(fun, catch_exit?) do
      true
    else
      Process.sleep(interval_ms)
      do_eventually(fun, attempts - 1, interval_ms, catch_exit?, final_check?)
    end
  end

  defp invoke(fun, false), do: fun.()

  defp invoke(fun, true) do
    fun.()
  catch
    :exit, _reason -> false
  end
end
