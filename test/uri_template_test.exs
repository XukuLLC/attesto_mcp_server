defmodule AttestoMCP.Server.UriTemplateTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server.UriTemplate

  test "validates the exact grammar and layouts used by the matcher" do
    uri_validator = fn value ->
      if String.starts_with?(value, ["urn:", "https://"]), do: :ok, else: {:error, :uri}
    end

    assert UriTemplate.valid?("urn:records/{id}/versions/{version}", uri_validator)
    assert UriTemplate.valid?("https://example.test/search{?q,limit}", uri_validator)

    for invalid <- [
          "urn:records/{}",
          "urn:records/{id}/{id}",
          "urn:records/{first}{second}",
          "urn:records/{#fragment}",
          "https://example.test/search{?q}/suffix",
          "https://example.test/search{?q,,limit}"
        ] do
      refute UriTemplate.valid?(invalid, uri_validator)
    end
  end

  test "matches bounded path and query templates" do
    budget = UriTemplate.new_budget()

    assert {:ok, %{"id" => "record-7"}, budget} =
             UriTemplate.match("urn:records/{id}", "urn:records/record-7", budget)

    assert {:ok, %{"query" => "hello world"}, _budget} =
             UriTemplate.match(
               "https://example.test/search{?query}",
               "https://example.test/search?query=hello+world",
               budget
             )
  end

  test "rejects unsafe decoded captures" do
    assert {:error, _budget} =
             UriTemplate.match(
               "urn:records/{id}",
               "urn:records/%2e%2e",
               UriTemplate.new_budget()
             )
  end

  test "returns an exhausted budget without attempting a match" do
    assert {:exhausted, %{candidates: 0, work: 0}} =
             UriTemplate.match("urn:{id}", "urn:value", %{candidates: 0, work: 10})
  end
end
