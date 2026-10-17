defmodule AttestoMCP.Server.UriTemplate do
  @moduledoc false

  alias AttestoMCP.Server.Telemetry

  @max_template_uri_bytes 4_096
  @max_template_value_bytes 2_048
  @max_template_query_pairs 32
  @max_template_expressions 16
  @max_template_variables 32
  @max_template_expression_bytes 128
  @max_template_match_steps 65_536
  @max_template_match_work 8_388_608
  @max_template_match_candidates 1_000

  # URI-template matching is deliberately bounded and only accepts layouts that
  # the registration validator declares supported. For a supported path, a
  # delimiter inside a valid capture is resolved by the bounded matcher below;
  # query keys remain exact and decoding never relaxes path-safety checks.
  @doc false
  @spec valid?(term(), (String.t() -> :ok | {:error, term()})) :: boolean()
  def valid?(template, uri_validator)
      when is_binary(template) and is_function(uri_validator, 1) do
    with true <- String.valid?(template),
         :ok <- uri_validator.(template),
         {:ok, parts} <- template_parts(template),
         expressions <- for({:expression, expression} <- parts, do: expression),
         true <- expressions != [],
         true <- length(expressions) <= @max_template_expressions,
         true <- Enum.all?(expressions, &(byte_size(&1) <= @max_template_expression_bytes)),
         {:ok, parsed_expressions} <- parse_template_expressions(expressions),
         true <- unique_template_variables?(parsed_expressions),
         true <- supported_template_layout?(parts, expressions, parsed_expressions) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def valid?(_template, _uri_validator), do: false

  @doc false
  @spec match(term(), term(), map()) ::
          {:ok, map(), map()} | {:error, map()} | {:exhausted, map()}
  def match(template, uri, budget)
      when is_binary(template) and is_binary(uri) and is_map(budget) do
    with {:ok, budget} <- reserve_template_match_candidate(budget),
         {:ok, budget} <-
           consume_template_match_work(budget, byte_size(template) + byte_size(uri) + 1) do
      match_with_budget(template, uri, budget)
    else
      {:exhausted, budget} -> {:exhausted, budget}
    end
  rescue
    _ -> {:error, budget}
  end

  def match(_template, _uri, budget), do: {:error, budget}

  defp match_with_budget(template, uri, budget) do
    if String.valid?(template) and String.valid?(uri) and
         byte_size(uri) <= @max_template_uri_bytes do
      case template_parts(template) do
        {:ok, parts} ->
          expressions = for {:expression, expression} <- parts, do: expression

          cond do
            expressions == [] or length(expressions) > @max_template_expressions ->
              {:error, budget}

            length(expressions) > @max_template_variables ->
              {:error, budget}

            Enum.any?(expressions, &(byte_size(&1) > @max_template_expression_bytes)) ->
              {:error, budget}

            not template_literal_boundaries_match?(parts, uri) ->
              {:error, budget}

            length(expressions) == 1 ->
              with {:ok, budget} <- consume_template_match_work(budget, byte_size(uri)) do
                case match_single_template(template, uri, hd(expressions)) do
                  {:ok, params} -> {:ok, params, budget}
                  :error -> {:error, budget}
                end
              else
                {:exhausted, budget} -> {:exhausted, budget}
              end

            true ->
              with {:ok, budget} <-
                     consume_template_match_work(
                       budget,
                       multi_template_setup_work(parts, uri)
                     ) do
                match_multi_path_template(parts, uri, expressions, budget)
              else
                {:exhausted, budget} -> {:exhausted, budget}
              end
          end

        :error ->
          {:error, budget}
      end
    else
      {:error, budget}
    end
  rescue
    _ -> {:error, budget}
  end

  @doc false
  @spec new_budget() :: %{work: non_neg_integer(), candidates: non_neg_integer()}
  def new_budget do
    %{work: @max_template_match_work, candidates: @max_template_match_candidates}
  end

  defp template_literal_boundaries_match?(parts, uri)
       when is_list(parts) and is_binary(uri) do
    literals = for {:literal, literal} <- parts, do: literal
    prefix = List.first(literals) || ""
    suffix = List.last(literals) || ""

    String.starts_with?(uri, prefix) and
      (suffix == "" or String.ends_with?(uri, suffix))
  end

  defp reserve_template_match_candidate(%{candidates: candidates} = budget)
       when is_integer(candidates) and candidates > 0,
       do: {:ok, %{budget | candidates: candidates - 1}}

  defp reserve_template_match_candidate(budget), do: {:exhausted, exhaust_match_budget(budget)}

  defp consume_template_match_work(%{work: remaining} = budget, work)
       when is_integer(remaining) and is_integer(work) and work >= 0 and remaining >= work,
       do: {:ok, %{budget | work: remaining - work}}

  defp consume_template_match_work(budget, _work),
    do: {:exhausted, exhaust_match_budget(budget)}

  defp exhaust_match_budget(%{work: _work} = budget), do: %{budget | work: 0}
  defp exhaust_match_budget(budget), do: budget

  @doc false
  @spec report_budget_exhausted(term()) :: :ok
  def report_budget_exhausted(operation) do
    Telemetry.execute(
      [:uri_template, :budget_exhausted],
      %{count: 1},
      %{source: operation, outcome: :rejected}
    )
  end

  defp multi_template_setup_work(parts, uri) do
    literals = for {:literal, literal} <- parts, do: literal
    uri_bytes = byte_size(uri)
    delimiter_scan_work = uri_bytes * max(length(Enum.uniq(literals)), 1)
    terminal_window_bytes = min(uri_bytes, @max_template_value_bytes)

    terminal_source =
      binary_part(uri, uri_bytes - terminal_window_bytes, terminal_window_bytes)

    terminal_scan_work =
      if String.contains?(terminal_source, "%") or not ascii_binary?(terminal_source) do
        div(terminal_window_bytes * (terminal_window_bytes + 1), 2)
      else
        terminal_window_bytes
      end

    uri_bytes + delimiter_scan_work + terminal_scan_work
  rescue
    _ -> @max_template_match_work
  end

  defp match_single_template(template, uri, expression) do
    marker = "{" <> expression <> "}"

    case String.split(template, marker, parts: 2) do
      [prefix, suffix] ->
        with true <- String.starts_with?(uri, prefix),
             remainder <- binary_part(uri, byte_size(prefix), byte_size(uri) - byte_size(prefix)),
             true <- suffix == "" or String.ends_with?(remainder, suffix),
             value <-
               if(suffix == "", do: remainder, else: remove_template_suffix(remainder, suffix)),
             {:ok, operator, specs} <- parse_template_expression(expression) do
          if operator == ?? do
            match_query_template(prefix, value, specs)
          else
            match_path_template(value, operator, specs)
          end
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp template_parts(template) when is_binary(template) do
    matches = Regex.scan(~r/\{([^{}]+)\}/, template, return: :index)

    if matches == [] do
      :error
    else
      build_template_parts(template, matches, 0, [])
    end
  rescue
    _ -> :error
  end

  defp build_template_parts(template, [], offset, acc) do
    suffix_size = byte_size(template) - offset

    if suffix_size >= 0 do
      literal = binary_part(template, offset, suffix_size)

      if String.contains?(literal, ["{", "}"]) do
        :error
      else
        {:ok, Enum.reverse([{:literal, literal} | acc])}
      end
    else
      :error
    end
  end

  defp build_template_parts(
         template,
         [[{start, length}, {expression_start, expression_length}] | rest],
         offset,
         acc
       )
       when start >= offset and expression_start >= start and expression_length >= 1 do
    literal_length = start - offset
    literal = binary_part(template, offset, literal_length)
    expression = binary_part(template, expression_start, expression_length)

    if String.contains?(literal, ["{", "}"]) do
      :error
    else
      build_template_parts(
        template,
        rest,
        start + length,
        [{:expression, expression}, {:literal, literal} | acc]
      )
    end
  rescue
    _ -> :error
  end

  defp build_template_parts(_template, _matches, _offset, _acc), do: :error

  defp match_multi_path_template(parts, uri, expressions, budget) do
    if multi_path_layout?(parts, expressions) do
      literals = for {:literal, literal} <- parts, do: literal
      delimiter_positions = template_delimiter_positions(uri, literals)

      with {:ok, parsed_expressions} <- parse_path_template_expressions(expressions),
           ascii_uri <- ascii_binary?(uri),
           terminal_starts <-
             terminal_capture_positions(uri, List.last(parsed_expressions), List.last(literals)),
           true <- terminal_starts != MapSet.new(),
           true <- literal_at?(uri, 0, hd(literals)) do
        {result, _memo, budget, _steps} =
          match_multi_path_expressions(
            literals,
            parsed_expressions,
            uri,
            0,
            byte_size(hd(literals)),
            delimiter_positions,
            path_remaining_bounds(literals, length(parsed_expressions)),
            terminal_starts,
            ascii_uri,
            %{},
            budget,
            0
          )

        case result do
          {:ok, params, position} when position == byte_size(uri) -> {:ok, params, budget}
          :exhausted -> {:exhausted, budget}
          _ -> {:error, budget}
        end
      else
        _ -> {:error, budget}
      end
    else
      {:error, budget}
    end
  end

  defp multi_path_layout?(parts, expressions) do
    literals = for {:literal, literal} <- parts, do: literal

    length(expressions) <= @max_template_expressions and
      length(expressions) <= @max_template_variables and
      length(literals) == length(expressions) + 1 and
      Enum.all?(expressions, &single_path_expression?/1) and
      no_adjacent_path_expressions?(literals)
  end

  defp parse_template_expressions(expressions) when is_list(expressions) do
    parsed = Enum.map(expressions, &parse_template_expression/1)

    if Enum.all?(parsed, &match?({:ok, _, _}, &1)), do: {:ok, parsed}, else: :error
  end

  defp unique_template_variables?(parsed_expressions) do
    names =
      for {:ok, _operator, specs} <- parsed_expressions,
          spec <- specs,
          do: spec.name

    length(names) <= @max_template_variables and length(names) == length(Enum.uniq(names))
  end

  defp supported_template_layout?(
         [{:literal, _prefix}, {:expression, _expression_part}, {:literal, suffix}],
         [_expression_value],
         [{:ok, operator, specs}]
       ) do
    operator in [nil, ?+, ??] and (operator != ?? or suffix == "") and specs != []
  end

  defp supported_template_layout?(parts, expressions, _parsed_expressions)
       when length(expressions) > 1,
       do: multi_path_layout?(parts, expressions)

  defp supported_template_layout?(_parts, _expressions, _parsed_expressions), do: false

  defp single_path_expression?(expression) do
    case parse_template_expression(expression) do
      {:ok, operator, [_spec]} when operator in [nil, ?+] -> true
      _ -> false
    end
  end

  defp no_adjacent_path_expressions?(literals) do
    last_index = length(literals) - 1

    literals
    |> Enum.with_index()
    |> Enum.all?(fn
      {_literal, 0} -> true
      {_literal, index} when index == last_index -> true
      {literal, _index} -> literal != ""
    end)
  end

  # A delimiter can occur inside an expanded value. We therefore try every
  # bounded delimiter position from the URI suffix inward and memoize every
  # {expression, position} suffix decision. Suffix-first ordering also avoids
  # mistaking a delimiter encoded inside one grapheme for the separator before
  # the next expression. This is a finite dynamic-programming matcher: URI
  # input is capped above, each state is evaluated once, and remaining-length
  # and terminal-capture indexes discard impossible splits before decoding
  # them. The candidate budget is a final fail-closed guard.
  defp parse_path_template_expressions(expressions) do
    parsed =
      Enum.map(expressions, fn expression ->
        case parse_template_expression(expression) do
          {:ok, operator, [spec]} when operator in [nil, ?+] -> {:ok, {operator, spec}}
          _ -> :error
        end
      end)

    if Enum.all?(parsed, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(parsed, fn {:ok, value} -> value end)},
      else: :error
  end

  defp path_remaining_bounds(literals, expression_count)
       when is_list(literals) and is_integer(expression_count) and expression_count > 0 do
    Enum.map(0..(expression_count - 1), fn expression_index ->
      future_expression_count = expression_count - expression_index - 1

      future_literal_bytes =
        literals
        |> Enum.drop(expression_index + 2)
        |> Enum.reduce(0, fn literal, total -> total + byte_size(literal) end)

      {
        future_expression_count + future_literal_bytes,
        future_expression_count * @max_template_value_bytes + future_literal_bytes
      }
    end)
  end

  defp path_remaining_bounds(_literals, _expression_count), do: []

  defp terminal_capture_positions(uri, {operator, spec}, delimiter)
       when is_binary(uri) and is_binary(delimiter) and operator in [nil, ?+] do
    terminal_position = byte_size(uri) - byte_size(delimiter)

    if terminal_position >= 1 and literal_at?(uri, terminal_position, delimiter) do
      lower_position = max(terminal_position - @max_template_value_bytes, 0)

      if String.contains?(
           binary_part(uri, lower_position, terminal_position - lower_position),
           "%"
         ) do
        Enum.reduce(lower_position..(terminal_position - 1), MapSet.new(), fn position,
                                                                              positions ->
          value = binary_part(uri, position, terminal_position - position)

          case decode_path_template_value(value, operator, spec) do
            {:ok, _decoded} -> MapSet.put(positions, position)
            :error -> positions
          end
        end)
      else
        plain_terminal_capture_positions(
          uri,
          lower_position,
          terminal_position,
          operator,
          spec
        )
      end
    else
      MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  defp terminal_capture_positions(_uri, _expression, _delimiter), do: MapSet.new()

  defp plain_path_capture_valid?(value, operator, spec) when is_binary(value) do
    value != "" and byte_size(value) <= @max_template_value_bytes and
      (operator == ?+ or not String.contains?(value, ["/", "?", "#"])) and
      not unsafe_template_value?(value) and prefix_length_ok?(value, spec.prefix)
  end

  defp plain_terminal_capture_positions(uri, lower_position, terminal_position, operator, spec) do
    source = binary_part(uri, lower_position, terminal_position - lower_position)
    unsafe_offset = last_plain_unsafe_offset(source, operator)
    lower_position = max(lower_position, lower_position + unsafe_offset + 1)

    if lower_position >= terminal_position do
      MapSet.new()
    else
      case spec.prefix do
        nil ->
          MapSet.new(lower_position..(terminal_position - 1))

        prefix when is_integer(prefix) ->
          if ascii_binary?(source) do
            lower_position = max(lower_position, terminal_position - prefix)

            if lower_position < terminal_position,
              do: MapSet.new(lower_position..(terminal_position - 1)),
              else: MapSet.new()
          else
            Enum.reduce(lower_position..(terminal_position - 1), MapSet.new(), fn position,
                                                                                  positions ->
              value = binary_part(uri, position, terminal_position - position)

              if plain_path_capture_valid?(value, operator, spec),
                do: MapSet.put(positions, position),
                else: positions
            end)
          end
      end
    end
  end

  defp ascii_binary?(value) when is_binary(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 < 128))
  end

  defp last_plain_unsafe_offset(source, operator) when is_binary(source) do
    last_offset = byte_size(source) - 1

    if last_offset >= 0 do
      Enum.reduce(0..last_offset, -1, fn offset, latest ->
        byte = :binary.at(source, offset)
        next_byte = if offset < last_offset, do: :binary.at(source, offset + 1), else: nil

        unsafe_separator = operator == nil and byte in [?/, ??, ?#]
        unsafe_byte = byte in [?\\, 0, ?\r, ?\n]
        unsafe_dot_pair = byte == ?. and next_byte == ?.

        if unsafe_separator or unsafe_byte or unsafe_dot_pair, do: offset, else: latest
      end)
    else
      -1
    end
  end

  defp match_multi_path_expressions(
         literals,
         expressions,
         uri,
         expression_index,
         position,
         delimiter_positions,
         remaining_bounds,
         terminal_starts,
         ascii_uri,
         memo,
         budget,
         steps
       ) do
    key = {expression_index, position}

    case Map.fetch(memo, key) do
      {:ok, result} ->
        {result, memo, budget, steps}

      :error ->
        {result, memo, budget, steps} =
          if expression_index == length(expressions) do
            if position == byte_size(uri) do
              {{:ok, %{}, position}, memo, budget, steps}
            else
              {:error, memo, budget, steps}
            end
          else
            {operator, spec} = Enum.at(expressions, expression_index)
            delimiter = Enum.at(literals, expression_index + 1)

            try_multi_path_candidates(
              candidate_positions_from(
                delimiter_positions,
                uri,
                delimiter,
                position,
                expression_index,
                length(expressions),
                spec,
                remaining_bounds,
                terminal_starts,
                ascii_uri
              ),
              delimiter,
              operator,
              spec,
              literals,
              expressions,
              uri,
              expression_index,
              position,
              delimiter_positions,
              remaining_bounds,
              terminal_starts,
              ascii_uri,
              memo,
              budget,
              steps
            )
          end

        {result, Map.put(memo, key, result), budget, steps}
    end
  rescue
    _ -> {:error, memo, budget, steps}
  end

  defp try_multi_path_candidates(
         [],
         _delimiter,
         _operator,
         _spec,
         _literals,
         _expressions,
         _uri,
         _expression_index,
         _position,
         _delimiter_positions,
         _remaining_bounds,
         _terminal_starts,
         _ascii_uri,
         memo,
         budget,
         steps
       ),
       do: {:error, memo, budget, steps}

  defp try_multi_path_candidates(
         [offset | rest],
         delimiter,
         operator,
         spec,
         literals,
         expressions,
         uri,
         expression_index,
         position,
         delimiter_positions,
         remaining_bounds,
         terminal_starts,
         ascii_uri,
         memo,
         budget,
         steps
       ) do
    if steps >= @max_template_match_steps do
      {:exhausted, memo, exhaust_match_budget(budget), steps}
    else
      case consume_template_match_work(budget, 1) do
        {:ok, budget} ->
          steps = steps + 1
          value = binary_part(uri, position, offset)

          case decode_path_template_value(value, operator, spec) do
            {:ok, decoded} ->
              next_position = position + offset + byte_size(delimiter)

              {result, memo, budget, steps} =
                match_multi_path_expressions(
                  literals,
                  expressions,
                  uri,
                  expression_index + 1,
                  next_position,
                  delimiter_positions,
                  remaining_bounds,
                  terminal_starts,
                  ascii_uri,
                  memo,
                  budget,
                  steps
                )

              case result do
                {:ok, params, final_position} ->
                  {{:ok, Map.put(params, spec.name, decoded), final_position}, memo, budget,
                   steps}

                :exhausted ->
                  {:exhausted, memo, budget, steps}

                :error ->
                  try_multi_path_candidates(
                    rest,
                    delimiter,
                    operator,
                    spec,
                    literals,
                    expressions,
                    uri,
                    expression_index,
                    position,
                    delimiter_positions,
                    remaining_bounds,
                    terminal_starts,
                    ascii_uri,
                    memo,
                    budget,
                    steps
                  )
              end

            :error ->
              try_multi_path_candidates(
                rest,
                delimiter,
                operator,
                spec,
                literals,
                expressions,
                uri,
                expression_index,
                position,
                delimiter_positions,
                remaining_bounds,
                terminal_starts,
                ascii_uri,
                memo,
                budget,
                steps
              )
          end

        {:exhausted, budget} ->
          {:exhausted, memo, budget, steps}
      end
    end
  rescue
    _ -> {:error, memo, budget, steps}
  end

  defp template_delimiter_positions(uri, literals) when is_binary(uri) and is_list(literals) do
    literals
    |> Enum.uniq()
    |> Map.new(fn
      "" -> {"", [byte_size(uri)]}
      delimiter -> {delimiter, delimiter_positions(uri, delimiter)}
    end)
  end

  defp template_delimiter_positions(_uri, _literals), do: %{}

  defp delimiter_positions(uri, delimiter)
       when is_binary(uri) and is_binary(delimiter) and delimiter != "" do
    max_position = byte_size(uri) - byte_size(delimiter)

    if max_position >= 0 do
      for position <- 0..max_position, literal_at?(uri, position, delimiter), do: position
    else
      []
    end
  rescue
    _ -> []
  end

  defp delimiter_positions(_uri, _delimiter), do: []

  defp candidate_positions_from(
         delimiter_positions,
         uri,
         delimiter,
         position,
         expression_index,
         expression_count,
         spec,
         remaining_bounds,
         terminal_starts,
         ascii_uri
       )
       when is_map(delimiter_positions) and is_binary(uri) and is_integer(position) and
              position >= 0 and is_integer(expression_index) and expression_index >= 0 and
              is_integer(expression_count) and expression_count > expression_index and
              is_list(remaining_bounds) and is_struct(terminal_starts, MapSet) and
              is_boolean(ascii_uri) do
    {min_remaining, max_remaining} = Enum.at(remaining_bounds, expression_index)
    delimiter_bytes = byte_size(delimiter)
    uri_bytes = byte_size(uri)

    max_possible_capture_bytes =
      min(
        @max_template_value_bytes,
        max(uri_bytes - delimiter_bytes - min_remaining - position, 0)
      )

    percent_in_capture_window? =
      max_possible_capture_bytes > 0 and
        :binary.match(uri, "%", scope: {position, max_possible_capture_bytes}) != :nomatch

    ascii_capture_window? =
      ascii_uri or
        ascii_binary?(binary_part(uri, position, max_possible_capture_bytes))

    raw_prefix_pruning_safe? = ascii_capture_window? and not percent_in_capture_window?

    max_capture_bytes =
      case {raw_prefix_pruning_safe?, spec.prefix} do
        # Prefixes count decoded graphemes, so a raw-byte bound is sound only
        # for unescaped ASCII in this capture's possible byte window. Percent
        # escapes can form arbitrarily many combining codepoints in one
        # grapheme cluster.
        {true, prefix} when is_integer(prefix) ->
          min(@max_template_value_bytes, prefix)

        _ ->
          @max_template_value_bytes
      end

    lower_position = max(position + 1, uri_bytes - delimiter_bytes - max_remaining)

    upper_position =
      min(
        position + max_capture_bytes,
        uri_bytes - delimiter_bytes - min_remaining
      )

    positions =
      delimiter_positions
      |> Map.get(delimiter, [])
      |> Enum.drop_while(&(&1 < lower_position))
      |> Enum.take_while(&(&1 <= upper_position))

    positions =
      if expression_index == expression_count - 2 do
        Enum.filter(positions, fn candidate ->
          MapSet.member?(terminal_starts, candidate + delimiter_bytes)
        end)
      else
        positions
      end

    positions
    |> Enum.reverse()
    |> Enum.map(&(&1 - position))
  end

  defp candidate_positions_from(
         _delimiter_positions,
         _uri,
         _delimiter,
         _position,
         _expression_index,
         _expression_count,
         _spec,
         _remaining_bounds,
         _terminal_starts,
         _ascii_uri
       ),
       do: []

  defp literal_at?(uri, position, literal)
       when is_binary(uri) and is_integer(position) and position >= 0 and is_binary(literal) do
    position + byte_size(literal) <= byte_size(uri) and
      binary_part(uri, position, byte_size(literal)) == literal
  rescue
    _ -> false
  end

  defp decode_path_template_value(value, operator, spec) do
    if value == "" or byte_size(value) > @max_template_value_bytes or
         (operator == nil and String.contains?(value, ["/", "?", "#"])) do
      :error
    else
      with {:ok, decoded} <- strict_template_decode(value, :path),
           false <- unsafe_template_value?(decoded),
           false <- operator == nil and String.contains?(decoded, ["/", "?", "#"]),
           true <- prefix_length_ok?(decoded, spec.prefix) do
        {:ok, decoded}
      else
        _ -> :error
      end
    end
  end

  defp remove_template_suffix(value, suffix) do
    binary_part(value, 0, byte_size(value) - byte_size(suffix))
  end

  defp parse_template_expression(expression) when is_binary(expression) do
    {operator, variables} =
      case expression do
        <<operator, rest::binary>> when operator in [?+, ??] -> {operator, rest}
        _ -> {nil, expression}
      end

    specs = String.split(variables, ",", trim: false)

    parsed_specs = Enum.map(specs, &parse_template_varspec/1)

    if variables != "" and Enum.all?(parsed_specs, &is_map/1) do
      {:ok, operator, parsed_specs}
    else
      :error
    end
  end

  defp parse_template_varspec(spec) when is_binary(spec) do
    {base, explode} =
      if String.ends_with?(spec, "*"),
        do: {String.trim_trailing(spec, "*"), true},
        else: {spec, false}

    case Regex.run(~r/^([A-Za-z][A-Za-z0-9_.]*)(?::([1-9][0-9]{0,3}))?$/, base,
           capture: :all_but_first
         ) do
      [name] -> %{name: name, prefix: nil, explode: explode}
      [name, prefix] -> %{name: name, prefix: String.to_integer(prefix), explode: explode}
      _ -> :error
    end
  end

  defp parse_template_varspec(_), do: :error

  defp match_path_template(value, operator, [spec]) when operator in [nil, ?+] do
    if value == "" or byte_size(value) > @max_template_value_bytes or
         (operator == nil and String.contains?(value, ["/", "?", "#"])) do
      :error
    else
      with {:ok, decoded} <- strict_template_decode(value, :path),
           false <- unsafe_template_value?(decoded),
           false <- operator == nil and String.contains?(decoded, ["/", "?", "#"]),
           true <- prefix_length_ok?(decoded, spec.prefix) do
        {:ok, %{spec.name => decoded}}
      else
        _ -> :error
      end
    end
  end

  defp match_path_template(_value, _operator, _specs), do: :error

  defp prefix_length_ok?(_value, nil), do: true
  defp prefix_length_ok?(value, prefix), do: String.length(value) <= prefix

  defp match_query_template(_prefix, query, specs) do
    with true <- String.starts_with?(query, "?") or String.starts_with?(query, "&"),
         raw_query <- binary_part(query, 1, byte_size(query) - 1),
         {:ok, pairs} <- parse_template_query(raw_query),
         {:ok, parsed} <- decode_query_pairs(pairs),
         {:ok, values} <- query_values(parsed, specs) do
      {:ok, values}
    else
      _ -> :error
    end
  end

  defp parse_template_query(raw_query)
       when is_binary(raw_query) and byte_size(raw_query) <= @max_template_uri_bytes do
    if raw_query == "" do
      :error
    else
      pairs = String.split(raw_query, "&", trim: false)

      if length(pairs) > @max_template_query_pairs or Enum.any?(pairs, &(&1 == "")) do
        :error
      else
        Enum.reduce_while(pairs, {:ok, []}, fn pair, {:ok, acc} ->
          case String.split(pair, "=", parts: 2) do
            [key, value] when key != "" -> {:cont, {:ok, [{key, value} | acc]}}
            _ -> {:halt, :error}
          end
        end)
        |> case do
          {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
          :error -> :error
        end
      end
    end
  end

  defp parse_template_query(_), do: :error

  defp decode_query_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- strict_template_decode(key, :query),
           {:ok, value} <- strict_template_decode(value, :query),
           false <- unsafe_template_value?(key) or unsafe_template_value?(value) do
        {:cont, {:ok, [{key, value} | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      :error -> :error
    end
  end

  defp query_values(pairs, specs) do
    if Enum.any?(specs, & &1.explode) do
      query_exploded_values(pairs, specs)
    else
      allowed = MapSet.new(specs, & &1.name)

      if Enum.all?(pairs, fn {key, _value} -> MapSet.member?(allowed, key) end) and
           unique_query_keys?(pairs) do
        {:ok, Map.new(pairs)}
      else
        :error
      end
    end
  end

  defp query_exploded_values(pairs, [%{name: name, explode: true}]) do
    cond do
      Enum.all?(pairs, fn {key, _value} -> key == name end) ->
        {:ok, %{name => Enum.map(pairs, &elem(&1, 1))}}

      Enum.any?(pairs, fn {key, _value} -> key == name end) ->
        :error

      unique_query_keys?(pairs) ->
        {:ok, %{name => Map.new(pairs)}}

      true ->
        :error
    end
  end

  defp query_exploded_values(_pairs, _specs), do: :error

  defp unique_query_keys?(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))
    length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp strict_template_decode(value, mode) when is_binary(value) do
    if byte_size(value) > @max_template_value_bytes or
         (String.contains?(value, "%") and Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value)) do
      :error
    else
      source = if mode == :query, do: String.replace(value, "+", " "), else: value

      try do
        decoded = if String.contains?(source, "%"), do: URI.decode(source), else: source

        if String.valid?(decoded) and byte_size(decoded) <= @max_template_value_bytes do
          {:ok, decoded}
        else
          :error
        end
      rescue
        _ -> :error
      end
    end
  end

  defp strict_template_decode(_value, _mode), do: :error

  defp unsafe_template_value?(value),
    do: String.contains?(value, ["..", "\\", "\u0000", "\r", "\n"])
end
