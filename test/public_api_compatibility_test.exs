defmodule AttestoMCP.Server.PublicAPICompatibilityTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server.{CachePolicy, Icons}

  test "hidden cache and icon limit getters remain callable throughout 2.x" do
    assert CachePolicy.cacheable_methods() == [
             "server/discover",
             "tools/list",
             "prompts/list",
             "resources/list",
             "resources/templates/list",
             "resources/read"
           ]

    assert Icons.max_icons() == 16
    assert Icons.max_total_bytes() == 131_072
  end
end
