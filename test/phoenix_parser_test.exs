defmodule AttestoMCP.Server.PhoenixParserTest do
  use ExUnit.Case, async: true

  test "bypasses the MCP route and its trailing-slash equivalent" do
    parser =
      AttestoMCP.Server.PhoenixParser.init(
        mcp_path: "/mcp",
        parsers: [:json],
        json_decoder: Jason
      )

    mcp = Plug.Test.conn(:post, "/mcp", ~s({"ok":true}))

    assert AttestoMCP.Server.PhoenixParser.call(mcp, parser).body_params == %Plug.Conn.Unfetched{
             aspect: :body_params
           }

    trailing_slash =
      Plug.Test.conn(:post, "/mcp/", ~s({"ok":true}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    assert AttestoMCP.Server.PhoenixParser.call(trailing_slash, parser).body_params ==
             %Plug.Conn.Unfetched{aspect: :body_params}

    repeated_trailing_slash =
      Plug.Test.conn(:post, "/mcp//", ~s({"ok":true}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    assert AttestoMCP.Server.PhoenixParser.call(repeated_trailing_slash, parser).body_params ==
             %Plug.Conn.Unfetched{aspect: :body_params}

    nested =
      Plug.Test.conn(:post, "/mcp/admin", ~s({"ok":true}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    parsed = AttestoMCP.Server.PhoenixParser.call(nested, parser)
    assert parsed.body_params == %{"ok" => true}

    unrelated =
      Plug.Test.conn(:post, "/health", ~s({"ok":true}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    assert AttestoMCP.Server.PhoenixParser.call(unrelated, parser).body_params == %{"ok" => true}
  end

  test "rejects non-canonical paths" do
    assert_raise ArgumentError, fn ->
      AttestoMCP.Server.PhoenixParser.init(mcp_path: "/mcp/../admin", parsers: [:json])
    end

    assert_raise ArgumentError, fn ->
      AttestoMCP.Server.PhoenixParser.init(mcp_path: "/", parsers: [:json])
    end
  end

  test "rejects malformed wrapper options instead of choosing a duplicate path" do
    assert_raise ArgumentError, fn ->
      AttestoMCP.Server.PhoenixParser.init(
        mcp_path: "/mcp",
        mcp_path: "/other",
        parsers: [:json]
      )
    end

    assert_raise ArgumentError, fn ->
      AttestoMCP.Server.PhoenixParser.init([{:mcp_path, "/mcp"}, :not_a_keyword])
    end
  end
end
