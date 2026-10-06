defmodule AttestoMCP.Server.Presentation do
  @moduledoc """
  Request-scoped server guidance and tool presentation.

  ## Instructions

  `:instructions` remains a static string. `:instructions_provider` is an
  optional one-argument callback (a function, `{module, function}`, or
  `{module, function, prefix_args}`) that receives the trusted request context
  and returns:

    * `{:ok, instructions}` with a non-empty UTF-8 string of at most 65,536
      bytes;
    * `:omit` to send no instructions for this request; or
    * `{:error, reason}` to fail the request.

  A configured provider supplies the instructions for modern `server/discover`
  and legacy `initialize`; the static string is used only when no provider is
  configured. A failing provider never falls back to the static string. An
  error, exception, exit, throw, invalid value, or request timeout returns a
  controlled internal error (`"instructions_provider_failure"`) and publishes
  no instructions. A failed legacy `initialize` leaves the session
  unnegotiated, so a later valid `initialize` can succeed.

  ## Tool presentation

  `:tool_presentation` is an optional two-argument callback that receives an
  already visible tool's public descriptor (string keys) and the trusted
  request context. It returns `{:ok, overrides}`, `:default`, or
  `{:error, reason}`. `overrides` may contain only:

    * `"title"`: a non-empty UTF-8 string of at most 1,024 bytes;
    * `"description"`: a non-blank UTF-8 string of at most 4,096 bytes;
    * `"icons"`: a complete icon list (see `AttestoMCP.Server.API`);
    * `"_meta"`: application keys merged over the registered `_meta`. Keys
      must follow the MCP `_meta` key grammar and must not use a reserved MCP
      prefix, `progressToken`, or trace-context names.

  Atom keys are accepted for these four fields. Any other field, including
  `name`, `inputSchema`, `outputSchema`, `annotations`, `execution`, a handler,
  scopes, or an authorization callback, fails the list request with
  `"tool_presentation_failure"`. No partial catalog is returned.

  Scope requirements, `authorize` callbacks, and HTTP definition policies
  decide availability first; hidden tools are never passed to the callback.
  Presentation never changes registered definitions, and `tools/call` repeats
  every eligibility check. Customized descriptors are part of the pagination
  fingerprint, so a cursor stops working when the presentation it was issued
  for changes.

  Both callbacks run in the request worker under the request deadline. Their
  output is treated as private: responses that include it use
  `cacheScope: "private"` and `ttlMs: 0` unless a cache policy explicitly
  supplies a TTL (see `AttestoMCP.Server.CachePolicy`). Guidance is not an
  authorization mechanism.
  """

  alias AttestoMCP.Server.{Error, HostCallback, Icons, RequestMeta, Schema, Telemetry}

  @max_instructions_bytes 65_536
  @max_title_bytes 1_024
  @max_description_bytes 4_096
  @fields %{
    "title" => "title",
    "description" => "description",
    "icons" => "icons",
    "_meta" => "_meta"
  }

  @doc false
  @spec validate_options!(keyword()) :: :ok
  def validate_options!(opts) do
    Enum.each([instructions_provider: 1, tool_presentation: 2], fn {key, arity} ->
      case Keyword.get(opts, key) do
        nil ->
          :ok

        callback ->
          unless HostCallback.valid?(callback, arity),
            do: raise(ArgumentError, "#{key} must be a supported #{arity}-argument callback")
      end
    end)
  end

  @doc false
  @spec dynamic_instructions?(keyword()) :: boolean()
  def dynamic_instructions?(opts), do: not is_nil(opts[:instructions_provider])

  @doc false
  @spec dynamic_tools?(keyword()) :: boolean()
  def dynamic_tools?(opts), do: not is_nil(opts[:tool_presentation])

  @doc false
  @spec instructions(keyword(), map()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def instructions(opts, context) do
    case opts[:instructions_provider] do
      nil ->
        {:ok, opts[:instructions]}

      provider ->
        try do
          case HostCallback.invoke(provider, [context]) do
            {:ok, instructions} when is_binary(instructions) ->
              if valid_text?(instructions, @max_instructions_bytes),
                do: {:ok, instructions},
                else: instructions_failure(context, :error, :invalid_instructions, [])

            :omit ->
              {:ok, nil}

            {:error, reason} ->
              instructions_failure(context, :error, {:provider_error, reason}, [])

            other ->
              instructions_failure(context, :error, {:invalid_return, other}, [])
          end
        catch
          kind, reason -> instructions_failure(context, kind, reason, __STACKTRACE__)
        end
    end
  end

  @doc false
  @spec tools([map()], keyword(), map()) :: {:ok, [map()]} | {:error, Error.t()}
  def tools(descriptors, opts, context) do
    case opts[:tool_presentation] do
      nil ->
        {:ok, descriptors}

      callback ->
        Enum.reduce_while(descriptors, {:ok, []}, fn descriptor, {:ok, acc} ->
          case present_tool(callback, descriptor, opts, context) do
            {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
            {:error, _error} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, descriptors} -> {:ok, Enum.reverse(descriptors)}
          error -> error
        end
    end
  end

  defp present_tool(callback, descriptor, opts, context) do
    case HostCallback.invoke(callback, [descriptor, context]) do
      :default ->
        {:ok, descriptor}

      {:ok, overrides} when is_map(overrides) ->
        case apply_overrides(descriptor, overrides, opts) do
          {:ok, descriptor} -> {:ok, descriptor}
          {:error, reason} -> presentation_failure(context, :error, reason, [])
        end

      {:error, reason} ->
        presentation_failure(context, :error, {:callback_error, reason}, [])

      other ->
        presentation_failure(context, :error, {:invalid_return, other}, [])
    end
  catch
    kind, reason -> presentation_failure(context, kind, reason, __STACKTRACE__)
  end

  defp apply_overrides(descriptor, overrides, opts) do
    with {:ok, overrides} <- canonical_overrides(overrides) do
      Enum.reduce_while(overrides, {:ok, descriptor}, fn {field, value}, {:ok, acc} ->
        case apply_field(field, value, acc, opts) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp canonical_overrides(overrides) do
    Enum.reduce_while(overrides, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      field = if is_atom(key) or is_binary(key), do: Map.get(@fields, to_string(key))

      cond do
        is_nil(field) -> {:halt, {:error, :unsupported_field}}
        Map.has_key?(acc, field) -> {:halt, {:error, :conflicting_field}}
        true -> {:cont, {:ok, Map.put(acc, field, value)}}
      end
    end)
  end

  defp apply_field("title", value, descriptor, _opts) do
    if valid_text?(value, @max_title_bytes),
      do: {:ok, Map.put(descriptor, "title", value)},
      else: {:error, :invalid_title}
  end

  defp apply_field("description", value, descriptor, _opts) do
    if valid_text?(value, @max_description_bytes) and String.trim(value) != "",
      do: {:ok, Map.put(descriptor, "description", value)},
      else: {:error, :invalid_description}
  end

  defp apply_field("icons", value, descriptor, _opts) do
    case Icons.normalize(value) do
      {:ok, icons} -> {:ok, Map.put(descriptor, "icons", icons)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_field("_meta", value, descriptor, opts) when is_map(value) do
    budget = [max_bytes: opts[:max_json_bytes] || Schema.default_instance_bytes()]

    valid? =
      Enum.all?(value, fn {key, _value} ->
        RequestMeta.valid_key?(key) and not RequestMeta.reserved_key?(key)
      end) and Schema.json_value(value, budget) == :ok

    if valid? do
      current = Map.get(descriptor, "_meta") || %{}
      {:ok, Map.put(descriptor, "_meta", Map.merge(current, value))}
    else
      {:error, :invalid_meta}
    end
  end

  defp apply_field("_meta", _value, _descriptor, _opts), do: {:error, :invalid_meta}

  defp valid_text?(value, max_bytes) when is_binary(value),
    do: byte_size(value) in 1..max_bytes and String.valid?(value)

  defp valid_text?(_value, _max_bytes), do: false

  defp instructions_failure(context, kind, reason, stacktrace) do
    report(context, :instructions_provider, kind, reason, stacktrace)
    {:error, Error.internal(%{"reason" => "instructions_provider_failure"})}
  end

  defp presentation_failure(context, kind, reason, stacktrace) do
    report(context, :tool_presentation, kind, reason, stacktrace)
    {:error, Error.internal(%{"reason" => "tool_presentation_failure"})}
  end

  defp report(context, source, kind, reason, stacktrace) do
    Telemetry.report_exception(
      Map.get(context, :exception_reporter),
      source,
      kind,
      reason,
      stacktrace,
      %{
        method: Telemetry.protocol_method(Map.get(context, :method, "handler")),
        transport: Map.get(context, :transport, :core),
        telemetry_metadata: Map.get(context, :telemetry_metadata)
      }
    )
  end
end
