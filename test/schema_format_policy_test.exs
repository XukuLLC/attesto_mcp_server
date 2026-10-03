defmodule AttestoMCP.Server.SchemaFormatPolicyTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

  @era "2026-07-28"

  defp call(server, id, name, extra \\ %{}) do
    params =
      Map.merge(
        %{
          "name" => name,
          "arguments" => %{},
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @era,
            "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
          }
        },
        extra
      )

    Server.dispatch(
      server,
      %{kind: :request, id: id, method: "tools/call", params: params},
      %{principal: "format-policy"},
      version: @era
    )
  end

  defp field_schema(format) do
    %{
      "type" => "object",
      "required" => ["value"],
      "properties" => %{"value" => %{"type" => "string", "format" => format}}
    }
  end

  test "2.x tool formats remain assertions with an explicit annotation opt-out" do
    for {opts, enforce?} <- [{[], true}, {[schema_formats: false], false}] do
      {:ok, server} = Server.start_link(opts)

      for {format, invalid} <- [
            {"email", "invalid"},
            {"uri", "not a url"},
            {"date", "2026-02-30"},
            {"date-time", "not a timestamp"}
          ] do
        :ok =
          Server.register_tool(server, format <> "-input", %{
            input_schema: field_schema(format),
            handler: fn _, _ -> {:ok, "called"} end
          })

        result = call(server, 1, format <> "-input", %{"arguments" => %{"value" => invalid}})

        if enforce? do
          assert {1, %{"error" => %{"code" => -32602}}} = result
        else
          assert {1, %{"result" => %{"isError" => false}}} = result
        end

        :ok =
          Server.register_tool(server, format <> "-output", %{
            output_schema: field_schema(format),
            handler: fn _, _ ->
              {:ok, %{"content" => [], "structuredContent" => %{"value" => invalid}}}
            end
          })

        assert {2, %{"result" => output}} = call(server, 2, format <> "-output")
        assert Map.get(output, "isError", false) == enforce?
      end
    end
  end

  test "elicitation URLs reject malformed URIs even with annotation tool policy" do
    {:ok, server} = Server.start_link(schema_formats: false)

    for {url, index} <- Enum.with_index(["", "javascript:alert(1) not a url"], 1) do
      name = "bad-url-#{index}"

      :ok =
        Server.register_tool(server, name, %{
          handler: fn _, _ ->
            {:input_required,
             %{
               "link" => %{
                 "method" => "elicitation/create",
                 "params" => %{"mode" => "url", "message" => "continue", "url" => url}
               }
             }}
          end
        })

      assert {^index, %{"error" => _}} = call(server, index, name)
    end
  end

  test "accepted elicitation form content always asserts its declared formats" do
    {:ok, server} = Server.start_link(schema_formats: false)

    for {format, invalid} <- [
          {"email", "invalid"},
          {"uri", "not a url"},
          {"date", "2026-02-30"},
          {"date-time", "invalid"}
        ] do
      :ok =
        Server.register_tool(server, format, %{
          handler: fn args, _ ->
            if Map.has_key?(args, "answer") do
              {:ok, "accepted"}
            else
              {:input_required,
               %{
                 "answer" => %{
                   "method" => "elicitation/create",
                   "params" => %{"message" => "enter", "requestedSchema" => field_schema(format)}
                 }
               }}
            end
          end
        })

      assert {1, %{"result" => %{"requestState" => state}}} = call(server, 1, format)

      assert {2, %{"error" => %{"data" => %{"reason" => "invalid_input_response"}}}} =
               call(server, 2, format, %{
                 "requestState" => state,
                 "inputResponses" => %{
                   "answer" => %{"action" => "accept", "content" => %{"value" => invalid}}
                 }
               })
    end
  end
end
