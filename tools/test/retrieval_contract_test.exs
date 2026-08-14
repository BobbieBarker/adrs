defmodule AdrDist.RetrievalContractTest do
  use ExUnit.Case, async: false

  alias AdrDist.{Build, Error, Retrieval, Source, Validator}
  alias AdrDist.TestSupport

  @required_fields ~w(
    schema_version record_id record_kind parent_id hydrate_id ordinal domain adr_id
    rule_number polarity adr_title routing_title rule_title heading_path status date
    updated tags source_description routing_description applies_to source_path
    source_start_line source_end_line languages source_sha256 retrieval_sha256
    references retrieval_text display_text
  )

  setup do
    fixture_root = TestSupport.temporary_directory!("adr-dist-contract")
    source_root = Path.join(fixture_root, "adrs")
    output_root = Path.join(fixture_root, "dist")
    source = fixture_source()

    domain_root = Path.join(source_root, "elixir-fixture")
    File.mkdir_p!(domain_root)
    File.write!(Path.join(domain_root, "adr-rules.yaml"), fixture_manifest())
    File.write!(Path.join(domain_root, "adr-001-canonical-fixture.md"), source)

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    %{
      fixture_root: fixture_root,
      source_root: source_root,
      output_root: output_root,
      source: source
    }
  end

  test "emits the exact v1 hierarchy, identities, payloads, and source evidence", context do
    assert {:ok, _summary} = Build.build(context.source_root, context.output_root)

    records =
      TestSupport.jsonl!(Path.join([context.output_root, "elixir-fixture", "retrieval.jsonl"]))

    assert Enum.map(records, & &1["record_kind"]) == [
             "adr_summary",
             "supporting",
             "rule",
             "example",
             "example"
           ]

    assert Enum.map(records, & &1["ordinal"]) == [1, 2, 3, 4, 5]

    assert Enum.map(records, & &1["record_id"]) == [
             "elixir-fixture:adr-001",
             "elixir-fixture:adr-001:supporting:decision-test",
             "elixir-fixture:adr-001:rule-01",
             "elixir-fixture:adr-001:rule-01:example:correct:01",
             "elixir-fixture:adr-001:rule-01:example:wrong:01"
           ]

    Enum.each(records, fn record ->
      assert @required_fields -- Map.keys(record) == []
      assert record["schema_version"] == "retrieval-v1"
      assert record["domain"] == "elixir-fixture"
      assert record["adr_id"] == 1
      assert record["adr_title"] == "Canonical Fixture"
      assert record["routing_title"] == "Find canonical fixture guidance"
      assert record["source_description"] == "Canonical human description."
      assert record["routing_description"] == "Query-shaped routing description."
      assert record["status"] == "accepted"
      assert record["date"] == "2026-01-02"
      assert is_nil(record["updated"])
      assert record["tags"] == ["elixir", "fixture"]
      assert record["applies_to"] == %{"content_match" => ["fixture_call"]}
      assert record["source_path"] == "adrs/elixir-fixture/adr-001-canonical-fixture.md"
      assert is_integer(record["source_start_line"])
      assert record["source_start_line"] >= 1
      assert record["source_end_line"] >= record["source_start_line"]
      assert record["source_sha256"] == TestSupport.sha256(record["display_text"])
      assert record["retrieval_sha256"] == TestSupport.sha256(record["retrieval_text"])
      assert String.trim(record["retrieval_text"]) != ""
      assert is_list(record["references"])
    end)

    [summary, supporting, rule, correct, wrong] = records

    assert is_nil(summary["parent_id"])
    assert summary["hydrate_id"] == summary["record_id"]
    assert is_nil(summary["rule_number"])
    assert is_nil(summary["rule_title"])
    assert is_nil(summary["polarity"])
    assert summary["context"] == "Fixture context."
    assert summary["decision"] == "Direct decision prose."
    refute summary["decision"] =~ "def correct"
    assert summary["consequences"] == "Fixture consequence."
    refute summary["context"] =~ "## Context"
    refute summary["decision"] =~ "## Decision"
    refute summary["consequences"] =~ "## Consequences"
    assert summary["retrieval_text"] =~ "Preserve complete examples"
    assert summary["retrieval_text"] =~ "Query-shaped routing description."

    assert supporting["parent_id"] == summary["record_id"]
    assert supporting["hydrate_id"] == supporting["record_id"]
    assert supporting["heading_path"] == ["Decision", "Decision test"]
    assert supporting["display_text"] =~ "### Decision test"
    assert supporting["display_text"] =~ "Ask whether the decision applies."

    assert rule["parent_id"] == summary["record_id"]
    assert rule["hydrate_id"] == rule["record_id"]
    assert rule["rule_number"] == 1
    assert rule["rule_title"] == "Preserve complete examples"
    assert "Universal rules" in rule["heading_path"]
    assert rule["display_text"] =~ "**Correct (staged excerpt):**"
    assert rule["display_text"] =~ "def correct"
    assert rule["display_text"] =~ "**Wrong:**"
    assert rule["display_text"] =~ "def wrong"
    assert rule["display_text"] =~ "**Why:** Complete regions retain their evidence."
    assert rule["retrieval_text"] =~ "Keep the prescription text searchable."
    assert rule["retrieval_text"] =~ "Complete regions retain their evidence."
    refute rule["retrieval_text"] =~ "def correct"
    refute rule["retrieval_text"] =~ "def wrong"
    assert rule["languages"] == ["elixir"]

    assert correct["parent_id"] == rule["record_id"]
    assert correct["hydrate_id"] == rule["record_id"]
    assert correct["polarity"] == "positive"
    assert correct["rule_number"] == 1
    assert correct["display_text"] =~ "The two fences are one staged example."
    assert correct["display_text"] =~ "def second_stage"
    assert correct["languages"] == ["elixir"]

    assert wrong["parent_id"] == rule["record_id"]
    assert wrong["hydrate_id"] == rule["record_id"]
    assert wrong["polarity"] == "negative"
    assert wrong["display_text"] =~ "def wrong"
    assert wrong["languages"] == ["elixir"]

    source_lines = String.split(context.source, "\n", trim: false)
    assert source_slice(source_lines, correct) |> String.trim() == correct["display_text"]
    assert source_slice(source_lines, wrong) |> String.trim() == wrong["display_text"]

    correct_label_line =
      Enum.find_index(source_lines, &(&1 == "**Correct (staged excerpt):**")) + 1

    wrong_label_line = Enum.find_index(source_lines, &(&1 == "**Wrong:**")) + 1

    assert correct["source_start_line"] == correct_label_line
    assert wrong["source_start_line"] == wrong_label_line
  end

  test "omits an empty direct Decision body while preserving routing and reference lines",
       context do
    source =
      context.source
      |> String.replace("\nDirect decision prose.\n", "\n")
      |> String.replace("Fixture context.", "Fixture context. Apply ADR-001 Rule 1.")

    source_path =
      Path.join([
        context.source_root,
        "elixir-fixture",
        "adr-001-canonical-fixture.md"
      ])

    File.write!(source_path, source)
    assert {:ok, _summary} = Build.build(context.source_root, context.output_root)

    [summary | _children] =
      TestSupport.jsonl!(Path.join([context.output_root, "elixir-fixture", "retrieval.jsonl"]))

    assert summary["decision"] == ""
    refute summary["display_text"] =~ "## Decision"
    refute summary["retrieval_text"] =~ "## Decision"
    assert summary["retrieval_text"] =~ "#### Rule 1: Preserve complete examples"

    assert [reference] = summary["references"]
    assert reference["target_id"] == "elixir-fixture:adr-001:rule-01"
    assert reference["raw_text"] == "ADR-001 Rule 1"

    expected_line =
      source
      |> String.split("\n", trim: false)
      |> Enum.find_index(&String.contains?(&1, "Apply ADR-001 Rule 1."))
      |> Kernel.+(1)

    assert reference["source_line"] == expected_line
    assert summary["source_sha256"] == TestSupport.sha256(summary["display_text"])
    assert summary["retrieval_sha256"] == TestSupport.sha256(summary["retrieval_text"])
  end

  test "retains the legacy one-ADR-per-row interface without field changes", context do
    assert {:ok, _summary} = Build.build(context.source_root, context.output_root)

    assert [legacy] =
             TestSupport.jsonl!(Path.join([context.output_root, "elixir-fixture", "adrs.jsonl"]))

    assert Map.keys(legacy) |> Enum.sort() ==
             ~w(applies_to body description domain id tags title) |> Enum.sort()

    assert legacy["id"] == 1
    assert legacy["domain"] == "elixir-fixture"
    assert legacy["title"] == "Find canonical fixture guidance"
    assert legacy["description"] == "Query-shaped routing description."
    assert legacy["body"] =~ "# ADR-001: Canonical Fixture"
  end

  test "validation rejects duplicate IDs, invalid hashes, empty payloads, and invalid references",
       context do
    assert {:ok, _summary} = Build.build(context.source_root, context.output_root)

    records =
      TestSupport.jsonl!(Path.join([context.output_root, "elixir-fixture", "retrieval.jsonl"]))

    assert {:error, duplicate_errors} = Retrieval.validate(records ++ [hd(records)])
    assert inspect(duplicate_errors) =~ "duplicate"

    [first | rest] = records

    assert {:ok, _records} = Retrieval.validate([Map.put(first, "decision", "") | rest])

    assert {:error, missing_section_errors} =
             Retrieval.validate([Map.delete(first, "decision") | rest])

    assert inspect(missing_section_errors) =~ "sections must be present"

    assert {:error, section_type_errors} =
             Retrieval.validate([Map.put(first, "decision", nil) | rest])

    assert inspect(section_type_errors) =~ "sections must be strings"

    assert {:error, empty_context_errors} =
             Retrieval.validate([Map.put(first, "context", "") | rest])

    assert inspect(empty_context_errors) =~ "context must not be empty"

    assert {:error, empty_consequences_errors} =
             Retrieval.validate([Map.put(first, "consequences", "") | rest])

    assert inspect(empty_consequences_errors) =~ "consequences must not be empty"

    assert {:error, hash_errors} =
             Retrieval.validate([
               Map.put(first, "retrieval_sha256", String.duplicate("0", 64)) | rest
             ])

    assert inspect(hash_errors) =~ "retrieval_sha256"

    assert {:error, text_errors} =
             Retrieval.validate([
               first
               |> Map.put("retrieval_text", "")
               |> Map.put("retrieval_sha256", TestSupport.sha256(""))
               | rest
             ])

    assert inspect(text_errors) =~ "retrieval_text"

    assert {:error, display_errors} =
             Retrieval.validate([
               first
               |> Map.put("display_text", "")
               |> Map.put("source_sha256", TestSupport.sha256(""))
               | rest
             ])

    assert inspect(display_errors) =~ "display_text"

    rule = Enum.find(records, &(&1["record_kind"] == "rule"))
    example = Enum.find(records, &(&1["record_kind"] == "example"))

    invalid_example_id_records =
      Enum.map(records, fn record ->
        if record["record_id"] == example["record_id"] do
          Map.update!(record, "record_id", &String.replace_suffix(&1, ":01", ":02"))
        else
          record
        end
      end)

    assert {:error, example_id_errors} = Retrieval.validate(invalid_example_id_records)
    assert inspect(example_id_errors) =~ "example record_id"

    invalid_reference = %{
      "target_id" => example["record_id"],
      "raw_text" => "Rule 1",
      "source_line" => rule["source_start_line"]
    }

    invalid_reference_records =
      Enum.map(records, fn record ->
        if record["record_id"] == rule["record_id"] do
          Map.put(record, "references", [invalid_reference])
        else
          record
        end
      end)

    assert {:error, reference_errors} = Retrieval.validate(invalid_reference_records)
    assert inspect(reference_errors) =~ "ADR summary or Rule"

    [second | remaining] = rest

    duplicated_payload =
      second
      |> Map.put("retrieval_text", first["retrieval_text"])
      |> Map.put("retrieval_sha256", first["retrieval_sha256"])

    assert {:error, duplicate_text_errors} =
             Retrieval.validate([first, duplicated_payload | remaining])

    assert inspect(duplicate_text_errors) =~ "duplicate retrieval_text"
  end

  test "staged validation rejects malformed or drifted legacy rows", context do
    assert {:ok, _summary} = Build.build(context.source_root, context.output_root)
    assert {:ok, domains} = Source.load(context.source_root)

    retrieval_path =
      Path.join([context.output_root, "elixir-fixture", "retrieval.jsonl"])

    records = TestSupport.jsonl!(retrieval_path)
    legacy_path = Path.join([context.output_root, "elixir-fixture", "adrs.jsonl"])
    output_root = context.output_root
    assert [legacy] = TestSupport.jsonl!(legacy_path)

    variants = [
      {"unexpected field", [Map.put(legacy, "extra", true)], "exactly seven public fields"},
      {"missing row", [], "expected 1 rows, found 0"},
      {"drifted value", [Map.put(legacy, "title", "Drifted")], "do not match"}
    ]

    Enum.each(variants, fn {_name, rows, expected_message} ->
      write_jsonl!(legacy_path, rows)

      assert {:error,
              %Error{
                code: :legacy_validation_failed,
                path: ^output_root,
                details: details
              }} = Validator.validate_staged(context.output_root, domains, records)

      assert inspect(details) =~ expected_message
    end)

    File.write!(legacy_path, "{invalid-json}\n")

    assert {:error,
            %Error{
              code: :legacy_validation_failed,
              path: ^output_root,
              details: decode_details
            }} = Validator.validate_staged(context.output_root, domains, records)

    assert inspect(decode_details) =~ "invalid JSON"
  end

  test "rejects manifest, filename, frontmatter, and H1 identity mismatches", context do
    variants = [
      {
        "manifest",
        String.replace(fixture_manifest(), "  - id: 1", "  - id: 2"),
        "adr-001-canonical-fixture.md",
        context.source
      },
      {
        "filename",
        String.replace(
          fixture_manifest(),
          "adr-001-canonical-fixture.md",
          "adr-002-canonical-fixture.md"
        ),
        "adr-002-canonical-fixture.md",
        context.source
      },
      {
        "frontmatter",
        fixture_manifest(),
        "adr-001-canonical-fixture.md",
        String.replace(context.source, "id: 1", "id: 2", global: false)
      },
      {
        "H1",
        fixture_manifest(),
        "adr-001-canonical-fixture.md",
        String.replace(context.source, "# ADR-001:", "# ADR-002:", global: false)
      }
    ]

    Enum.each(variants, fn {label, manifest, filename, source} ->
      source_root = Path.join([context.fixture_root, "identity-#{label}", "adrs"])
      domain_root = Path.join(source_root, "elixir-fixture")
      output_root = Path.join(context.fixture_root, "identity-#{label}-dist")
      File.mkdir_p!(domain_root)
      File.write!(Path.join(domain_root, "adr-rules.yaml"), manifest)
      File.write!(Path.join(domain_root, filename), source)

      assert {:error, error} = Build.build(source_root, output_root)
      assert inspect(error) =~ ~r/mismatch|expected|invalid/i
    end)
  end

  test "a failed rebuild leaves the previous distribution byte-identical", context do
    assert {:ok, _summary} = Build.build(context.source_root, context.output_root)
    before_failure = TestSupport.files_with_contents!(context.output_root)

    source_path =
      Path.join([
        context.source_root,
        "elixir-fixture",
        "adr-001-canonical-fixture.md"
      ])

    File.write!(source_path, String.replace(context.source, "## Consequences", "## Missing"))

    assert {:error, _error} = Build.build(context.source_root, context.output_root)
    assert TestSupport.files_with_contents!(context.output_root) == before_failure
  end

  test "the public build_dist executable succeeds against an isolated corpus", context do
    executable = System.find_executable("elixir")
    script = Path.join([TestSupport.repo_root(), "tools", "build_dist.exs"])

    {output, status} =
      System.cmd(executable, [script],
        cd: context.fixture_root,
        env: [{"MIX_OS_CONCURRENCY_LOCK", System.get_env("MIX_OS_CONCURRENCY_LOCK") || "1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert File.regular?(
             Path.join([
               context.fixture_root,
               "dist",
               "elixir-fixture",
               "retrieval.jsonl"
             ])
           )
  end

  defp source_slice(lines, record) do
    lines
    |> Enum.slice((record["source_start_line"] - 1)..(record["source_end_line"] - 1))
    |> Enum.join("\n")
  end

  defp write_jsonl!(path, rows) do
    contents = Enum.map_join(rows, "\n", &Jason.encode!/1)
    File.write!(path, contents <> if(contents == "", do: "", else: "\n"))
  end

  defp fixture_manifest do
    """
    domain: elixir-fixture
    title: Fixture routing collection
    description: Fixture manifest.

    adrs:
      - id: 1
        file: adr-001-canonical-fixture.md
        title: Find canonical fixture guidance
        description: Query-shaped routing description.
        applies_to:
          content_match:
            - fixture_call
    """
  end

  defp fixture_source do
    """
    ---
    type: adr
    id: 1
    title: Canonical Fixture
    status: accepted
    date: 2026-01-02
    tags: [elixir, fixture]
    description: Canonical human description.
    ---

    # ADR-001: Canonical Fixture

    ## Context

    Fixture context.

    ## Decision

    Direct decision prose.

    ### Decision test

    Ask whether the decision applies.

    ### Universal rules

    #### Rule 1: Preserve complete examples

    Keep the prescription text searchable.

    **Correct (staged excerpt):**

    ````elixir
    def correct, do: :ok
    ````

    The two fences are one staged example.

    ~~~~elixir
    def second_stage, do: :ok
    ~~~~

    **Wrong:**

    ```elixir
    def wrong, do: :error
    ```

    **Why:** Complete regions retain their evidence.

    ## Consequences

    Fixture consequence.
    """
  end
end
