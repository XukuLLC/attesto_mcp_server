defmodule AttestoMCP.Server.HostCallback do
  @moduledoc """
  Validation and invocation for host-supplied callbacks in `AttestoMCP.Server`.

  A callback is a function, `{module, function}`, or
  `{module, function, extra_args}`. For the three-tuple form, `invoke/2`
  passes the per-call arguments first and `extra_args` after them
  (`apply(module, function, arguments ++ extra_args)`), the order every
  Attesto package uses for host callbacks.

  Releases before 3.0 passed `extra_args` first. Arity is the same either way,
  so a callback left in the old order would start and then receive its
  arguments swapped. A three-tuple with non-empty `extra_args` is therefore
  refused until the host confirms the order with
  `config :attesto_mcp_server, host_callback_order: :call_args_first`.
  An empty `extra_args` list is unaffected.
  """

  @order_key :host_callback_order
  @confirmed_order :call_args_first

  @spec valid?(term(), non_neg_integer()) :: boolean()
  def valid?(callback, arity) when is_function(callback, arity), do: true

  def valid?({module, function}, arity)
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0,
      do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  def valid?({module, function, extra_args} = callback, arity)
      when is_atom(module) and is_atom(function) and is_list(extra_args) and is_integer(arity) and
             arity >= 0 do
    confirm_order!(callback, arity)

    Code.ensure_loaded?(module) and
      function_exported?(module, function, arity + length(extra_args))
  end

  def valid?(_callback, _arity), do: false

  @doc false
  # Whether a callback's argument order is settled: anything but a three-tuple
  # with non-empty extra_args is, and such a tuple is once the host confirms.
  @spec order_confirmed?(term()) :: boolean()
  def order_confirmed?({_module, _function, [_ | _]}),
    do: Application.get_env(:attesto_mcp_server, @order_key) == @confirmed_order

  def order_confirmed?(_callback), do: true

  @doc false
  @spec confirm_order!(term(), non_neg_integer()) :: :ok
  def confirm_order!(callback, arity) do
    if order_confirmed?(callback),
      do: :ok,
      else: raise(ArgumentError, order_message(callback, arity))
  end

  @doc false
  # Names the function and argument counts only; extra_args values can be
  # credentials and are never rendered.
  @spec order_message({module(), atom(), list()}, non_neg_integer()) :: String.t()
  def order_message({module, function, extra_args}, arity) do
    extra = length(extra_args)
    name = "#{inspect(module)}.#{function}/#{arity + extra}"

    "#{name} is configured with #{extra} extra argument(s). Since attesto_mcp_server 3.0 it is " <>
      "called with its #{arity} per-call argument(s) first and the extra argument(s) last; " <>
      "releases before 3.0 passed the extra arguments first. Reorder its parameters if needed, " <>
      "then confirm with `config :attesto_mcp_server, host_callback_order: :call_args_first`."
  end

  @spec invoke(term(), [term()]) :: term()
  def invoke(callback, arguments) when is_function(callback) and is_list(arguments),
    do: apply(callback, arguments)

  def invoke({module, function}, arguments) when is_list(arguments),
    do: apply(module, function, arguments)

  def invoke({module, function, extra_args}, arguments)
      when is_list(extra_args) and is_list(arguments),
      do: apply(module, function, arguments ++ extra_args)
end
