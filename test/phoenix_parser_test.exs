defmodule AttestoMCP.Server.PhoenixParserTest do
  use ExUnit.Case, async: true

  test "bypasses the MCP route and its trailing-slash equivalent" do
    parser =
      AttestoMCP.Server.PhoenixParser.init(
        mcp_path: "/mcp",
        parsers: [:json],
        json_decoder: Jason
      )

    mcp = json_conn("/mcp")

    assert AttestoMCP.Server.PhoenixParser.call(mcp, parser).body_params == %Plug.Conn.Unfetched{
             aspect: :body_params
           }

    trailing_slash = json_conn("/mcp/")

    assert AttestoMCP.Server.PhoenixParser.call(trailing_slash, parser).body_params ==
             %Plug.Conn.Unfetched{aspect: :body_params}

    repeated_trailing_slash = json_conn("/mcp//")

    assert AttestoMCP.Server.PhoenixParser.call(repeated_trailing_slash, parser).body_params ==
             %Plug.Conn.Unfetched{aspect: :body_params}

    nested = json_conn("/mcp/admin")

    parsed = AttestoMCP.Server.PhoenixParser.call(nested, parser)
    assert parsed.body_params == %{"ok" => true}

    unrelated = json_conn("/health")

    assert AttestoMCP.Server.PhoenixParser.call(unrelated, parser).body_params == %{"ok" => true}
  end

  test "bypasses every configured MCP route without bypassing parents, prefixes, or children" do
    parser =
      AttestoMCP.Server.PhoenixParser.init(
        mcp_path: ["/mcp/a", "/mcp/b", "/mcp/c"],
        parsers: [:json],
        json_decoder: Jason
      )

    for path <- ["/mcp/a", "/mcp/b/", "/mcp/c//"] do
      assert AttestoMCP.Server.PhoenixParser.call(json_conn(path), parser).body_params ==
               %Plug.Conn.Unfetched{aspect: :body_params}
    end

    for path <- ["/mcp", "/mcp/a/admin", "/mcp/ab", "/mcp/copy", "/health"] do
      assert AttestoMCP.Server.PhoenixParser.call(json_conn(path), parser).body_params == %{
               "ok" => true
             }
    end
  end

  test "decodes the real connection path exactly as Phoenix routing does" do
    parser =
      AttestoMCP.Server.PhoenixParser.init(
        mcp_path: ["/mcp/a", "/mcp/b"],
        parsers: [:json],
        json_decoder: Jason
      )

    route_equivalent = json_conn("/mcp/%61")

    assert AttestoMCP.Server.PhoenixParser.call(route_equivalent, parser).body_params ==
             %Plug.Conn.Unfetched{aspect: :body_params}

    encoded_separator = json_conn("/mcp/a%2Fchild")

    assert AttestoMCP.Server.PhoenixParser.call(encoded_separator, parser).body_params == %{
             "ok" => true
           }

    traversal = json_conn("/mcp/a/%2e%2e")
    assert AttestoMCP.Server.PhoenixParser.call(traversal, parser).body_params == %{"ok" => true}
  end

  test "rejects non-canonical paths" do
    assert_raise ArgumentError, fn ->
      AttestoMCP.Server.PhoenixParser.init(mcp_path: "/mcp/../admin", parsers: [:json])
    end

    assert_raise ArgumentError, fn ->
      AttestoMCP.Server.PhoenixParser.init(mcp_path: "/", parsers: [:json])
    end

    assert_raise ArgumentError, fn ->
      AttestoMCP.Server.PhoenixParser.init(mcp_path: <<255>>, parsers: [:json])
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

    assert_raise ArgumentError, fn ->
      AttestoMCP.Server.PhoenixParser.init(%{mcp_path: "/mcp"})
    end
  end

  test "rejects empty, duplicate, improper, and over-limit path lists" do
    invalid_path_lists = [
      [],
      ["/mcp/a", "/mcp/a"],
      ["/mcp/a", "/mcp/../admin"],
      ["/mcp/a" | :improper],
      Enum.map(1..33, &"/mcp/#{&1}")
    ]

    for paths <- invalid_path_lists do
      assert_raise ArgumentError, fn ->
        AttestoMCP.Server.PhoenixParser.init(mcp_path: paths, parsers: [:json])
      end
    end
  end

  defp json_conn(path) do
    Plug.Test.conn(:post, path, ~s({"ok":true}))
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end
end
