defmodule AdrDist.MarkdownTest do
  use ExUnit.Case, async: true

  alias AdrDist.Markdown

  test "parses nested rules, qualified labels, deep headings, and multiple variable fences" do
    body = """
    # ADR-001: Fixture

    ## Context

    Fixture context.

    ## Decision

    Direct decision prose.

    ### Decision test

    Ask whether this applies.

    ### Universal rules

    #### Rule 1: Preserve the complete example region

    Keep the prescription outside example fences.

    **Correct (staged excerpt):**

    ````elixir
    # A heading and structural-looking labels inside a fence are payload.
    ### Rule 99: Not a real rule
    **Wrong:**
    :ok
    ````

    The staged examples are intentionally one searchable region.

    ~~~~elixir
    def second_stage, do: :ok
    ~~~~

    ##### Correct-example commentary

    Keep this deeper subsection inside the Rule and the Correct region.

    **Wrong:**

    ```elixir
    def wrong, do: :error
    ```

    **Why:** The complete region supplies the evidence.

    ## Consequences

    Fixture consequence.
    """

    assert {:ok, document} = Markdown.parse(body)
    assert document.title == "ADR-001: Fixture"
    assert Enum.map(document.supporting, & &1.title) == ["Decision test"]
    assert Markdown.section_body(document.context) == "Fixture context."
    assert Markdown.section_body(document.decision) == "Direct decision prose."
    assert Markdown.section_body(document.consequences) == "Fixture consequence."

    assert [rule] = document.rules
    assert rule.number == 1
    assert rule.title == "Preserve the complete example region"

    assert rule.path == [
             "ADR-001: Fixture",
             "Decision",
             "Universal rules",
             rule.title |> then(&("Rule 1: " <> &1))
           ]

    assert rule.statement == "Keep the prescription outside example fences."
    assert rule.correct.label == "**Correct (staged excerpt):**"
    assert rule.correct.body =~ "### Rule 99: Not a real rule"
    assert rule.correct.body =~ "**Wrong:**"
    assert rule.correct.body =~ "The staged examples are intentionally one searchable region."
    assert rule.correct.body =~ "def second_stage"
    assert rule.correct.body =~ "##### Correct-example commentary"
    assert rule.wrong.body =~ "def wrong"
    assert rule.why == "The complete region supplies the evidence."
    assert rule.start_line < rule.end_line
  end

  test "rejects an unbalanced fence" do
    body =
      valid_body("""
      **Correct:**

      ```elixir
      :ok
      """)

    assert {:error, {:invalid_markdown, line, message}} = Markdown.parse(body)
    assert line == line_of(body, "```elixir")
    assert message =~ "unclosed fenced code block"
  end

  test "requires exactly one Context, Decision, and Consequences in order" do
    out_of_order = """
    # ADR-001: Fixture

    ## Decision

    Decision first.

    ## Context

    Context second.

    ### Rule 1: One

    Statement.

    **Correct:** good

    **Wrong:** bad

    **Why:** reason

    ## Consequences

    Consequences.
    """

    duplicate_context = """
    # ADR-001: Fixture

    ## Context

    First.

    ## Context

    Second.

    ## Decision

    ### Rule 1: One

    Statement.

    **Correct:** good

    **Wrong:** bad

    **Why:** reason

    ## Consequences

    Consequences.
    """

    assert {:error, {:invalid_markdown, out_of_order_line, _message}} =
             Markdown.parse(out_of_order)

    assert {:error, {:invalid_markdown, duplicate_line, _message}} =
             Markdown.parse(duplicate_context)

    assert is_integer(out_of_order_line)
    assert is_integer(duplicate_line)
  end

  test "rejects missing, duplicated, and noncontiguous Rule regions" do
    missing_wrong =
      valid_body("""
      **Correct:** good

      **Why:** reason
      """)

    duplicate_correct =
      valid_body("""
      **Correct:** first

      **Correct:** second

      **Wrong:** bad

      **Why:** reason
      """)

    noncontiguous = """
    # ADR-001: Fixture

    ## Context

    Context.

    ## Decision

    ### Rule 1: First

    Statement.

    **Correct:** good

    **Wrong:** bad

    **Why:** reason

    ### Rule 3: Third

    Statement.

    **Correct:** good

    **Wrong:** bad

    **Why:** reason

    ## Consequences

    Consequences.
    """

    assert {:error, {:invalid_markdown, missing_line, _message}} = Markdown.parse(missing_wrong)

    assert {:error, {:invalid_markdown, duplicate_line, _message}} =
             Markdown.parse(duplicate_correct)

    assert {:error, {:invalid_markdown, noncontiguous_line, message}} =
             Markdown.parse(noncontiguous)

    assert is_integer(missing_line)
    assert is_integer(duplicate_line)
    assert is_integer(noncontiguous_line)
    assert message =~ "rule numbers"
  end

  test "accepts only H3 and H4 Rule headings with absolute diagnostics" do
    Enum.each([2, 5, 6], fn level ->
      heading = String.duplicate("#", level) <> " Rule 1: Wrong level"
      body = body_with_rule_heading(heading)
      offset = 40

      assert {:error, {:invalid_markdown, line, message}} = Markdown.parse(body, offset)
      assert line == offset + line_of(body, heading)
      assert message =~ "Rule headings must use H3 or H4"
    end)

    assert {:ok, h3_document} = body_with_rule_heading("### Rule 1: Valid H3") |> Markdown.parse()

    grouped_h4 =
      body_with_rule_heading("#### Rule 1: Valid grouped H4", "### Universal rules")

    situational_h4 =
      body_with_rule_heading("#### Rule 1: Valid situational H4", "### Situational rules")

    assert {:ok, h4_document} = Markdown.parse(grouped_h4)
    assert {:ok, situational_document} = Markdown.parse(situational_h4)
    assert hd(h3_document.rules).title == "Valid H3"
    assert hd(h4_document.rules).title == "Valid grouped H4"
    assert hd(situational_document.rules).title == "Valid situational H4"
  end

  test "rejects Rules outside Decision at their absolute heading lines" do
    rule_heading = "### Rule 1: Misplaced"
    rule = rule_block(rule_heading)

    under_context = """
    # ADR-001: Fixture

    ## Context

    Context.

    #{rule}

    ## Decision

    Decision.

    ## Consequences

    Consequences.
    """

    after_consequences = """
    # ADR-001: Fixture

    ## Context

    Context.

    ## Decision

    Decision.

    ## Consequences

    Consequences.

    #{rule}
    """

    offset = 17

    Enum.each([under_context, after_consequences], fn body ->
      assert {:error, {:invalid_markdown, line, message}} = Markdown.parse(body, offset)
      assert line == offset + line_of(body, rule_heading)
      assert message =~ "within the Decision section"
    end)
  end

  test "requires exact parent structure for H3 and H4 Rules" do
    cases = [
      body_with_rule_heading("#### Rule 1: Direct H4"),
      body_with_rule_heading("#### Rule 1: Arbitrary group", "### Notes")
    ]

    Enum.each(cases, fn body ->
      heading = Enum.find(String.split(body, "\n"), &String.contains?(&1, "Rule 1:"))

      assert {:error, {:invalid_markdown, line, message}} = Markdown.parse(body)
      assert line == line_of(body, heading)
      assert message =~ "H3 Rules must be direct Decision children"
      assert message =~ "Universal rules or Situational rules"
    end)
  end

  defp valid_body(rule_regions) do
    """
    # ADR-001: Fixture

    ## Context

    Context.

    ## Decision

    ### Rule 1: One

    Statement.

    #{rule_regions}

    ## Consequences

    Consequences.
    """
  end

  defp body_with_rule_heading(rule_heading, group_heading \\ nil) do
    group = if group_heading, do: group_heading <> "\n\n", else: ""

    """
    # ADR-001: Fixture

    ## Context

    Context.

    ## Decision

    #{group}#{rule_heading}

    Statement.

    **Correct:** good

    **Wrong:** bad

    **Why:** reason

    ## Consequences

    Consequences.
    """
  end

  defp rule_block(rule_heading) do
    """
    #{rule_heading}

    Statement.

    **Correct:** good

    **Wrong:** bad

    **Why:** reason
    """
  end

  defp line_of(content, text) do
    content
    |> String.split("\n", trim: false)
    |> Enum.find_index(&(&1 == text))
    |> Kernel.+(1)
  end
end
