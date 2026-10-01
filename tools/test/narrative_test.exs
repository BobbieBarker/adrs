defmodule AdrDist.NarrativeTest do
  use ExUnit.Case, async: true

  alias AdrDist.{Build, Error, Markdown, Retrieval, Source, TestSupport}

  test "narrative parsing is explicit and preserves the whole Decision envelope" do
    body = narrative_body()
    offset = 17

    assert {:error, {:invalid_markdown, _, "ADR contains no numbered rules"}} =
             Markdown.parse(body)

    assert {:error, {:invalid_markdown, _, "ADR contains no numbered rules"}} =
             Markdown.parse(body, offset, :rules)

    assert {:ok, document} = Markdown.parse(body, offset, :narrative)
    assert document.rules == []
    assert [decision] = document.supporting
    assert decision.title == "Decision"
    assert decision.path == ["ADR-001: Narrative Fixture", "Decision"]
    assert Markdown.section_body(document.decision) == "Keep the responsibility coherent."
    assert decision.display_text == decision_region(body)
    assert decision.start_line == offset + line_of(body, "## Decision")
    assert decision.end_line == offset + line_of(body, "## Consequences") - 1
    assert decision.display_text =~ "### 4. Own the lifecycle"
    assert decision.display_text =~ "## Review criteria"
    assert decision.display_text =~ "### Rule 99: Fenced payload"
    assert decision.display_text =~ "**Wrong:** fenced payload"
    refute decision.display_text =~ "## Consequences"
    assert Markdown.section_body(document.context) =~ "### Background detail"
    assert Markdown.section_body(document.consequences) =~ "### Tradeoff detail"
  end

  test "narrative mode rejects valid and malformed rule grammar outside fences" do
    markers = [
      "### Rule 1: A rule",
      "#### Rule one: Malformed numbering",
      "### Rule1: Missing space",
      "### Universal rules",
      "### Situational rules",
      "**Correct:** example",
      "**Wrong (example):** example",
      "**Why** missing colon"
    ]

    Enum.each(markers, fn marker ->
      body = String.replace(narrative_body(), "### 2. Hide representation", marker)

      assert {:error, {:invalid_markdown, line, message}} = Markdown.parse(body, 9, :narrative)
      assert line == 9 + line_of(body, marker)
      assert message =~ "narrative structure cannot contain Rule headings"
    end)
  end

  test "narrative mode retains structural validation and rejects empty decisions" do
    body = narrative_body()
    empty = String.replace(body, decision_region(body), "## Decision")

    assert {:error, {:invalid_markdown, _, "narrative Decision must not be empty"}} =
             Markdown.parse(empty, 0, :narrative)

    missing = String.replace(body, "## Consequences", "## Missing")
    assert {:error, {:invalid_markdown, _, message}} = Markdown.parse(missing, 0, :narrative)
    assert message =~ "expected exactly one"

    unclosed = body <> "\n```\n"

    assert {:error, {:invalid_markdown, _, "unclosed fenced code block"}} =
             Markdown.parse(unclosed, 0, :narrative)

    assert {:error, {:invalid_markdown, 6, "structure must be :rules or :narrative"}} =
             Markdown.parse(body, 5, :unknown)
  end

  test "registry opt-in emits one v1 supporting record with exact source evidence" do
    root = fixture_root!()
    source_root = Path.join(root, "adrs")
    output_root = Path.join(root, "dist")
    source = write_fixture!(source_root, "narrative")

    assert {:ok, [domain]} = Source.load(source_root)
    assert [adr] = domain.adrs
    assert adr.body == narrative_body() <> "\n"
    assert {:ok, [summary, decision] = records} = Retrieval.build([adr])
    assert Enum.map(records, & &1["record_kind"]) == ["adr_summary", "supporting"]
    assert summary["record_id"] == "software-design:adr-001"
    assert summary["decision"] == "Keep the responsibility coherent."
    assert decision["record_id"] == "software-design:adr-001:supporting:decision"
    assert decision["parent_id"] == summary["record_id"]
    assert decision["hydrate_id"] == decision["record_id"]
    assert decision["heading_path"] == ["Decision"]
    assert decision["schema_version"] == "retrieval-v1"
    assert is_nil(decision["rule_number"])
    assert is_nil(decision["polarity"])
    assert decision["display_text"] == decision_region(narrative_body())
    assert decision["retrieval_text"] =~ decision["display_text"]
    assert decision["source_sha256"] == TestSupport.sha256(decision["display_text"])
    assert decision["source_start_line"] == line_of(source, "## Decision")
    assert decision["source_end_line"] == line_of(source, "## Consequences") - 1

    assert source
           |> String.split("\n", trim: false)
           |> Enum.slice((decision["source_start_line"] - 1)..(decision["source_end_line"] - 1))
           |> Enum.join("\n")
           |> String.trim() == decision["display_text"]

    assert {:ok, _summary} = Build.build(source_root, output_root)

    assert [legacy] =
             TestSupport.jsonl!(Path.join([output_root, "software-design", "adrs.jsonl"]))

    assert legacy["body"] == adr.body

    assert File.read!(
             Path.join([
               output_root,
               "software-design",
               "claude-code",
               ".claude",
               "rules",
               "adr-001.md"
             ])
           ) ==
             adr.body
  end

  test "registry rejects unknown or non-string structures without bypassing default rules" do
    Enum.each(["narration", nil, false, 3, []], fn structure ->
      source_root = Path.join(fixture_root!(), "adrs")
      write_fixture!(source_root, structure)

      assert {:error, %Error{code: :invalid_manifest, message: message}} =
               Source.load(source_root)

      assert message =~ "structure must be rules or narrative"
    end)

    Enum.each([:omitted, "rules"], fn structure ->
      source_root = Path.join(fixture_root!(), "adrs")
      write_fixture!(source_root, structure)

      assert {:error, %Error{code: :invalid_markdown, message: message}} =
               Source.load(source_root)

      assert message == "ADR contains no numbered rules"
    end)
  end

  defp fixture_root! do
    root = TestSupport.temporary_directory!("adr-narrative")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write_fixture!(source_root, structure) do
    domain_root = Path.join(source_root, "software-design")
    File.mkdir_p!(domain_root)

    structure_line =
      if structure == :omitted, do: "", else: "    structure: #{Jason.encode!(structure)}\n"

    manifest = """
    domain: software-design
    title: Software design
    description: Narrative fixture.
    adrs:
      - id: 1
        file: adr-001-narrative-fixture.md
        title: Narrative fixture
        description: Retrieve a complete design decision.
    #{structure_line}    applies_to: {}
    """

    source = """
    ---
    type: adr
    id: 1
    title: Narrative Fixture
    status: accepted
    date: '2026-09-30'
    tags: [software-design]
    description: Preserve a complete narrative decision.
    ---

    #{narrative_body()}
    """

    File.write!(Path.join(domain_root, "adr-rules.yaml"), manifest)
    File.write!(Path.join(domain_root, "adr-001-narrative-fixture.md"), source)
    source
  end

  defp decision_region(body) do
    [_, decision] = String.split(body, "## Decision\n", parts: 2)
    [region, _] = String.split(decision, "## Consequences", parts: 2)
    String.trim("## Decision\n" <> region)
  end

  defp line_of(body, marker) do
    body |> String.split("\n", trim: false) |> Enum.find_index(&(&1 == marker)) |> Kernel.+(1)
  end

  defp narrative_body do
    """
    # ADR-001: Narrative Fixture

    ## Context

    Context.

    ### Background detail

    Preserve context subsections too.

    ## Decision

    Keep the responsibility coherent.

    ### 1. Identify ownership

    A contrasting example keeps its explanation:

    ```text
    ### Rule 99: Fenced payload
    **Wrong:** fenced payload
    ```

    This demonstrates the dependency to remove.

    ### 2. Hide representation

    Keep the storage invariant owned.

    ### 3. Weigh interface cost

    Avoid mechanical splits.

    ### 4. Own the lifecycle

    Preserve cancellation and completion.

    ## Review criteria

    Who owns the invariant?

    ## Consequences

    Some modules stay together.

    ### Tradeoff detail

    Interfaces still have a cost.
    """
  end
end
