defmodule AttestoMCP.Server.HeaderNameTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server.HeaderName

  @reserved ~w(authorization cookie host content-length transfer-encoding connection upgrade)

  test "accepts HTTP token names and reserved words used under the mcp-param prefix" do
    assert HeaderName.valid?("x-request-id")
    assert HeaderName.valid?("mcp-param-account")
    assert HeaderName.valid_suffix?("account")

    for name <- @reserved do
      assert HeaderName.valid?(name)
      assert HeaderName.valid?(String.upcase(name))
      assert HeaderName.valid_suffix?(name)
    end
  end

  test "rejects invalid, overlong, non-UTF-8, and already-prefixed names" do
    for name <- ["", "bad name", "bad:name", <<255>>, String.duplicate("a", 257)] do
      refute HeaderName.valid?(name)
    end

    refute HeaderName.valid_suffix?("mcp-param-account")
    refute HeaderName.valid_suffix?(String.duplicate("a", 129))
  end
end
