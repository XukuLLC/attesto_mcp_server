defmodule AttestoMCP.Server.Sampling do
  @moduledoc false

  alias AttestoMCP.Server.{Output, Protocol, Schema}

  @modern Protocol.modern()
  @legacy Protocol.legacy()
  @oldest "2025-06-18"
  @roles ~w(user assistant)

  def tool_parameters?(params) when is_map(params),
    do: Map.has_key?(params, "tools") or Map.has_key?(params, "toolChoice")

  def tool_parameters?(_params), do: false

  def tools_available?(params, sampling),
    do: not tool_parameters?(params) or is_map(sampling["tools"])

  def valid_request?(params, revision, opts) when revision in [@modern, @legacy, @oldest] do
    case params do
      %{"messages" => messages, "maxTokens" => max_tokens} ->
        integer?(max_tokens) and is_list(messages) and
          optional_fields?(params,
            systemPrompt: &is_binary/1,
            includeContext: &(&1 in ~w(none thisServer allServers)),
            temperature: &is_number/1,
            stopSequences: &strings?/1,
            metadata: &is_map/1,
            modelPreferences: &model_preferences?/1,
            _meta: &request_meta?(&1, revision)
          ) and tool_options?(params, revision) and valid_task?(params, revision) and
          valid_messages?(messages, revision, opts, %{})

      _ ->
        false
    end
  end

  def valid_request?(_params, _revision, _opts), do: false

  def valid_result?(%{"model" => model} = result, revision, opts)
      when is_binary(model) and revision in [@modern, @legacy, @oldest] do
    Schema.json_value(result, opts) == :ok and
      optional_fields?(result, stopReason: &is_binary/1) and
      case message_blocks(result, revision, opts) do
        {:ok, "assistant", blocks} ->
          unique_ids?(tool_ids(blocks, "tool_use", "id"))

        {:ok, "user", blocks} ->
          tool_results_only_or_absent?(blocks)

        :error ->
          false
      end
  end

  def valid_result?(_result, _revision, _opts), do: false

  defp valid_messages?([], _revision, _opts, _seen), do: true

  defp valid_messages?([message | rest], revision, opts, seen) do
    case message_blocks(message, revision, opts) do
      {:ok, "assistant", blocks} ->
        case tool_ids(blocks, "tool_use", "id") do
          [] -> valid_messages?(rest, revision, opts, seen)
          ids -> match_tool_results?(rest, ids, revision, opts, seen)
        end

      {:ok, "user", blocks} ->
        Enum.all?(blocks, &(&1["type"] != "tool_result")) and
          valid_messages?(rest, revision, opts, seen)

      :error ->
        false
    end
  end

  # Sampling's Tool Use and Result Balance rule requires an adjacent answer
  # for every tool use, including parallel calls whose results arrive in any order.
  defp match_tool_results?([answer | rest], ids, revision, opts, seen) do
    with {:ok, "user", blocks} <- message_blocks(answer, revision, opts),
         calls = Map.from_keys(ids, true),
         true <- map_size(calls) == length(ids) and Enum.all?(ids, &(not Map.has_key?(seen, &1))),
         answers = tool_ids(blocks, "tool_result", "toolUseId"),
         true <- length(answers) == length(blocks) and length(answers) == length(ids),
         true <- Map.from_keys(answers, true) == calls do
      valid_messages?(rest, revision, opts, Map.merge(seen, calls))
    else
      _ -> false
    end
  end

  defp match_tool_results?([], _ids, _revision, _opts, _seen), do: false

  defp tool_ids(blocks, type, field),
    do: for(%{"type" => ^type} = block <- blocks, do: block[field])

  defp unique_ids?(ids), do: MapSet.size(MapSet.new(ids)) == length(ids)

  defp tool_results_only_or_absent?(blocks) do
    count = Enum.count(blocks, &(&1["type"] == "tool_result"))
    count == 0 or count == length(blocks)
  end

  defp message_blocks(%{"role" => role, "content" => content} = message, revision, opts)
       when role in @roles do
    blocks = if is_map(content), do: [content], else: content

    if (revision != @oldest or is_map(content)) and
         optional_fields?(message, _meta: &is_map/1) and
         list_of?(blocks, &sampling_block?(&1, role, revision, opts)),
       do: {:ok, role, blocks},
       else: :error
  end

  defp message_blocks(_message, _revision, _opts), do: :error

  defp sampling_block?(%{"type" => type} = block, _role, _revision, opts)
       when type in ~w(text image audio),
       do: content_block?(block, opts)

  defp sampling_block?(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = block,
         "assistant",
         revision,
         _opts
       )
       when revision != @oldest and is_binary(id) and is_binary(name) and is_map(input),
       do: optional_fields?(block, _meta: &is_map/1)

  defp sampling_block?(
         %{"type" => "tool_result", "toolUseId" => id, "content" => content} = block,
         "user",
         revision,
         opts
       )
       when revision != @oldest and is_binary(id) do
    list_of?(content, &content_block?(&1, opts)) and
      optional_fields?(block, isError: &is_boolean/1, _meta: &is_map/1) and
      (revision == @modern or optional_fields?(block, structuredContent: &is_map/1))
  end

  defp sampling_block?(_block, _role, _revision, _opts), do: false

  defp content_block?(block, opts) when is_map(block) do
    optional_fields?(block, annotations: &annotations?/1) and
      match?({:ok, _}, Output.normalize_content_item(block, opts))
  end

  defp content_block?(_block, _opts), do: false

  defp annotations?(annotations) when is_map(annotations),
    do:
      optional_fields?(annotations,
        audience: &list_of?(&1, fn role -> role in @roles end),
        priority: &priority?/1,
        lastModified: &is_binary/1
      )

  defp annotations?(_annotations), do: false

  defp tool_options?(params, @oldest), do: not tool_parameters?(params)

  defp tool_options?(params, revision),
    do:
      optional_fields?(params,
        tools: &list_of?(&1, fn tool -> tool?(tool, revision) end),
        toolChoice: &tool_choice?/1
      )

  defp tool_choice?(choice) when is_map(choice),
    do: optional_fields?(choice, mode: &(&1 in ~w(auto required none)))

  defp tool_choice?(_choice), do: false

  defp tool?(%{"name" => name, "inputSchema" => %{"type" => "object"} = input} = tool, revision)
       when is_binary(name) do
    object_schema?(input, revision) and
      optional_fields?(tool,
        title: &is_binary/1,
        description: &is_binary/1,
        _meta: &is_map/1,
        icons: &icons?/1,
        annotations: &tool_annotations?/1,
        outputSchema: &output_schema?(&1, revision)
      ) and (revision != @legacy or optional_fields?(tool, execution: &execution?/1))
  end

  defp tool?(_tool, _revision), do: false

  defp object_schema?(schema, @modern), do: optional_fields?(schema, "$schema": &is_binary/1)

  defp object_schema?(schema, @legacy),
    do:
      optional_fields?(schema,
        "$schema": &is_binary/1,
        properties: &object_properties?/1,
        required: &strings?/1
      )

  defp object_properties?(properties),
    do: is_map(properties) and Enum.all?(properties, fn {_key, schema} -> is_map(schema) end)

  defp output_schema?(schema, @modern) when is_map(schema), do: object_schema?(schema, @modern)

  defp output_schema?(%{"type" => "object"} = schema, @legacy),
    do: object_schema?(schema, @legacy)

  defp output_schema?(_schema, _revision), do: false

  defp tool_annotations?(annotations) when is_map(annotations),
    do:
      optional_fields?(annotations,
        title: &is_binary/1,
        readOnlyHint: &is_boolean/1,
        destructiveHint: &is_boolean/1,
        idempotentHint: &is_boolean/1,
        openWorldHint: &is_boolean/1
      )

  defp tool_annotations?(_annotations), do: false

  defp icons?(icons), do: list_of?(icons, &icon?/1)

  defp icon?(%{"src" => src} = icon) when is_binary(src),
    do:
      match?({:ok, %URI{scheme: scheme}} when is_binary(scheme), URI.new(src)) and
        optional_fields?(icon,
          mimeType: &is_binary/1,
          sizes: &strings?/1,
          theme: &(&1 in ~w(light dark))
        )

  defp icon?(_icon), do: false

  defp execution?(execution) when is_map(execution),
    do: optional_fields?(execution, taskSupport: &(&1 in ~w(forbidden optional required)))

  defp execution?(_execution), do: false

  defp valid_task?(params, @legacy),
    do: optional_fields?(params, task: &task?/1)

  defp valid_task?(_params, _revision), do: true

  defp task?(task), do: is_map(task) and optional_fields?(task, ttl: &integer?/1)

  defp request_meta?(meta, @modern), do: is_map(meta)

  defp request_meta?(meta, _revision),
    do: is_map(meta) and optional_fields?(meta, progressToken: &(is_binary(&1) or integer?(&1)))

  defp model_preferences?(preferences) when is_map(preferences),
    do:
      optional_fields?(preferences,
        hints: &model_hints?/1,
        costPriority: &priority?/1,
        speedPriority: &priority?/1,
        intelligencePriority: &priority?/1
      )

  defp model_preferences?(_preferences), do: false

  defp model_hints?(hints) do
    list_of?(hints, fn hint -> is_map(hint) and optional_fields?(hint, name: &is_binary/1) end)
  end

  defp priority?(value), do: is_number(value) and value >= 0 and value <= 1
  defp integer?(value), do: is_number(value) and trunc(value) == value
  defp list_of?(value, valid?), do: is_list(value) and Enum.all?(value, valid?)
  defp strings?(value), do: list_of?(value, &is_binary/1)

  defp optional_fields?(object, fields) do
    Enum.all?(fields, fn {field, valid?} ->
      case Map.fetch(object, Atom.to_string(field)) do
        :error -> true
        {:ok, value} -> valid?.(value)
      end
    end)
  end
end
