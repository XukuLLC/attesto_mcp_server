alias AttestoMCP.Server.Schema

[suite] = System.argv()
manifest = Jason.decode!(File.read!("test/support/json_schema_suite_exclusions.json"))
exclusions = Map.new(manifest["exclusions"], &{{&1["file"], &1["description"]}, &1})
files = Path.wildcard(Path.join(suite, "tests/draft2020-12/*.json"))
if length(files) != 46, do: raise("expected all 46 required draft2020-12 corpus files")

{passed, excluded, seen} =
  Enum.reduce(files, {0, 0, MapSet.new()}, fn file, totals ->
    groups = Jason.decode!(File.read!(file))

    Enum.reduce(groups, totals, fn group, {passed, excluded, seen} ->
      key = {Path.basename(file), group["description"]}
      schema = group["schema"]

      case Map.fetch(exclusions, key) do
        {:ok, exclusion} ->
          # Network references and custom network dialects are deliberately
          # unavailable. Each exclusion must still fail for its stated reason.
          expected = {:error, String.to_existing_atom(exclusion["reason"])}
          actual = Schema.validate_schema(schema, formats: false)

          if actual != expected,
            do: raise("changed exclusion #{inspect(key)}: #{inspect(actual)}")

          count = length(group["tests"])

          if count != exclusion["tests"],
            do: raise("changed excluded corpus group #{inspect(key)}")

          {passed, excluded + count, MapSet.put(seen, key)}

        :error ->
          if Schema.validate_schema(schema, formats: false) != :ok,
            do: raise("rejected required schema #{inspect(key)}")

          Enum.each(group["tests"], fn test ->
            result = Schema.validate(test["data"], schema, formats: false)

            if result == :ok != test["valid"],
              do:
                raise(
                  "corpus mismatch #{inspect(key)} / #{test["description"]}: #{inspect(result)}"
                )
          end)

          {passed + length(group["tests"]), excluded, seen}
      end
    end)
  end)

if MapSet.size(seen) != map_size(exclusions), do: raise("stale corpus exclusions")
if {passed, excluded} != {1252, 49}, do: raise("unexpected corpus coverage")

IO.puts(
  "JSON Schema #{manifest["upstream_commit"]}: #{passed} passed; #{excluded} explicitly excluded"
)
