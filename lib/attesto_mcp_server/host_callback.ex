defmodule AttestoMCP.Server.HostCallback do
  @moduledoc false

  @spec valid?(term(), non_neg_integer()) :: boolean()
  def valid?(callback, arity) when is_function(callback, arity), do: true

  def valid?({module, function}, arity)
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0,
      do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  def valid?({module, function, prefix_args}, arity)
      when is_atom(module) and is_atom(function) and is_list(prefix_args) and is_integer(arity) and
             arity >= 0,
      do:
        Code.ensure_loaded?(module) and
          function_exported?(module, function, length(prefix_args) + arity)

  def valid?(_callback, _arity), do: false

  @spec invoke(term(), [term()]) :: term()
  def invoke(callback, arguments) when is_function(callback) and is_list(arguments),
    do: apply(callback, arguments)

  def invoke({module, function}, arguments) when is_list(arguments),
    do: apply(module, function, arguments)

  def invoke({module, function, prefix_args}, arguments)
      when is_list(prefix_args) and is_list(arguments),
      do: apply(module, function, prefix_args ++ arguments)
end
