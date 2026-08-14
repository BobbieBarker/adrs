defmodule AdrDist.CorpusTest do
  use ExUnit.Case, async: false

  alias AdrDist.Build
  alias AdrDist.TestSupport

  @expected %{
    "elixir-code-anti-patterns" => %{adrs: 10, rules: 16, examples: 32, supporting: 0},
    "elixir-conventions" => %{adrs: 8, rules: 30, examples: 60, supporting: 0},
    "elixir-design-anti-patterns" => %{adrs: 6, rules: 11, examples: 22, supporting: 0},
    "elixir-ecto" => %{adrs: 1, rules: 1, examples: 2, supporting: 0},
    "elixir-macro-anti-patterns" => %{adrs: 5, rules: 7, examples: 14, supporting: 0},
    "elixir-otp" => %{adrs: 13, rules: 46, examples: 92, supporting: 2},
    "elixir-resilience" => %{adrs: 1, rules: 2, examples: 4, supporting: 0}
  }

  test "the complete corpus has stable counts, relationships, and content invariants" do
    output_root = TestSupport.temporary_directory!("adr-dist-corpus")
    on_exit(fn -> File.rm_rf!(output_root) end)

    assert {:ok, _summary} =
             Build.build(Path.join(TestSupport.repo_root(), "adrs"), output_root)

    records_by_domain =
      Map.new(@expected, fn {domain, _counts} ->
        path = Path.join([output_root, domain, "retrieval.jsonl"])
        assert File.regular?(path)
        {domain, TestSupport.jsonl!(path)}
      end)

    Enum.each(@expected, fn {domain, expected} ->
      records = Map.fetch!(records_by_domain, domain)
      frequencies = Enum.frequencies_by(records, & &1["record_kind"])

      assert frequencies["adr_summary"] == expected.adrs
      assert frequencies["rule"] == expected.rules
      assert frequencies["example"] == expected.examples
      assert Map.get(frequencies, "supporting", 0) == expected.supporting

      legacy = TestSupport.jsonl!(Path.join([output_root, domain, "adrs.jsonl"]))
      assert length(legacy) == expected.adrs
      assert Enum.all?(legacy, &(&1["domain"] == domain))

      assert length(Path.wildcard(Path.join([output_root, domain, "cursor", "adr-*.mdc"]))) ==
               expected.adrs

      assert length(
               Path.wildcard(
                 Path.join([
                   output_root,
                   domain,
                   "claude-code",
                   ".claude",
                   "rules",
                   "adr-*.md"
                 ])
               )
             ) == expected.adrs

      assert File.read!(Path.join([output_root, domain, "bundle.md"])) =~
               "Source: https://github.com/BobbieBarker/adrs"
    end)

    records = records_by_domain |> Map.values() |> List.flatten()
    assert length(records) == 385
    assert count_kind(records, "adr_summary") == 44
    assert count_kind(records, "rule") == 113
    assert count_kind(records, "example") == 226
    assert count_kind(records, "supporting") == 2

    ids = Enum.map(records, & &1["record_id"])
    assert length(ids) == MapSet.size(MapSet.new(ids))

    retrieval_texts = Enum.map(records, & &1["retrieval_text"])
    assert Enum.all?(retrieval_texts, &(String.trim(&1) != ""))
    assert length(retrieval_texts) == MapSet.size(MapSet.new(retrieval_texts))

    source_hashes = Enum.map(records, & &1["source_sha256"])
    retrieval_hashes = Enum.map(records, & &1["retrieval_sha256"])
    assert Enum.all?(source_hashes, &Regex.match?(~r/^[0-9a-f]{64}$/, &1))
    assert Enum.all?(retrieval_hashes, &Regex.match?(~r/^[0-9a-f]{64}$/, &1))

    id_set = MapSet.new(ids)

    Enum.each(records, fn record ->
      assert record["date"] =~ ~r/^\d{4}-\d{2}-\d{2}$/
      assert is_nil(record["updated"]) or record["updated"] =~ ~r/^\d{4}-\d{2}-\d{2}$/
      assert record["source_start_line"] <= record["source_end_line"]
      assert record["source_sha256"] == TestSupport.sha256(record["display_text"])
      assert record["retrieval_sha256"] == TestSupport.sha256(record["retrieval_text"])
      assert MapSet.member?(id_set, record["hydrate_id"])

      if parent_id = record["parent_id"] do
        assert MapSet.member?(id_set, parent_id)
      end

      Enum.each(record["references"], fn reference ->
        assert MapSet.member?(id_set, reference["target_id"])
        assert is_binary(reference["raw_text"])
        assert is_integer(reference["source_line"])
        assert reference["source_line"] >= record["source_start_line"]
        assert reference["source_line"] <= record["source_end_line"]
      end)
    end)

    examples = Enum.filter(records, &(&1["record_kind"] == "example"))
    assert count_polarity(examples, "positive") == 113
    assert count_polarity(examples, "negative") == 113

    Enum.each(examples, fn example ->
      assert example["parent_id"] == example["hydrate_id"]
      assert String.starts_with?(example["parent_id"], "#{example["domain"]}:adr-")
      assert example["record_id"] =~ ~r/:example:(?:correct|wrong):\d{2}$/
    end)

    rules = Enum.filter(records, &(&1["record_kind"] == "rule"))
    examples_by_rule = Enum.group_by(examples, & &1["parent_id"])

    Enum.each(rules, fn rule ->
      assert rule["hydrate_id"] == rule["record_id"]
      assert rule["display_text"] =~ "**Correct"
      assert rule["display_text"] =~ "**Wrong"
      assert rule["display_text"] =~ "**Why:**"

      Enum.each(Map.fetch!(examples_by_rule, rule["record_id"]), fn example ->
        refute String.contains?(rule["retrieval_text"], example["display_text"])
      end)
    end)

    assert Enum.map(
             Enum.filter(records, &(&1["record_kind"] == "supporting")),
             & &1["record_id"]
           ) == [
             "elixir-otp:adr-001:supporting:when-a-genserver-is-the-right-answer",
             "elixir-otp:adr-003:supporting:decision-test"
           ]

    refute Enum.any?(records, fn record ->
             record["rule_title"] in ["Universal rules", "Situational rules"]
           end)
  end

  test "two independent temporary builds are byte-identical" do
    output_a = TestSupport.temporary_directory!("adr-dist-determinism-a")
    output_b = TestSupport.temporary_directory!("adr-dist-determinism-b")

    on_exit(fn ->
      File.rm_rf!(output_a)
      File.rm_rf!(output_b)
    end)

    source_root = Path.join(TestSupport.repo_root(), "adrs")
    assert {:ok, _summary} = Build.build(source_root, output_a)
    assert {:ok, _summary} = Build.build(source_root, output_b)

    assert TestSupport.files_with_contents!(output_a) ==
             TestSupport.files_with_contents!(output_b)
  end

  defp count_kind(records, kind), do: Enum.count(records, &(&1["record_kind"] == kind))
  defp count_polarity(records, polarity), do: Enum.count(records, &(&1["polarity"] == polarity))
end
