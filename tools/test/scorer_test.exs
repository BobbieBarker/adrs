previous_import_setting = System.get_env("SCORE_RETRIEVAL_IMPORT_ONLY")
System.put_env("SCORE_RETRIEVAL_IMPORT_ONLY", "1")
Code.require_file(Path.expand("../score_retrieval.exs", __DIR__))

if previous_import_setting do
  System.put_env("SCORE_RETRIEVAL_IMPORT_ONLY", previous_import_setting)
else
  System.delete_env("SCORE_RETRIEVAL_IMPORT_ONLY")
end

defmodule RetrievalEval.ScorerTest do
  use ExUnit.Case, async: true

  alias AdrDist.PackageValidator
  alias RetrievalEval.Scorer

  test "calculates hydrated, graded, routing, inversion, and abstention metrics" do
    query_rows = [
      query("q-exact-hit", "exact", [{"rule-a", 3}], [], false),
      query("q-answerable-abstained", "scenario", [{"rule-c", 3}], [], false),
      query("q-citation", "citation", [{"rule-d", 3}], [], false),
      query("q-hard-negative", "hard_negative", [{"rule-e", 3}], ["rule-f"], false),
      query("q-graded", "multi_rule", [{"rule-g", 3}, {"rule-h", 2}], [], false),
      query("q-no-answer-hit", "no_answer", [], [], true),
      query("q-no-answer-miss", "no_answer", [], [], true)
    ]

    result_rows = [
      result(
        "q-exact-hit",
        [
          hit("rule-a", 0.1),
          hit("example-a", 0.2),
          hit("rule-b", 0.9)
        ],
        false
      ),
      result("q-answerable-abstained", [], true),
      result("q-citation", [hit("rule-d", 0.8)], false),
      result("q-hard-negative", [hit("rule-e", 0.2), hit("rule-f", 0.9)], false),
      result("q-graded", [hit("rule-h", 0.9), hit("rule-g", 0.8)], false),
      result("q-no-answer-hit", [], true),
      result("q-no-answer-miss", [hit("rule-b", 0.5)], false)
    ]

    manifest_rows =
      Enum.map(~w(rule-a rule-b rule-c rule-d rule-e rule-f rule-g rule-h), fn record_id ->
        %{"record_id" => record_id, "hydrate_id" => record_id}
      end) ++
        [%{"record_id" => "example-a", "hydrate_id" => "rule-a"}]

    assert {:ok, report} = Scorer.score(query_rows, result_rows, manifest_rows)
    metrics = report["metrics"]

    discounted_second = 1.0 / (:math.log(3) / :math.log(2))
    graded_ndcg = (3.0 + 7.0 * discounted_second) / (7.0 + 3.0 * discounted_second)
    expected_ndcg = (discounted_second + 0.0 + 1.0 + discounted_second + graded_ndcg) / 5

    assert_in_delta metrics["recall_at_5"], 0.8, 1.0e-12
    assert_in_delta metrics["mrr"], 0.6, 1.0e-12
    assert_in_delta metrics["ndcg_at_5"], expected_ndcg, 1.0e-12
    assert_in_delta metrics["citation_top1"], 1.0, 1.0e-12
    assert_in_delta metrics["hard_negative_inversion"], 1.0, 1.0e-12
    assert_in_delta metrics["abstention_precision"], 0.5, 1.0e-12
    assert_in_delta metrics["abstention_recall"], 0.5, 1.0e-12
  end

  test "rejects duplicate result rows with an actionable error" do
    queries = [query("q", "exact", [{"rule-a", 3}], [], false)]
    results = [result("q", [hit("rule-a", 1.0)], false), result("q", [], false)]
    manifest = [%{"record_id" => "rule-a", "hydrate_id" => "rule-a"}]

    assert {:error, errors} = Scorer.score(queries, results, manifest)
    assert inspect(errors) =~ "duplicate"
  end

  test "rejects result hits without a finite numeric score" do
    queries = [query("q", "exact", [{"rule-a", 3}], [], false)]
    manifest = [%{"record_id" => "rule-a", "hydrate_id" => "rule-a"}]

    malformed_hits = [
      %{"record_id" => "rule-a"},
      %{"record_id" => "rule-a", "score" => "0.9"},
      %{"score" => 0.9},
      "rule-a"
    ]

    Enum.each(malformed_hits, fn malformed_hit ->
      results = [result("q", [malformed_hit], false)]

      assert {:error, errors} = Scorer.score(queries, results, manifest)
      assert inspect(errors) =~ "finite numeric score"
    end)
  end

  test "counts ADR-level hard negatives and pins every required confusion pair" do
    required_pairs = required_hard_negative_pairs()

    eleven_pairs =
      Enum.flat_map(required_pairs, &hard_negative_pair/1) ++
        Enum.flat_map(1..4, &hard_negative_pair/1)

    duplicate_rules_same_adrs = [
      hard_negative_row("synthetic:adr-001:rule-02", "synthetic:adr-002:rule-03"),
      hard_negative_row("synthetic:adr-002:rule-03", "synthetic:adr-001:rule-02")
    ]

    errors =
      PackageValidator.validate_hard_negative_adr_pair_coverage(
        eleven_pairs ++ duplicate_rules_same_adrs
      )

    assert Enum.any?(errors, &(&1 =~ "expected at least 12 distinct cross-ADR"))
    assert Enum.any?(errors, &(&1 =~ "found 11"))
    refute Enum.any?(errors, &(&1 =~ "missing required"))

    assert [] ==
             PackageValidator.validate_hard_negative_adr_pair_coverage(
               Enum.flat_map(required_pairs, &hard_negative_pair/1) ++
                 Enum.flat_map(1..5, &hard_negative_pair/1)
             )

    required_without_ecto =
      Enum.reject(required_pairs, fn {_left, right} ->
        right == "elixir-ecto:adr-001"
      end)

    errors =
      PackageValidator.validate_hard_negative_adr_pair_coverage(
        Enum.flat_map(required_without_ecto, &hard_negative_pair/1) ++
          Enum.flat_map(1..6, &hard_negative_pair/1)
      )

    refute Enum.any?(errors, &(&1 =~ "expected at least 12"))

    assert Enum.any?(errors, fn error ->
             error =~ "missing required hard-negative ADR pair" and
               error =~ "elixir-conventions:adr-007 / elixir-ecto:adr-001"
           end)
  end

  defp query(id, class, relevance, hard_negatives, should_abstain) do
    %{
      "schema_version" => "1.0",
      "query_id" => id,
      "query" => "Synthetic #{id}",
      "query_class" => class,
      "scope_domains" => ["synthetic"],
      "relevance" =>
        Enum.map(relevance, fn {record_id, grade} ->
          %{"record_id" => record_id, "grade" => grade}
        end),
      "hard_negative_ids" => hard_negatives,
      "should_abstain" => should_abstain,
      "review_notes" => "Fixed synthetic judgment."
    }
  end

  defp result(query_id, results, abstained) do
    %{"query_id" => query_id, "results" => results, "abstained" => abstained}
  end

  defp hit(record_id, score), do: %{"record_id" => record_id, "score" => score}

  defp hard_negative_pair(index) when is_integer(index) do
    left = "synthetic:adr-#{pad_adr(index * 2 - 1)}:rule-01"
    right = "synthetic:adr-#{pad_adr(index * 2)}:rule-01"

    [hard_negative_row(left, right), hard_negative_row(right, left)]
  end

  defp hard_negative_pair({left_adr, right_adr}) do
    left = "#{left_adr}:rule-01"
    right = "#{right_adr}:rule-01"

    [hard_negative_row(left, right), hard_negative_row(right, left)]
  end

  defp required_hard_negative_pairs do
    [
      {"elixir-code-anti-patterns:adr-002", "elixir-conventions:adr-005"},
      {"elixir-conventions:adr-005", "elixir-conventions:adr-007"},
      {"elixir-otp:adr-004", "elixir-otp:adr-005"},
      {"elixir-conventions:adr-004", "elixir-otp:adr-012"},
      {"elixir-conventions:adr-007", "elixir-ecto:adr-001"},
      {"elixir-conventions:adr-008", "elixir-design-anti-patterns:adr-001"},
      {"elixir-code-anti-patterns:adr-010", "elixir-otp:adr-012"}
    ]
  end

  defp hard_negative_row(primary, negative) do
    %{
      "query_class" => "hard_negative",
      "relevance" => [%{"record_id" => primary, "grade" => 3}],
      "hard_negative_ids" => [negative]
    }
  end

  defp pad_adr(value), do: value |> Integer.to_string() |> String.pad_leading(3, "0")
end
