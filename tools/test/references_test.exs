defmodule AdrDist.ReferencesTest do
  use ExUnit.Case, async: true

  alias AdrDist.References

  test "extracts same-domain, qualified, and plural references with exact source evidence" do
    content = """
    # ADR-001: The document's own title is identity, not a citation

    See ADR-002 for the broad decision.
    Apply ADR-002 Rule 3 for this case.
    Compare `elixir-otp` ADR-005 Rules 1, 2, and 4.
    Also compare elixir-ecto ADR-001 Rule 1.
    """

    assert {:ok, references} = References.extract(content, "elixir-conventions")

    assert Enum.map(references, &reference_shape/1) == [
             {"ADR-002", 3, "elixir-conventions", 2, []},
             {"ADR-002 Rule 3", 4, "elixir-conventions", 2, [3]},
             {"`elixir-otp` ADR-005 Rules 1, 2, and 4", 5, "elixir-otp", 5, [1, 2, 4]},
             {"elixir-ecto ADR-001 Rule 1", 6, "elixir-ecto", 1, [1]}
           ]
  end

  test "resolves plural citations into separate evidence-bearing target objects" do
    content = "See `elixir-otp` ADR-005 Rules 1, 2, and 4."

    known_ids =
      MapSet.new([
        "elixir-otp:adr-005:rule-01",
        "elixir-otp:adr-005:rule-02",
        "elixir-otp:adr-005:rule-04"
      ])

    assert {:ok, references} =
             References.resolve(
               content,
               "elixir-conventions",
               known_ids,
               "elixir-conventions:adr-001:rule-01"
             )

    assert Enum.map(references, &Map.fetch!(&1, "target_id")) == [
             "elixir-otp:adr-005:rule-01",
             "elixir-otp:adr-005:rule-02",
             "elixir-otp:adr-005:rule-04"
           ]

    assert Enum.all?(references, fn reference ->
             reference["raw_text"] == "`elixir-otp` ADR-005 Rules 1, 2, and 4" and
               reference["source_line"] == 1
           end)
  end

  test "reports malformed citation-like syntax with its line" do
    malformed = [
      "Use ADR-12 here.",
      "Use ADR-ABC here.",
      "Use ADR-002 Rule two here.",
      "Use ADR-002 Rules 1 and here.",
      "Use ADR-005 Rule 1a here.",
      "Use ADR-005 Rule 1/2 here.",
      "Use ADR-005 Rule 1 or 2 here.",
      "Use ADR-005 Rules 1 through 3 here."
    ]

    Enum.each(malformed, fn content ->
      assert {:error, errors} = References.extract(content, "elixir-conventions")
      diagnostic = inspect(errors)
      assert diagnostic =~ "1"
      assert diagnostic =~ "ADR-"
    end)
  end

  test "ignores backticked code terms while preserving explicit unknown-domain failures" do
    content = "The `conn` ADR-009 concern is local to this domain."

    assert {:ok, [reference]} = References.extract(content, "elixir-conventions")

    assert reference_shape(reference) ==
             {"ADR-009", 1, "elixir-conventions", 9, []}

    known_ids = MapSet.new(["elixir-conventions:adr-009"])

    assert {:ok, [resolved]} =
             References.resolve(
               content,
               "elixir-conventions",
               known_ids,
               "elixir-conventions:adr-001:rule-01"
             )

    assert resolved["target_id"] == "elixir-conventions:adr-009"

    assert {:error, errors} =
             References.resolve(
               "See `elixir-unknown` ADR-001.",
               "elixir-conventions",
               known_ids,
               "elixir-conventions:adr-001:rule-01"
             )

    assert inspect(errors) =~ "elixir-unknown:adr-001"
  end

  test "requires a left token boundary for unbackticked domain qualifiers" do
    glued_qualifiers = [
      {"notelixir-otp ADR-005", 5},
      {"foo-elixir-unknown ADR-001", 1},
      {"my_elixir-ecto ADR-002", 2}
    ]

    Enum.each(glued_qualifiers, fn {content, adr_number} ->
      assert {:ok, [reference]} = References.extract(content, "elixir-conventions")

      assert reference_shape(reference) ==
               {"ADR-#{String.pad_leading(Integer.to_string(adr_number), 3, "0")}", 1,
                "elixir-conventions", adr_number, []}
    end)
  end

  test "reports unknown domains, ADRs, and Rules during global resolution" do
    known_ids = MapSet.new(["elixir-conventions:adr-001", "elixir-conventions:adr-001:rule-01"])

    citations = [
      "elixir-unknown ADR-001",
      "`elixir-unknown` ADR-001",
      "ADR-999",
      "ADR-001 Rule 99"
    ]

    Enum.each(citations, fn citation ->
      assert {:error, errors} =
               References.resolve(
                 citation,
                 "elixir-conventions",
                 known_ids,
                 "elixir-conventions:adr-001:rule-01"
               )

      assert inspect(errors) =~ "unresolved"
    end)
  end

  defp reference_shape(reference) do
    {
      Map.fetch!(reference, :raw_text),
      Map.fetch!(reference, :source_line),
      Map.fetch!(reference, :domain),
      Map.fetch!(reference, :adr_number),
      Map.fetch!(reference, :rule_numbers)
    }
  end
end
