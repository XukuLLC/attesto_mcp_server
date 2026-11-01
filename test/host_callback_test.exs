defmodule AttestoMCP.Server.HostCallbackTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server.HostCallback

  defmodule Target do
    def echo(first, second, extra), do: [first, second, extra]
  end

  test "a three-tuple receives the per-call arguments first and extra_args after them" do
    assert HostCallback.invoke({Target, :echo, [:extra]}, [:first, :second]) == [
             :first,
             :second,
             :extra
           ]

    assert HostCallback.valid?({Target, :echo, [:extra]}, 2)
    refute HostCallback.valid?({Target, :echo, [:extra]}, 3)
  end
end
