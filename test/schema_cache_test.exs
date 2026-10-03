defmodule AttestoMCP.Server.SchemaCacheTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server.Schema
  alias AttestoMCP.Server.Schema.Cache

  @cache __MODULE__.Cache

  setup context do
    opts =
      Keyword.merge(
        [name: @cache, max_entries: 2, max_bytes: 4_000, max_entry_bytes: 3_000],
        Map.get(context, :cache_opts, [])
      )

    start_supervised!({Cache, opts})
    :ok
  end

  test "retained entries are bounded and evicted in insertion order" do
    for key <- [:first, :second, :third],
        do: assert(:ok = Cache.put(key, %{type: :integer}, @cache))

    assert :miss = Cache.get(:first, @cache)
    assert {:ok, %{type: :integer}} = Cache.get(:second, @cache)
    assert {:ok, %{type: :integer}} = Cache.get(:third, @cache)
    assert %{entries: 2, bytes: bytes, max_bytes: max_bytes} = GenServer.call(@cache, :stats)
    assert bytes <= max_bytes

    assert :ok = Cache.put(:second, %{type: :string}, @cache)
    assert %{entries: 2} = GenServer.call(@cache, :stats)
    assert {:ok, %{type: :integer}} = Cache.get(:second, @cache)
  end

  @tag cache_opts: [max_entries: 64, max_bytes: 2_000, max_entry_bytes: 1_500]
  test "byte limits account for off-heap binaries and reject oversized roots without eviction" do
    root = :binary.copy("x", 900)
    assert :ok = Cache.put(:first, root, @cache)
    assert :ok = Cache.put(:second, root, @cache)
    assert :miss = Cache.get(:first, @cache)
    assert {:ok, ^root} = Cache.get(:second, @cache)

    assert :ok = Cache.put(:oversized, :binary.copy("y", 2_000), @cache)
    assert :miss = Cache.get(:oversized, @cache)
    assert {:ok, ^root} = Cache.get(:second, @cache)
    assert %{entries: 1, bytes: bytes, max_bytes: 2_000} = GenServer.call(@cache, :stats)
    assert bytes <= 2_000
  end

  test "a reserved insertion excludes other roots and a dead caller releases it" do
    parent = self()

    caller =
      spawn(fn ->
        :ok = GenServer.call(@cache, {:reserve, make_ref(), 1_000})
        send(parent, :reserved)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :reserved
    assert :ok = Cache.put(:busy, %{root: :ignored}, @cache)
    assert %{entries: 0} = GenServer.call(@cache, :stats)
    Process.exit(caller, :kill)
    assert :ok = wait_for_released_reservation()
    assert :ok = Cache.put(:after_crash, %{root: :stored}, @cache)
    assert {:ok, %{root: :stored}} = Cache.get(:after_crash, @cache)
  end

  test "a timed-out reservation cannot strand admission" do
    :ok = :sys.suspend(@cache)
    on_exit(fn -> if Process.whereis(@cache), do: :sys.resume(@cache) end)
    parent = self()

    task =
      Task.async(fn ->
        :ok = Cache.put(:timed_out, %{root: :ignored}, @cache)
        send(parent, :reservation_timed_out)

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)
    assert_receive :reservation_timed_out, 1_000
    :ok = :sys.resume(@cache)

    assert %{entries: 0} = GenServer.call(@cache, :stats)
    assert :ok = Cache.put(:after_timeout, %{root: :stored}, @cache)
    assert {:ok, %{root: :stored}} = Cache.get(:after_timeout, @cache)
    assert Process.alive?(task.pid)
    send(task.pid, :finish)
    assert :ok = Task.await(task)
  end

  @tag cache_opts: [max_bytes: 200_000, max_entry_bytes: 64_000]
  test "concurrent misses cannot queue large roots behind a stalled owner" do
    parent = self()
    root = :binary.copy("x", 40_000)

    caller =
      spawn(fn ->
        reservation = make_ref()
        :ok = GenServer.call(@cache, {:reserve, reservation, 50_000})
        send(parent, :reserved)

        receive do
          :put ->
            try do
              GenServer.call(@cache, {:put, reservation, :first, root, 50_000}, 100)
            catch
              :exit, _ -> :ok
            end

            send(parent, :put_timed_out)
        end
      end)

    assert_receive :reserved
    :ok = :sys.suspend(@cache)
    on_exit(fn -> if Process.whereis(@cache), do: :sys.resume(@cache) end)
    send(caller, :put)

    tasks = for index <- 1..16, do: Task.async(fn -> Cache.put(index, root, @cache) end)
    for task <- tasks, do: assert(:ok = Task.await(task))
    assert_receive :put_timed_out

    {:messages, messages} = Process.info(Process.whereis(@cache), :messages)

    root_messages =
      Enum.count(messages, fn
        {:"$gen_call", _, {:put, _, _, _, _}} -> true
        _ -> false
      end)

    assert root_messages == 1
    :ok = :sys.resume(@cache)
    assert %{entries: 1} = GenServer.call(@cache, :stats)
    assert {:ok, ^root} = Cache.get(:first, @cache)
    assert :ok = Cache.put(:after_stall, %{root: :stored}, @cache)
    assert {:ok, %{root: :stored}} = Cache.get(:after_stall, @cache)
  end

  test "unavailable and restarted owners fall back safely and release their tables" do
    assert :ok = Cache.put(:before_restart, %{root: :old}, @cache)
    stop_supervised!(Cache)
    assert :miss = Cache.get(:before_restart, @cache)
    assert :ok = Cache.put(:unavailable, %{root: :ignored}, @cache)

    start_supervised!({Cache, name: @cache})
    assert :miss = Cache.get(:before_restart, @cache)
    assert :ok = Cache.put(:after_restart, %{root: :new}, @cache)
    assert {:ok, %{root: :new}} = Cache.get(:after_restart, @cache)
  end

  test "fresh callers share only compiled schemas and validate every instance" do
    schema = %{"type" => "integer", "maximum" => 5, "title" => unique_title()}
    key = {schema, true, Schema.default_instance_bytes()}

    assert :ok = Task.async(fn -> Schema.validate(4, schema) end) |> Task.await()
    assert {:ok, %JSV.Root{}} = Cache.get(key)

    assert {:error, :maximum} = Task.async(fn -> Schema.validate(6, schema) end) |> Task.await()

    assert {:error, {:type, "integer"}} =
             Task.async(fn -> Schema.validate("4", schema) end) |> Task.await()

    assert :ok = Task.async(fn -> Schema.validate(5, schema) end) |> Task.await()

    changed = Map.put(schema, "maximum", 3)
    assert {:error, :maximum} = Schema.validate(4, changed)
    assert :ok = Schema.validate(4, schema)
  end

  test "cached keys and compiled roots detach slices from larger source binaries" do
    backing = :binary.copy("x", 1_000_000)
    value = :binary.part(backing, 0, 1_000)
    assert :binary.referenced_byte_size(value) == 1_000_000
    schema = %{"const" => value, "title" => unique_title()}
    key = {schema, true, Schema.default_instance_bytes()}
    assert :ok = Schema.validate(value, schema)
    [{cached_key, cached_root}] = :ets.lookup(Cache, key)
    {cached_schema, _, _} = cached_key

    assert :binary.referenced_byte_size(cached_schema["const"]) == byte_size(value)
    assert :binary.referenced_byte_size(cached_root.raw["const"]) == byte_size(value)
    assert cached_schema == schema
    assert cached_root.raw["const"] == value
    assert :ok = Task.async(fn -> Schema.validate(value, schema) end) |> Task.await()
    assert {:error, :const_mismatch} = Schema.validate("different", schema)
  end

  test "an uncopyable closure bypasses retention and releases its reservation" do
    backing = :binary.copy("x", 1_000_000)
    value = :binary.part(backing, 0, 1_000)
    assert :ok = Cache.put(:closure, fn -> value end, @cache)
    assert :miss = Cache.get(:closure, @cache)
    assert :ok = Cache.put(:after_closure, %{root: :stored}, @cache)
    assert {:ok, %{root: :stored}} = Cache.get(:after_closure, @cache)
  end

  test "cached roots retain format policy and the caller's schema and instance byte limits" do
    schema = %{"format" => "date", "title" => unique_title()}
    assert :ok = Schema.validate("bad", schema, formats: false)
    assert {:error, :format} = Schema.validate("bad", schema)
    assert {:error, :format} = Schema.validate("bad", schema, formats: true)
    assert :ok = Schema.validate("bad", schema, formats: false)

    large_schema = %{"title" => :binary.copy("a", 600), "type" => "string"}
    assert :ok = Schema.validate("small", large_schema, max_bytes: 1_024)
    assert {:error, :not_json} = Schema.validate("small", large_schema, max_bytes: 512)

    assert {:error, :not_json} =
             Schema.validate(:binary.copy("b", 1_024), large_schema, max_bytes: 1_024)

    assert :ok = Schema.validate("small", large_schema, max_bytes: 1_024)
  end

  test "invalid schemas never occupy the successful compilation cache" do
    schema = %{"title" => unique_title(), "type" => "unsupported"}
    key = {schema, true, Schema.default_instance_bytes()}
    assert {:error, {:invalid_keyword, "type"}} = Schema.validate_schema(schema)
    assert :miss = Cache.get(key)
    assert {:error, {:invalid_keyword, "type"}} = Schema.validate(1, schema)
    assert :miss = Cache.get(key)
  end

  test "cached recursive compositions still have a validation deadline" do
    definitions =
      Map.new(0..22, fn index ->
        schema =
          if index == 22 do
            %{"type" => "integer"}
          else
            reference = %{"$ref" => "#/$defs/n#{index + 1}"}
            %{"allOf" => [reference, reference]}
          end

        {"n#{index}", schema}
      end)

    schema = %{"$defs" => definitions, "$ref" => "#/$defs/n0", "title" => unique_title()}
    assert :ok = Schema.validate_schema(schema)
    assert {:ok, %JSV.Root{}} = Cache.get({schema, true, Schema.default_instance_bytes()})

    for _ <- 1..2 do
      assert {:error, :schema_validation_timeout} =
               Task.async(fn -> Schema.validate(1, schema) end) |> Task.await()
    end
  end

  test "standalone validation works while the application cache is unavailable" do
    application = AttestoMCP.Server.Application
    :ok = Supervisor.terminate_child(application, Cache)
    on_exit(fn -> Supervisor.restart_child(application, Cache) end)
    schema = %{"type" => "integer", "title" => unique_title()}

    assert :ok = Schema.validate(1, schema)
    assert {:error, {:type, "integer"}} = Schema.validate("1", schema)
    assert :miss = Cache.get({schema, true, Schema.default_instance_bytes()})
    assert {:ok, _pid} = Supervisor.restart_child(application, Cache)
    assert :ok = Schema.validate(2, schema)
    assert {:ok, %JSV.Root{}} = Cache.get({schema, true, Schema.default_instance_bytes()})
  end

  defp unique_title, do: "cache-test-#{System.unique_integer([:positive])}"

  defp wait_for_released_reservation do
    Enum.reduce_while(1..100, {:error, :reservation_not_released}, fn _, _ ->
      if :sys.get_state(@cache).reservation == nil do
        {:halt, :ok}
      else
        Process.sleep(1)
        {:cont, {:error, :reservation_not_released}}
      end
    end)
  end
end
