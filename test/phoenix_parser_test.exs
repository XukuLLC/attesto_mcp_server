defmodule AttestoMCP.Server.PhoenixParserTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 3]

  defmodule ForwardTarget do
    @moduledoc false
    import Plug.Conn

    def init(options), do: options

    def call(conn, _options) do
      unread? = match?(%Plug.Conn.Unfetched{aspect: :body_params}, conn.body_params)
      send_resp(conn, 404, if(unread?, do: "unread", else: "parsed"))
    end
  end

  defmodule ForwardRouter do
    @moduledoc false
    use Phoenix.Router

    forward("/mcp", ForwardTarget)
  end

  defmodule EndpointPipeline do
    @moduledoc false
    use Plug.Builder

    plug AttestoMCP.Server.PhoenixParser,
      mcp_path: "/mcp",
      parsers: [:urlencoded, :multipart, :json],
      json_decoder: Jason,
      length: 16

    plug(ForwardRouter)
  end

  test "Phoenix forward child paths reach the mount with an unread body" do
    response = EndpointPipeline.call(json_conn("/mcp/anything"), [])

    assert response.status == 404
    assert response.resp_body == "unread"
  end

  test "Phoenix forward child paths bypass malformed, oversized, and multipart bodies" do
    boundary = "attesto-boundary"

    requests = [
      conn(:post, "/mcp/malformed", "{")
      |> put_req_header("content-type", "application/json"),
      conn(:post, "/mcp/oversized", Jason.encode!(%{"value" => String.duplicate("x", 32)}))
      |> put_req_header("content-type", "application/json"),
      conn(
        :post,
        "/mcp/upload",
        "--#{boundary}\r\ncontent-disposition: form-data; name=\"file\"; " <>
          "filename=\"payload.txt\"\r\ncontent-type: text/plain\r\n\r\npayload\r\n" <>
          "--#{boundary}--\r\n"
      )
      |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
    ]

    for request <- requests do
      response = EndpointPipeline.call(request, [])
      assert response.status == 404
      assert response.resp_body == "unread"
    end
  end

  test "bypasses the MCP forward and its complete subtree" do
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

    assert AttestoMCP.Server.PhoenixParser.call(nested, parser).body_params ==
             %Plug.Conn.Unfetched{aspect: :body_params}

    unrelated = json_conn("/health")

    assert AttestoMCP.Server.PhoenixParser.call(unrelated, parser).body_params == %{"ok" => true}
  end

  test "bypasses every configured MCP subtree without bypassing parents or sibling prefixes" do
    parser =
      AttestoMCP.Server.PhoenixParser.init(
        mcp_path: ["/mcp/a", "/mcp/b", "/mcp/c"],
        parsers: [:json],
        json_decoder: Jason
      )

    for path <- ["/mcp/a", "/mcp/a/admin", "/mcp/b/", "/mcp/b/child", "/mcp/c//"] do
      assert AttestoMCP.Server.PhoenixParser.call(json_conn(path), parser).body_params ==
               %Plug.Conn.Unfetched{aspect: :body_params}
    end

    for path <- ["/mcp", "/mcp/ab", "/mcp/copy", "/health"] do
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

    assert AttestoMCP.Server.PhoenixParser.call(traversal, parser).body_params ==
             %Plug.Conn.Unfetched{aspect: :body_params}
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
