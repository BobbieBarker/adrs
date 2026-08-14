defmodule AdrDist.SchemaContractTest do
  use ExUnit.Case, async: true

  alias AdrDist.TestSupport

  test "documents provenance envelopes and payload hash semantics" do
    properties = schema() |> Map.fetch!("properties")

    assert properties["source_start_line"]["description"] =~ "provenance envelope"
    assert properties["source_start_line"]["description"] =~ "discontiguous"
    assert properties["source_start_line"]["description"] =~ "contributing to display_text"
    assert properties["source_end_line"]["description"] =~ "not a promise"
    assert properties["source_end_line"]["description"] =~ "retrieval_text"
    assert properties["source_sha256"]["description"] =~ "UTF-8 bytes of display_text"
    assert properties["retrieval_sha256"]["description"] =~ "UTF-8 bytes of retrieval_text"

    assert properties["retrieval_text"]["description"] =~
             "outside display_text's provenance envelope"
  end

  test "allows an empty direct Decision but requires non-empty Context and Consequences" do
    properties = schema() |> Map.fetch!("properties")

    assert properties["context"] == %{"$ref" => "#/$defs/nonEmptyString"}
    assert properties["decision"] == %{"type" => "string"}
    assert properties["consequences"] == %{"$ref" => "#/$defs/nonEmptyString"}
  end

  test "restricts v1 example record IDs to the single per-polarity index" do
    record_id = schema() |> get_in(["$defs", "recordId"])
    pattern = Regex.compile!(Map.fetch!(record_id, "pattern"))

    assert record_id["description"] =~ "exactly one Correct and one Wrong"
    assert Regex.match?(pattern, "elixir-otp:adr-005:rule-02:example:correct:01")
    assert Regex.match?(pattern, "elixir-otp:adr-005:rule-02:example:wrong:01")
    refute Regex.match?(pattern, "elixir-otp:adr-005:rule-02:example:correct:02")
    refute Regex.match?(pattern, "elixir-otp:adr-005:rule-02:example:wrong:00")

    assert Regex.match?(pattern, "elixir-otp:adr-005")
    assert Regex.match?(pattern, "elixir-otp:adr-005:rule-02")
    assert Regex.match?(pattern, "elixir-otp:adr-005:supporting:decision-test")
  end

  defp schema do
    TestSupport.repo_root()
    |> Path.join("schema/retrieval-v1.schema.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
