#!/usr/bin/env elixir

unless Code.ensure_loaded?(Jason) do
  Mix.install([{:jason, "~> 1.4"}])
end

defmodule RetrievalEval.JSON do
  @moduledoc false

  @spec decode(String.t()) :: {:ok, map() | list()} | {:error, term()}
  def decode(value) when is_binary(value) do
    Jason.decode(value)
  end

  @spec encode(term()) :: String.t()
  def encode(value), do: Jason.encode!(value)
end

defmodule RetrievalEval.Loader do
  @moduledoc "Loads the versioned evaluation, retrieval-result, and retrieval-manifest formats."

  alias RetrievalEval.JSON

  @spec load_queries(Path.t()) :: {:ok, [map()]} | {:error, [String.t()]}
  def load_queries(path), do: load_jsonl_collection(path, "queries.jsonl")

  @spec load_results(Path.t()) :: {:ok, [map()]} | {:error, [String.t()]}
  def load_results(path), do: load_jsonl_collection(path, nil)

  @spec load_manifest(Path.t()) :: {:ok, [map()]} | {:error, [String.t()]}
  def load_manifest(path) do
    cond do
      File.dir?(path) ->
        load_manifest_directory(path)

      File.regular?(path) and Path.extname(path) == ".jsonl" ->
        load_jsonl_files([path])

      File.regular?(path) and Path.extname(path) == ".json" ->
        load_manifest_catalog(path)

      true ->
        {:error, ["manifest path does not exist or is unsupported: #{path}"]}
    end
  end

  defp load_manifest_directory(path) do
    files = Path.wildcard(Path.join([path, "**", "retrieval.jsonl"])) |> Enum.sort()

    case files do
      [] -> {:error, ["no retrieval.jsonl manifests found below #{path}"]}
      _ -> load_jsonl_files(files)
    end
  end

  defp load_manifest_catalog(path) do
    case File.read(path) do
      {:ok, body} -> decode_manifest_catalog(path, body)
      {:error, reason} -> {:error, ["could not read #{path}: #{inspect(reason)}"]}
    end
  end

  defp decode_manifest_catalog(path, body) do
    case JSON.decode(body) do
      {:ok, catalog} ->
        files =
          catalog
          |> collect_jsonl_paths()
          |> Enum.map(&resolve_catalog_path(path, &1))
          |> Enum.uniq()
          |> Enum.sort()

        case files do
          [] -> {:error, ["catalog #{path} does not reference retrieval JSONL files"]}
          _ -> load_jsonl_files(files)
        end

      {:error, reason} ->
        {:error, ["invalid JSON in #{path}: #{Exception.message(reason)}"]}
    end
  end

  defp collect_jsonl_paths(value) when is_binary(value) do
    if String.ends_with?(value, "retrieval.jsonl"), do: [value], else: []
  end

  defp collect_jsonl_paths(value) when is_list(value),
    do: Enum.flat_map(value, &collect_jsonl_paths/1)

  defp collect_jsonl_paths(value) when is_map(value) do
    value |> Map.values() |> Enum.flat_map(&collect_jsonl_paths/1)
  end

  defp collect_jsonl_paths(_value), do: []

  defp resolve_catalog_path(catalog_path, referenced_path) do
    cwd_path = Path.expand(referenced_path)
    catalog_relative = Path.expand(referenced_path, Path.dirname(catalog_path))

    cond do
      Path.type(referenced_path) == :absolute -> referenced_path
      File.exists?(cwd_path) -> cwd_path
      true -> catalog_relative
    end
  end

  defp load_jsonl_collection(path, basename) do
    cond do
      File.dir?(path) ->
        pattern =
          if basename,
            do: Path.join([path, "**", basename]),
            else: Path.join([path, "**", "*.jsonl"])

        files = Path.wildcard(pattern) |> Enum.sort()

        case files do
          [] -> {:error, ["no JSONL files found below #{path}"]}
          _ -> load_jsonl_files(files)
        end

      File.regular?(path) ->
        load_jsonl_files([path])

      true ->
        {:error, ["path does not exist: #{path}"]}
    end
  end

  defp load_jsonl_files(files) do
    {rows, errors} =
      Enum.reduce(files, {[], []}, fn file, {rows, errors} ->
        case load_jsonl_file(file) do
          {:ok, file_rows} -> {rows ++ file_rows, errors}
          {:error, file_errors} -> {rows, errors ++ file_errors}
        end
      end)

    case errors do
      [] -> {:ok, rows}
      _ -> {:error, errors}
    end
  end

  defp load_jsonl_file(path) do
    case File.read(path) do
      {:ok, body} -> decode_jsonl(path, body)
      {:error, reason} -> {:error, ["could not read #{path}: #{inspect(reason)}"]}
    end
  end

  defp decode_jsonl(path, body) do
    {rows, errors} =
      body
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {line, line_number}, {rows, errors} ->
        if String.trim(line) == "" do
          {rows, errors}
        else
          decode_jsonl_line(path, line_number, line, rows, errors)
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(rows)}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp decode_jsonl_line(path, line_number, line, rows, errors) do
    case JSON.decode(line) do
      {:ok, row} when is_map(row) ->
        {[row | rows], errors}

      {:ok, _other} ->
        {rows, ["#{path}:#{line_number}: expected a JSON object" | errors]}

      {:error, reason} ->
        {rows, ["#{path}:#{line_number}: invalid JSON: #{Exception.message(reason)}" | errors]}
    end
  end
end

defmodule RetrievalEval.Scorer do
  @moduledoc "Scores ranked retrieval results against the ADR evaluation-query contract."

  @query_classes ~w(exact scenario code hard_negative multi_rule no_answer citation)

  @typedoc "A decoded evaluation query, result row, or retrieval-manifest row."
  @type row :: %{optional(String.t()) => term()}

  @spec score([row()], [row()], [row()]) :: {:ok, map()} | {:error, [String.t()]}
  def score(query_rows, result_rows, manifest_rows)
      when is_list(query_rows) and is_list(result_rows) and is_list(manifest_rows) do
    errors = validate_queries(query_rows) ++ validate_results(result_rows)

    case errors do
      [] -> {:ok, compute_metrics(query_rows, result_rows, manifest_rows)}
      _ -> {:error, errors}
    end
  end

  @spec hydrate_ranked_ids([term()], [row()]) :: [String.t()]
  def hydrate_ranked_ids(results, manifest_rows)
      when is_list(results) and is_list(manifest_rows) do
    aliases = manifest_aliases(manifest_rows)

    results
    |> Enum.map(&result_record_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&canonical_rule_id(&1, aliases))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec validate_queries([row()]) :: [String.t()]
  def validate_queries(rows) do
    duplicate_errors(rows, "query_id", "query") ++ Enum.flat_map(rows, &validate_query/1)
  end

  @spec validate_results([row()]) :: [String.t()]
  def validate_results(rows) do
    duplicate_errors(rows, "query_id", "result") ++ Enum.flat_map(rows, &validate_result/1)
  end

  defp validate_query(row) do
    id = Map.get(row, "query_id", "<missing query_id>")

    []
    |> require_string(row, "schema_version", id)
    |> require_string(row, "query_id", id)
    |> require_string(row, "query", id)
    |> require_enum(row, "query_class", @query_classes, id)
    |> require_string_list(row, "scope_domains", id, false)
    |> require_relevance(row, id)
    |> require_string_list(row, "hard_negative_ids", id, true)
    |> require_boolean(row, "should_abstain", id)
    |> require_string(row, "review_notes", id)
    |> validate_answerability(row, id)
  end

  defp validate_result(row) do
    id = Map.get(row, "query_id", "<missing query_id>")
    errors = [] |> require_string(row, "query_id", id) |> require_boolean(row, "abstained", id)

    case ranked_results(row) do
      results when is_list(results) ->
        if Enum.all?(results, &valid_result?/1),
          do: errors,
          else: [
            "#{id}: every result must be an object with a non-empty record_id and finite numeric score"
            | errors
          ]

      _ ->
        ["#{id}: results must be a list" | errors]
    end
  end

  defp validate_answerability(errors, row, id) do
    relevance = Map.get(row, "relevance", [])
    should_abstain = Map.get(row, "should_abstain")

    cond do
      should_abstain == true and relevance != [] ->
        ["#{id}: abstention query must have empty relevance" | errors]

      should_abstain == false and relevance == [] ->
        ["#{id}: answerable query must have at least one relevance judgment" | errors]

      true ->
        errors
    end
  end

  defp require_relevance(errors, row, id) do
    case Map.get(row, "relevance") do
      values when is_list(values) ->
        if Enum.all?(values, &valid_relevance?/1),
          do: errors,
          else: ["#{id}: relevance entries require record_id and grade 1..3" | errors]

      _ ->
        ["#{id}: relevance must be a list" | errors]
    end
  end

  defp valid_relevance?(%{"record_id" => id, "grade" => grade}) do
    is_binary(id) and id != "" and is_integer(grade) and grade in 1..3
  end

  defp valid_relevance?(_value), do: false

  defp require_string(errors, row, field, id) do
    case Map.get(row, field) do
      value when is_binary(value) and value != "" -> errors
      _ -> ["#{id}: #{field} must be a non-empty string" | errors]
    end
  end

  defp require_boolean(errors, row, field, id) do
    if is_boolean(Map.get(row, field)),
      do: errors,
      else: ["#{id}: #{field} must be a boolean" | errors]
  end

  defp require_enum(errors, row, field, choices, id) do
    if Map.get(row, field) in choices,
      do: errors,
      else: ["#{id}: #{field} must be one of #{Enum.join(choices, ", ")}" | errors]
  end

  defp require_string_list(errors, row, field, id, allow_empty) do
    case Map.get(row, field) do
      values when is_list(values) ->
        valid = Enum.all?(values, &(is_binary(&1) and &1 != "")) and (allow_empty or values != [])

        if valid,
          do: errors,
          else: [
            "#{id}: #{field} must be #{if allow_empty, do: "a", else: "a non-empty"} string list"
            | errors
          ]

      _ ->
        ["#{id}: #{field} must be a string list" | errors]
    end
  end

  defp duplicate_errors(rows, field, kind) do
    rows
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} -> "duplicate #{kind} #{field}: #{id}" end)
  end

  defp compute_metrics(query_rows, result_rows, manifest_rows) do
    aliases = manifest_aliases(manifest_rows)
    results_by_query = Map.new(result_rows, &{Map.fetch!(&1, "query_id"), &1})

    scored =
      Enum.map(query_rows, fn query ->
        result =
          Map.get(results_by_query, query["query_id"], %{"results" => [], "abstained" => false})

        score_query(query, result, aliases)
      end)

    answerable = Enum.reject(scored, & &1.should_abstain)
    citations = Enum.filter(scored, &(&1.query_class == "citation"))
    hard_negatives = Enum.filter(scored, &(&1.query_class == "hard_negative"))

    tp = Enum.count(scored, &(&1.should_abstain and &1.abstained))
    fp = Enum.count(scored, &(not &1.should_abstain and &1.abstained))
    fn_count = Enum.count(scored, &(&1.should_abstain and not &1.abstained))

    %{
      "schema_version" => "1.0",
      "query_count" => length(query_rows),
      "result_count" => length(result_rows),
      "missing_result_count" =>
        Enum.count(query_rows, &(not Map.has_key?(results_by_query, &1["query_id"]))),
      "answerable_query_count" => length(answerable),
      "no_answer_query_count" => Enum.count(scored, & &1.should_abstain),
      "metrics" => %{
        "recall_at_5" => average(answerable, & &1.recall_at_5),
        "mrr" => average(answerable, & &1.reciprocal_rank),
        "ndcg_at_5" => average(answerable, & &1.ndcg_at_5),
        "citation_top1" => average(citations, &boolean_score(&1.citation_top1)),
        "hard_negative_inversion" =>
          average(hard_negatives, &boolean_score(&1.hard_negative_inversion)),
        "abstention_precision" => ratio(tp, tp + fp),
        "abstention_recall" => ratio(tp, tp + fn_count)
      },
      "counts" => %{
        "citation_queries" => length(citations),
        "hard_negative_queries" => length(hard_negatives),
        "abstention_true_positive" => tp,
        "abstention_false_positive" => fp,
        "abstention_false_negative" => fn_count
      }
    }
  end

  defp score_query(query, result, aliases) do
    ranked =
      if Map.get(result, "abstained", false) and not query["should_abstain"] do
        []
      else
        result |> ranked_results() |> hydrate_with_aliases(aliases)
      end

    relevance =
      query["relevance"]
      |> Enum.map(fn judgment ->
        {canonical_rule_id(judgment["record_id"], aliases), judgment["grade"]}
      end)
      |> Enum.reject(fn {id, _grade} -> is_nil(id) end)
      |> Map.new()

    hard_negatives =
      query["hard_negative_ids"]
      |> Enum.map(&canonical_rule_id(&1, aliases))
      |> Enum.reject(&is_nil/1)

    relevant_ids = Map.keys(relevance)

    primary_ids =
      relevance |> Enum.filter(fn {_id, grade} -> grade == 3 end) |> Enum.map(&elem(&1, 0))

    top_five = Enum.take(ranked, 5)
    first_relevant_rank = first_rank(ranked, relevant_ids)
    first_negative_rank = first_rank(ranked, hard_negatives)

    %{
      query_class: query["query_class"],
      should_abstain: query["should_abstain"],
      abstained: Map.get(result, "abstained", false),
      recall_at_5: recall(top_five, primary_ids),
      reciprocal_rank: reciprocal_rank(first_relevant_rank),
      ndcg_at_5: ndcg(top_five, relevance, 5),
      citation_top1: citation_top1?(query["query_class"], ranked, relevant_ids),
      hard_negative_inversion: inversion?(first_relevant_rank, first_negative_rank)
    }
  end

  defp manifest_aliases(rows) do
    Enum.reduce(rows, %{}, fn row, aliases ->
      record_id = Map.get(row, "record_id") || Map.get(row, "id")
      kind = Map.get(row, "record_kind") || Map.get(row, "kind")

      rule_id =
        Map.get(row, "hydrate_id") ||
          case kind do
            "rule" -> Map.get(row, "rule_id") || record_id
            "example" -> Map.get(row, "parent_rule_id") || Map.get(row, "rule_id")
            _ -> Map.get(row, "parent_rule_id")
          end

      if is_binary(record_id) and is_binary(rule_id) do
        aliases
        |> Map.put(record_id, normalize_rule_prefix(rule_id))
        |> Map.put(normalize_rule_prefix(record_id), normalize_rule_prefix(rule_id))
      else
        aliases
      end
    end)
  end

  defp hydrate_with_aliases(results, aliases) do
    results
    |> Enum.map(&result_record_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&canonical_rule_id(&1, aliases))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp canonical_rule_id(id, aliases) when is_binary(id) do
    normalized = normalize_rule_prefix(id)

    cond do
      Map.has_key?(aliases, id) -> aliases[id]
      Map.has_key?(aliases, normalized) -> aliases[normalized]
      true -> normalized
    end
  end

  defp canonical_rule_id(_id, _aliases), do: nil

  defp normalize_rule_prefix(id), do: String.replace_prefix(id, "rule:", "")

  defp ranked_results(row) do
    values = Map.get(row, "results")

    if is_list(values) and Enum.all?(values, &valid_result?/1) do
      Enum.sort_by(values, & &1["score"], :desc)
    else
      values
    end
  end

  defp result_record_id(value) when is_binary(value), do: value
  defp result_record_id(%{"record_id" => id}) when is_binary(id), do: id
  defp result_record_id(%{"id" => id}) when is_binary(id), do: id
  defp result_record_id(_value), do: nil

  defp valid_result?(%{"record_id" => record_id, "score" => score}) do
    is_binary(record_id) and record_id != "" and finite_number?(score)
  end

  defp valid_result?(_value), do: false

  defp finite_number?(value) when is_integer(value), do: true
  defp finite_number?(value) when is_float(value), do: value - value == 0.0
  defp finite_number?(_value), do: false

  defp recall(_retrieved, []), do: 0.0

  defp recall(retrieved, relevant),
    do: ratio(Enum.count(relevant, &(&1 in retrieved)), length(relevant))

  defp reciprocal_rank(nil), do: 0.0
  defp reciprocal_rank(rank), do: 1.0 / rank

  defp first_rank(_ranked, []), do: nil

  defp first_rank(ranked, targets) do
    ranked
    |> Enum.with_index(1)
    |> Enum.find_value(fn {id, rank} -> if id in targets, do: rank end)
  end

  defp citation_top1?("citation", [first | _], relevant), do: first in relevant
  defp citation_top1?("citation", [], _relevant), do: false
  defp citation_top1?(_class, _ranked, _relevant), do: false

  defp inversion?(_relevant_rank, nil), do: false
  defp inversion?(nil, negative_rank) when is_integer(negative_rank), do: true
  defp inversion?(relevant_rank, negative_rank), do: negative_rank < relevant_rank

  defp ndcg(ranked, relevance, cutoff) do
    actual =
      ranked
      |> Enum.take(cutoff)
      |> Enum.with_index(1)
      |> Enum.reduce(0.0, fn {id, rank}, acc ->
        acc + discounted_gain(Map.get(relevance, id, 0), rank)
      end)

    ideal =
      relevance
      |> Map.values()
      |> Enum.sort(:desc)
      |> Enum.take(cutoff)
      |> Enum.with_index(1)
      |> Enum.reduce(0.0, fn {grade, rank}, acc -> acc + discounted_gain(grade, rank) end)

    ratio(actual, ideal)
  end

  defp discounted_gain(grade, rank), do: (:math.pow(2, grade) - 1) / :math.log2(rank + 1)

  defp average([], _mapper), do: 0.0

  defp average(values, mapper),
    do: values |> Enum.map(mapper) |> Enum.sum() |> Kernel./(length(values))

  defp boolean_score(true), do: 1.0
  defp boolean_score(false), do: 0.0

  defp ratio(_numerator, denominator) when denominator == 0 or denominator == 0.0, do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator
end

defmodule RetrievalEval.CLI do
  @moduledoc false

  alias RetrievalEval.{JSON, Loader, Scorer}

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    {opts, _args, invalid} =
      OptionParser.parse(argv,
        strict: [
          queries: :string,
          results: :string,
          manifest: :string,
          format: :string,
          help: :boolean
        ]
      )

    cond do
      opts[:help] -> print_help(0)
      invalid != [] -> fail(["invalid options: #{inspect(invalid)}"])
      is_nil(opts[:results]) -> fail(["--results is required"])
      true -> run(opts)
    end
  end

  defp run(opts) do
    queries_path = opts[:queries] || "eval"
    manifest_path = opts[:manifest] || "dist"
    format = opts[:format] || "text"

    case load_inputs(queries_path, opts[:results], manifest_path) do
      {:ok, {queries, results, manifest}} -> score_and_print(queries, results, manifest, format)
      {:error, errors} -> fail(errors)
    end
  end

  defp load_inputs(queries_path, results_path, manifest_path) do
    queries = Loader.load_queries(queries_path)
    results = Loader.load_results(results_path)
    manifest = Loader.load_manifest(manifest_path)

    case {queries, results, manifest} do
      {{:ok, query_rows}, {:ok, result_rows}, {:ok, manifest_rows}} ->
        {:ok, {query_rows, result_rows, manifest_rows}}

      _ ->
        errors = Enum.flat_map([queries, results, manifest], &load_errors/1)
        {:error, errors}
    end
  end

  defp load_errors({:error, errors}), do: errors
  defp load_errors({:ok, _rows}), do: []

  defp score_and_print(queries, results, manifest, format) do
    case Scorer.score(queries, results, manifest) do
      {:ok, report} ->
        print_report(report, format)
        System.halt(0)

      {:error, errors} ->
        fail(errors)
    end
  end

  defp print_report(report, "json"), do: IO.puts(JSON.encode(report))

  defp print_report(report, "text") do
    metrics = report["metrics"]

    IO.puts(
      "Queries: #{report["query_count"]} (#{report["missing_result_count"]} missing results)"
    )

    IO.puts("Recall@5: #{format_metric(metrics["recall_at_5"])}")
    IO.puts("MRR: #{format_metric(metrics["mrr"])}")
    IO.puts("nDCG@5: #{format_metric(metrics["ndcg_at_5"])}")
    IO.puts("Citation top1: #{format_metric(metrics["citation_top1"])}")
    IO.puts("Hard-negative inversion: #{format_metric(metrics["hard_negative_inversion"])}")
    IO.puts("Abstention precision: #{format_metric(metrics["abstention_precision"])}")
    IO.puts("Abstention recall: #{format_metric(metrics["abstention_recall"])}")
  end

  defp print_report(_report, format),
    do: fail(["--format must be text or json, got #{inspect(format)}"])

  defp format_metric(value), do: :erlang.float_to_binary(value, decimals: 4)

  defp fail(errors) do
    Enum.each(errors, &IO.puts(:stderr, "error: #{&1}"))
    System.halt(2)
  end

  defp print_help(status) do
    IO.puts("""
    Usage: elixir tools/score_retrieval.exs --results RESULTS.jsonl [options]

      --queries PATH   Query JSONL file or directory (default: eval)
      --manifest PATH  retrieval.jsonl, retrieval catalog, or dist directory (default: dist)
      --results PATH   Ranked result JSONL file or directory
      --format FORMAT  text or json (default: text)
    """)

    System.halt(status)
  end
end

unless System.get_env("SCORE_RETRIEVAL_IMPORT_ONLY") == "1" do
  RetrievalEval.CLI.main(System.argv())
end
