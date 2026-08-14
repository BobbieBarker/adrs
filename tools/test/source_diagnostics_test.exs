defmodule AdrDist.SourceDiagnosticsTest do
  use ExUnit.Case, async: false

  alias AdrDist.{Build, Error}
  alias AdrDist.TestSupport

  test "build errors retain absolute source lines for structural Markdown failures" do
    cases = [
      %{
        name: "unclosed-fence",
        regions: """
        **Correct:**

        ```elixir
        :ok
        """,
        marker: "```elixir",
        occurrence: 1,
        message: "unclosed fenced code block"
      },
      %{
        name: "duplicate-label",
        regions: """
        **Correct:** first

        **Correct:** second

        **Wrong:** bad

        **Why:** reason
        """,
        marker: "**Correct:** second",
        occurrence: 1,
        message: "duplicate correct section"
      },
      %{
        name: "missing-label",
        regions: """
        **Correct:** good
        """,
        marker: "### Rule 1: Preserve evidence",
        occurrence: 1,
        message: "expected exactly one Correct, Wrong, and Why section"
      },
      %{
        name: "out-of-order-label",
        regions: """
        **Wrong:** bad

        **Correct:** good

        **Why:** reason
        """,
        marker: "**Wrong:** bad",
        occurrence: 1,
        message: "wrong section is out of order"
      }
    ]

    Enum.each(cases, fn diagnostic_case ->
      fixture_root = TestSupport.temporary_directory!("adr-source-#{diagnostic_case.name}")
      on_exit(fn -> File.rm_rf!(fixture_root) end)

      source_root = Path.join(fixture_root, "adrs")
      output_root = Path.join(fixture_root, "dist")
      source = fixture_source(diagnostic_case.regions)
      source_path = write_fixture!(source_root, source)
      expected_line = line_of(source, diagnostic_case.marker, diagnostic_case.occurrence)

      assert {:error,
              %Error{
                code: :invalid_markdown,
                path: ^source_path,
                line: ^expected_line,
                message: message
              } = error} = Build.build(source_root, output_root)

      assert message =~ diagnostic_case.message
      assert Error.format(error) =~ "#{source_path}:#{expected_line}:"
      refute File.exists?(output_root)
    end)
  end

  test "malformed manifest YAML reports its exact path and line without replacing dist" do
    fixture_root = TestSupport.temporary_directory!("adr-source-manifest-yaml")
    on_exit(fn -> File.rm_rf!(fixture_root) end)

    source_root = Path.join(fixture_root, "adrs")
    output_root = Path.join(fixture_root, "dist")
    domain_root = Path.join(source_root, "elixir-fixture")
    File.mkdir_p!(domain_root)

    manifest =
      fixture_manifest()
      |> String.replace("title: Source diagnostics", "title: *undefined")

    manifest_path = Path.join(domain_root, "adr-rules.yaml")
    File.write!(manifest_path, manifest)
    File.write!(Path.join(domain_root, "adr-001-source-diagnostic.md"), valid_fixture_source())

    before_failure = seed_existing_dist!(output_root)
    expected_line = line_of(manifest, "title: *undefined", 1)

    assert {:error,
            %Error{
              code: :invalid_manifest,
              path: ^manifest_path,
              line: ^expected_line,
              message: message
            } = error} = Build.build(source_root, output_root)

    assert message =~ "invalid manifest YAML"
    assert Error.format(error) =~ "#{manifest_path}:#{expected_line}:"
    assert TestSupport.files_with_contents!(output_root) == before_failure
  end

  test "malformed frontmatter YAML includes the opening delimiter in its line offset" do
    fixture_root = TestSupport.temporary_directory!("adr-source-frontmatter-yaml")
    on_exit(fn -> File.rm_rf!(fixture_root) end)

    source_root = Path.join(fixture_root, "adrs")
    output_root = Path.join(fixture_root, "dist")

    source =
      valid_fixture_source()
      |> String.replace("title: Source Diagnostic", "title: *undefined")

    source_path = write_fixture!(source_root, source)
    before_failure = seed_existing_dist!(output_root)
    expected_line = line_of(source, "title: *undefined", 1)

    assert {:error,
            %Error{
              code: :invalid_frontmatter,
              path: ^source_path,
              line: ^expected_line,
              message: message
            } = error} = Build.build(source_root, output_root)

    assert expected_line == 4
    assert message =~ "invalid frontmatter YAML"
    assert Error.format(error) =~ "#{source_path}:#{expected_line}:"
    assert TestSupport.files_with_contents!(output_root) == before_failure
  end

  test "reference failures retain record, source path, line, and the existing dist" do
    cases = [
      %{
        name: "malformed-reference",
        citation: "ADR-005 Rule 1a",
        code: :malformed_reference,
        message: "malformed ADR reference"
      },
      %{
        name: "unresolved-reference",
        citation: "ADR-999 Rule 1",
        code: :unresolved_reference,
        message: "unresolved ADR reference"
      }
    ]

    Enum.each(cases, fn diagnostic_case ->
      fixture_root = TestSupport.temporary_directory!("adr-source-#{diagnostic_case.name}")
      on_exit(fn -> File.rm_rf!(fixture_root) end)

      source_root = Path.join(fixture_root, "adrs")
      output_root = Path.join(fixture_root, "dist")
      sentence = "Statement citing #{diagnostic_case.citation}."

      source =
        valid_fixture_source()
        |> String.replace("Statement.", sentence)

      write_fixture!(source_root, source)
      File.mkdir_p!(output_root)
      sentinel_path = Path.join(output_root, "existing.txt")
      File.write!(sentinel_path, "untouched")

      expected_line = line_of(source, sentence, 1)
      expected_path = "adrs/elixir-fixture/adr-001-source-diagnostic.md"
      expected_record_id = "elixir-fixture:adr-001:rule-01"

      assert {:error,
              %Error{
                code: code,
                path: ^expected_path,
                line: ^expected_line,
                message: message,
                details: details
              } = error} = Build.build(source_root, output_root)

      assert code == diagnostic_case.code
      assert message =~ diagnostic_case.message
      assert details.record_id == expected_record_id
      assert Error.format(error) =~ "#{expected_path}:#{expected_line}:"
      assert File.read!(sentinel_path) == "untouched"
      assert File.ls!(output_root) == ["existing.txt"]
    end)
  end

  defp write_fixture!(source_root, source) do
    domain_root = Path.join(source_root, "elixir-fixture")
    File.mkdir_p!(domain_root)
    File.write!(Path.join(domain_root, "adr-rules.yaml"), fixture_manifest())
    source_path = Path.join(domain_root, "adr-001-source-diagnostic.md")
    File.write!(source_path, source)
    source_path
  end

  defp seed_existing_dist!(output_root) do
    existing_path = Path.join([output_root, "nested", "existing.txt"])
    File.mkdir_p!(Path.dirname(existing_path))
    File.write!(existing_path, "untouched")
    TestSupport.files_with_contents!(output_root)
  end

  defp fixture_manifest do
    """
    domain: elixir-fixture
    title: Source diagnostics
    description: Exercises source-aware parser diagnostics.

    adrs:
      - id: 1
        file: adr-001-source-diagnostic.md
        title: Diagnose malformed source
        description: Find malformed structural Markdown.
        applies_to: {}
    """
  end

  defp fixture_source(regions) do
    """
    ---
    type: adr
    id: 1
    title: Source Diagnostic
    status: accepted
    date: 2026-01-02
    tags: [elixir, fixture]
    description: Source-aware diagnostic fixture.
    ---

    # ADR-001: Source Diagnostic

    ## Context

    Fixture context.

    ## Decision

    ### Rule 1: Preserve evidence

    Statement.

    #{regions}

    ## Consequences

    Fixture consequence.
    """
  end

  defp valid_fixture_source do
    fixture_source("""
    **Correct:** good

    **Wrong:** bad

    **Why:** reason
    """)
  end

  defp line_of(content, marker, occurrence) do
    content
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_number} -> line == marker end)
    |> Enum.at(occurrence - 1)
    |> elem(1)
  end
end
