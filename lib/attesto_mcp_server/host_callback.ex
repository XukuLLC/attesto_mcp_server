defmodule AttestoMCP.Server.HostCallback do
  @moduledoc """
  Validation and invocation for host-supplied callbacks in `AttestoMCP.Server`.

  A callback is a function, `{module, function}`, or
  `{module, function, extra_args}`. For the three-tuple form, `invoke/2`
  passes the per-call arguments first and `extra_args` after them
  (`apply(module, function, arguments ++ extra_args)`), the order every
  Attesto package uses for host callbacks.
  """

  @spec valid?(term(), non_neg_integer()) :: boolean()
  def valid?(callback, arity) when is_function(callback, arity), do: true

  def valid?({module, function}, arity)
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0,
      do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  def valid?({module, function, extra_args}, arity)
      when is_atom(module) and is_atom(function) and is_list(extra_args) and is_integer(arity) and
             arity >= 0,
      do:
        Code.ensure_loaded?(module) and
          function_exported?(module, function, arity + length(extra_args))

  def valid?(_callback, _arity), do: false

  @spec invoke(term(), [term()]) :: term()
  def invoke(callback, arguments) when is_function(callback) and is_list(arguments),
    do: apply(callback, arguments)

  def invoke({module, function}, arguments) when is_list(arguments),
    do: apply(module, function, arguments)

  def invoke({module, function, extra_args}, arguments)
      when is_list(extra_args) and is_list(arguments),
      do: apply(module, function, arguments ++ extra_args)
end
