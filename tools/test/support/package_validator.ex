defmodule AdrDist.PackageValidator do
  @moduledoc false

  @required_record_fields ~w(
    schema_version record_id record_kind parent_id hydrate_id ordinal domain adr_id
    rule_number polarity adr_title routing_title rule_title heading_path status date
    updated tags source_description routing_description applies_to source_path
    source_start_line source_end_line languages source_sha256 retrieval_sha256
    references retrieval_text display_text
  )

  @required_query_fields ~w(
    schema_version query_id query query_class scope_domains relevance
    hard_negative_ids should_abstain review_notes
  )

  @record_kinds ~w(adr_summary rule example supporting)
  @query_classes ~w(exact scenario code hard_negative multi_rule no_answer citation)
  @minimum_distinct_hard_negative_adr_pairs 12
  @required_hard_negative_adr_pairs [
    {"elixir-code-anti-patterns:adr-002", "elixir-conventions:adr-005"},
    {"elixir-conventions:adr-005", "elixir-conventions:adr-007"},
    {"elixir-otp:adr-004", "elixir-otp:adr-005"},
    {"elixir-conventions:adr-004", "elixir-otp:adr-012"},
    {"elixir-conventions:adr-007", "elixir-ecto:adr-001"},
    {"elixir-conventions:adr-008", "elixir-design-anti-patterns:adr-001"},
    {"elixir-code-anti-patterns:adr-010", "elixir-otp:adr-012"}
  ]

  @expected_counts %{
    "elixir-code-anti-patterns" => %{adrs: 10, rules: 16, examples: 32, supporting: 0},
    "elixir-conventions" => %{adrs: 8, rules: 30, examples: 60, supporting: 0},
    "elixir-design-anti-patterns" => %{adrs: 6, rules: 11, examples: 22, supporting: 0},
    "elixir-ecto" => %{adrs: 1, rules: 1, examples: 2, supporting: 0},
    "elixir-macro-anti-patterns" => %{adrs: 5, rules: 7, examples: 14, supporting: 0},
    "elixir-otp" => %{adrs: 13, rules: 46, examples: 92, supporting: 2},
    "elixir-resilience" => %{adrs: 1, rules: 2, examples: 4, supporting: 0}
  }

  @type stats :: %{
          retrieval_records: non_neg_integer(),
          legacy_records: non_neg_integer(),
          evaluation_queries: non_neg_integer()
        }

  @spec validate(Path.t()) :: {:ok, stats()} | {:error, [String.t()]}
  def validate(repo_root) do
    retrieval_paths = Path.wildcard(Path.join([repo_root, "dist", "*", "retrieval.jsonl"]))
    legacy_paths = Path.wildcard(Path.join([repo_root, "dist", "*", "adrs.jsonl"]))
    query_paths = Path.wildcard(Path.join([repo_root, "eval", "**", "queries.jsonl"]))

    {retrieval_records, retrieval_load_errors} = load_jsonl_files(retrieval_paths)
    {legacy_records, legacy_load_errors} = load_jsonl_files(legacy_paths)
    {query_rows, query_load_errors} = load_jsonl_files(query_paths)

    errors =
      missing_file_errors(retrieval_paths, legacy_paths, query_paths) ++
        retrieval_load_errors ++
        legacy_load_errors ++
        query_load_errors ++
        validate_schema(repo_root) ++
        validate_source_dates(repo_root) ++
        validate_retrieval(repo_root, retrieval_records) ++
        validate_legacy(legacy_records) ++
        validate_evaluation(query_rows, retrieval_records) ++
        validate_catalog(repo_root, retrieval_records)

    case errors do
      [] ->
        {:ok,
         %{
           retrieval_records: length(retrieval_records),
           legacy_records: length(legacy_records),
           evaluation_queries: length(query_rows)
         }}

      _ ->
        {:error, errors}
    end
  end

  defp missing_file_errors(retrieval_paths, legacy_paths, query_paths) do
    []
    |> add_if(retrieval_paths == [], "dist/: no retrieval.jsonl artifacts found")
    |> add_if(legacy_paths == [], "dist/: no adrs.jsonl artifacts found")
    |> add_if(query_paths == [], "eval/: no queries.jsonl files found")
  end

  defp load_jsonl_files(paths) do
    Enum.reduce(paths, {[], []}, fn path, {all_rows, all_errors} ->
      {rows, errors} = load_jsonl(path)
      {all_rows ++ rows, all_errors ++ errors}
    end)
  end

  defp load_jsonl(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {line, line_number}, {rows, errors} ->
      if String.trim(line) == "" do
        {rows, errors}
      else
        decode_jsonl_line(path, line_number, line, rows, errors)
      end
    end)
    |> then(fn {rows, errors} -> {Enum.reverse(rows), Enum.reverse(errors)} end)
  rescue
    error -> {[], ["#{path}: could not read JSONL: #{Exception.message(error)}"]}
  end

  defp decode_jsonl_line(path, line_number, line, rows, errors) do
    case Jason.decode(line) do
      {:ok, row} when is_map(row) ->
        {[Map.put(row, "__validation_path__", path) | rows], errors}

      {:ok, _value} ->
        {rows, ["#{path}:#{line_number}: expected a JSON object" | errors]}

      {:error, reason} ->
        {rows, ["#{path}:#{line_number}: invalid JSON: #{Exception.message(reason)}" | errors]}
    end
  end

  defp validate_schema(repo_root) do
    path = Path.join([repo_root, "schema", "retrieval-v1.schema.json"])

    case File.read(path) do
      {:ok, body} -> validate_schema_body(path, body)
      {:error, reason} -> ["#{path}: missing or unreadable schema: #{inspect(reason)}"]
    end
  end

  defp validate_schema_body(path, body) do
    case Jason.decode(body) do
      {:ok, schema} ->
        required_lists = collect_key(schema, "required")
        schema_text = Jason.encode!(schema)

        []
        |> add_if(
          schema["$schema"] != "https://json-schema.org/draft/2020-12/schema",
          "#{path}: $schema must declare JSON Schema Draft 2020-12"
        )
        |> add_if(
          not Enum.any?(
            required_lists,
            &MapSet.subset?(MapSet.new(@required_record_fields), MapSet.new(&1))
          ),
          "#{path}: no record definition requires the complete retrieval-v1 field set"
        )
        |> add_if(
          not Enum.all?(@record_kinds, &String.contains?(schema_text, &1)),
          "#{path}: record_kind contract is incomplete"
        )
        |> add_if(
          collect_key(schema, "additionalProperties") |> Enum.all?(&(&1 != false)),
          "#{path}: schema must reject undeclared properties"
        )

      {:error, reason} ->
        ["#{path}: invalid JSON: #{Exception.message(reason)}"]
    end
  end

  defp validate_source_dates(repo_root) do
    repo_root
    |> Path.join("adrs/*/adr-*.md")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_number} ->
        if Regex.match?(~r/^(date|updated):\s/, line) and
             not Regex.match?(~r/^(date|updated):\s+(['"])\d{4}-\d{2}-\d{2}\2\s*$/, line) do
          ["#{path}:#{line_number}: date metadata must be a quoted ISO date string"]
        else
          []
        end
      end)
    end)
  end

  defp validate_retrieval(repo_root, records) do
    clean_records = Enum.map(records, &Map.delete(&1, "__validation_path__"))
    ids = Enum.map(clean_records, & &1["record_id"])
    id_set = MapSet.new(ids)

    duplicate_errors(ids, "retrieval record_id") ++
      validate_corpus_counts(clean_records) ++
      validate_domain_ordinals(clean_records) ++
      validate_rule_example_separation(clean_records) ++
      Enum.flat_map(records, &validate_record(repo_root, &1, id_set))
  end

  defp validate_corpus_counts(records) do
    per_domain_errors =
      Enum.flat_map(@expected_counts, fn {domain, expected} ->
        domain_records = Enum.filter(records, &(&1["domain"] == domain))
        frequencies = Enum.frequencies_by(domain_records, & &1["record_kind"])

        []
        |> count_error(domain, "adr_summary", frequencies, expected.adrs)
        |> count_error(domain, "rule", frequencies, expected.rules)
        |> count_error(domain, "example", frequencies, expected.examples)
        |> count_error(domain, "supporting", frequencies, expected.supporting)
      end)

    totals = Enum.frequencies_by(records, & &1["record_kind"])

    (per_domain_errors ++
       [])
    |> total_count_error("all domains", "adr_summary", totals, 44)
    |> total_count_error("all domains", "rule", totals, 113)
    |> total_count_error("all domains", "example", totals, 226)
    |> total_count_error("all domains", "supporting", totals, 2)
    |> add_if(
      length(records) != 385,
      "dist/: expected 385 retrieval rows, found #{length(records)}"
    )
  end

  defp validate_record(repo_root, record, id_set) do
    path = Map.get(record, "__validation_path__", "retrieval.jsonl")
    record = Map.delete(record, "__validation_path__")
    id = record["record_id"] || "<missing record_id>"
    prefix = "#{path}: #{id}:"

    expected_fields =
      if record["record_kind"] == "adr_summary" do
        @required_record_fields ++ ~w(context decision consequences)
      else
        @required_record_fields
      end

    missing = expected_fields -- Map.keys(record)
    unexpected = Map.keys(record) -- expected_fields

    []
    |> add_if(missing != [], "#{prefix} missing fields: #{Enum.join(missing, ", ")}")
    |> add_if(unexpected != [], "#{prefix} unexpected fields: #{Enum.join(unexpected, ", ")}")
    |> add_if(record["schema_version"] != "retrieval-v1", "#{prefix} invalid schema_version")
    |> add_if(record["record_kind"] not in @record_kinds, "#{prefix} invalid record_kind")
    |> add_if(not valid_record_id?(record["record_id"]), "#{prefix} record_id is invalid")
    |> add_if(
      not is_integer(record["ordinal"]) or record["ordinal"] < 1,
      "#{prefix} ordinal must be positive"
    )
    |> add_if(
      not is_integer(record["adr_id"]) or record["adr_id"] < 1,
      "#{prefix} adr_id must be numeric"
    )
    |> add_if(
      not Regex.match?(~r/^[a-z][a-z0-9-]*$/, record["domain"] || ""),
      "#{prefix} domain is invalid"
    )
    |> add_if(
      not nonempty_string?(record["adr_title"]),
      "#{prefix} adr_title must be a non-empty string"
    )
    |> add_if(
      not nonempty_string?(record["routing_title"]),
      "#{prefix} routing_title must be a non-empty string"
    )
    |> add_if(
      not nonempty_string_list?(record["heading_path"]),
      "#{prefix} heading_path must contain non-empty strings"
    )
    |> add_if(
      not nonempty_string?(record["status"]),
      "#{prefix} status must be a non-empty string"
    )
    |> add_if(
      not unique_nonempty_string_list?(record["tags"]),
      "#{prefix} tags must contain unique non-empty strings"
    )
    |> add_if(
      not nonempty_string?(record["source_description"]),
      "#{prefix} source_description must be a non-empty string"
    )
    |> add_if(
      not nonempty_string?(record["routing_description"]),
      "#{prefix} routing_description must be a non-empty string"
    )
    |> add_if(not valid_applies_to?(record["applies_to"]), "#{prefix} applies_to is invalid")
    |> add_if(
      not Regex.match?(
        ~r/^adrs\/[a-z][a-z0-9-]*\/adr-[0-9]{3}-[^\/]+\.md$/,
        record["source_path"] || ""
      ),
      "#{prefix} source_path format is invalid"
    )
    |> add_if(
      not unique_nonempty_string_list?(record["languages"]),
      "#{prefix} languages must contain unique non-empty strings"
    )
    |> add_if(
      not date_or_nil?(record["date"], false),
      "#{prefix} date must be an ISO date string"
    )
    |> add_if(
      not date_or_nil?(record["updated"], true),
      "#{prefix} updated must be an ISO date string or null"
    )
    |> add_if(not positive_span?(record), "#{prefix} source line span is invalid")
    |> add_if(
      not nonempty_string?(record["retrieval_text"]),
      "#{prefix} retrieval_text must not be empty"
    )
    |> add_if(
      not nonempty_string?(record["display_text"]),
      "#{prefix} display_text must be a non-empty string"
    )
    |> add_if(
      not sha256_string?(record["source_sha256"]),
      "#{prefix} source_sha256 format is invalid"
    )
    |> add_if(
      not sha256_string?(record["retrieval_sha256"]),
      "#{prefix} retrieval_sha256 format is invalid"
    )
    |> add_if(
      record["retrieval_sha256"] != sha256(record["retrieval_text"]),
      "#{prefix} retrieval_sha256 mismatch"
    )
    |> add_if(
      record["source_sha256"] != sha256(record["display_text"]),
      "#{prefix} source_sha256 mismatch"
    )
    |> add_if(
      not source_exists?(repo_root, record["source_path"]),
      "#{prefix} source_path does not exist"
    )
    |> Kernel.++(validate_kind(record, id_set, prefix))
    |> Kernel.++(validate_references(repo_root, record, id_set, prefix))
  end

  defp validate_kind(%{"record_kind" => "adr_summary"} = record, id_set, prefix) do
    expected_id = adr_record_id(record)

    []
    |> add_if(
      record["record_id"] != expected_id,
      "#{prefix} summary record_id must be #{expected_id}"
    )
    |> add_if(not is_nil(record["parent_id"]), "#{prefix} summary parent_id must be null")
    |> add_if(
      record["hydrate_id"] != record["record_id"],
      "#{prefix} summary must hydrate itself"
    )
    |> add_if(not is_nil(record["rule_number"]), "#{prefix} summary rule_number must be null")
    |> add_if(not is_nil(record["rule_title"]), "#{prefix} summary rule_title must be null")
    |> add_if(not is_nil(record["polarity"]), "#{prefix} summary polarity must be null")
    |> add_if(not nonempty_string?(record["context"]), "#{prefix} summary context is required")
    |> add_if(not nonempty_string?(record["decision"]), "#{prefix} summary decision is required")
    |> add_if(
      not nonempty_string?(record["consequences"]),
      "#{prefix} summary consequences are required"
    )
    |> add_if(
      not MapSet.member?(id_set, record["hydrate_id"]),
      "#{prefix} hydrate_id is unresolved"
    )
  end

  defp validate_kind(%{"record_kind" => "rule"} = record, id_set, prefix) do
    expected_id = "#{adr_record_id(record)}:rule-#{pad(record["rule_number"], 2)}"

    []
    |> common_child_errors(record, id_set, prefix)
    |> add_if(
      record["record_id"] != expected_id,
      "#{prefix} Rule record_id must be #{expected_id}"
    )
    |> add_if(
      record["parent_id"] != adr_record_id(record),
      "#{prefix} Rule parent must be the ADR summary"
    )
    |> add_if(record["hydrate_id"] != record["record_id"], "#{prefix} Rule must hydrate itself")
    |> add_if(not is_integer(record["rule_number"]), "#{prefix} Rule number is required")
    |> add_if(not nonempty_string?(record["rule_title"]), "#{prefix} Rule title is required")
    |> add_if(not is_nil(record["polarity"]), "#{prefix} Rule polarity must be null")
    |> add_if(
      not String.contains?(record["display_text"] || "", "**Correct"),
      "#{prefix} Rule display omits Correct"
    )
    |> add_if(
      not String.contains?(record["display_text"] || "", "**Wrong"),
      "#{prefix} Rule display omits Wrong"
    )
    |> add_if(
      not String.contains?(record["display_text"] || "", "**Why:**"),
      "#{prefix} Rule display omits Why"
    )
    |> summary_only_field_errors(record, prefix)
  end

  defp validate_kind(%{"record_kind" => "example"} = record, id_set, prefix) do
    rule_id = "#{adr_record_id(record)}:rule-#{pad(record["rule_number"], 2)}"
    kind = if record["polarity"] == "positive", do: "correct", else: "wrong"
    expected_id = "#{rule_id}:example:#{kind}:01"

    []
    |> common_child_errors(record, id_set, prefix)
    |> add_if(
      record["record_id"] != expected_id,
      "#{prefix} example record_id must be #{expected_id}"
    )
    |> add_if(record["parent_id"] != rule_id, "#{prefix} example parent must be its Rule")
    |> add_if(
      record["hydrate_id"] != record["parent_id"],
      "#{prefix} example must hydrate its Rule parent"
    )
    |> add_if(
      record["polarity"] not in ~w(positive negative),
      "#{prefix} example polarity is invalid"
    )
    |> add_if(not is_integer(record["rule_number"]), "#{prefix} example rule_number is required")
    |> add_if(
      not Regex.match?(~r/:example:(?:correct|wrong):\d{2}$/, record["record_id"] || ""),
      "#{prefix} example record_id is invalid"
    )
    |> summary_only_field_errors(record, prefix)
  end

  defp validate_kind(%{"record_kind" => "supporting"} = record, id_set, prefix) do
    expected_prefix = Regex.escape(adr_record_id(record))

    []
    |> common_child_errors(record, id_set, prefix)
    |> add_if(
      record["parent_id"] != adr_record_id(record),
      "#{prefix} supporting parent must be the ADR summary"
    )
    |> add_if(
      record["hydrate_id"] != record["record_id"],
      "#{prefix} supporting record must hydrate itself"
    )
    |> add_if(not is_nil(record["rule_number"]), "#{prefix} supporting rule_number must be null")
    |> add_if(not is_nil(record["rule_title"]), "#{prefix} supporting rule_title must be null")
    |> add_if(not is_nil(record["polarity"]), "#{prefix} supporting polarity must be null")
    |> add_if(
      not Regex.match?(
        ~r/^#{expected_prefix}:supporting:[a-z0-9]+(?:-[a-z0-9]+)*$/,
        record["record_id"] || ""
      ),
      "#{prefix} supporting record_id is invalid"
    )
    |> summary_only_field_errors(record, prefix)
  end

  defp validate_kind(_record, _id_set, _prefix), do: []

  defp common_child_errors(errors, record, id_set, prefix) do
    errors
    |> add_if(not is_binary(record["parent_id"]), "#{prefix} child parent_id is required")
    |> add_if(
      not MapSet.member?(id_set, record["parent_id"]),
      "#{prefix} parent_id is unresolved"
    )
    |> add_if(
      not MapSet.member?(id_set, record["hydrate_id"]),
      "#{prefix} hydrate_id is unresolved"
    )
  end

  defp summary_only_field_errors(errors, record, prefix) do
    Enum.reduce(~w(context decision consequences), errors, fn field, field_errors ->
      add_if(field_errors, Map.has_key?(record, field), "#{prefix} #{field} is summary-only")
    end)
  end

  defp validate_references(repo_root, record, id_set, prefix) do
    case record["references"] do
      references when is_list(references) ->
        Enum.flat_map(references, fn reference ->
          validate_reference(repo_root, record, reference, id_set, prefix)
        end)

      _ ->
        ["#{prefix} references must be a list"]
    end
  end

  defp validate_reference(repo_root, record, reference, id_set, prefix) when is_map(reference) do
    expected_keys = ~w(raw_text source_line target_id) |> Enum.sort()
    source_line = reference["source_line"]

    []
    |> add_if(
      Map.keys(reference) |> Enum.sort() != expected_keys,
      "#{prefix} reference fields are invalid"
    )
    |> add_if(
      not MapSet.member?(id_set, reference["target_id"]),
      "#{prefix} reference target is unresolved"
    )
    |> add_if(
      not adr_or_rule_record_id?(reference["target_id"]),
      "#{prefix} reference target must be an ADR summary or Rule"
    )
    |> add_if(
      not nonempty_string?(reference["raw_text"]),
      "#{prefix} reference raw_text is required"
    )
    |> add_if(not is_integer(source_line), "#{prefix} reference source_line is required")
    |> add_if(
      is_integer(source_line) and
        (source_line < record["source_start_line"] or source_line > record["source_end_line"]),
      "#{prefix} reference source_line is outside the record span"
    )
    |> add_if(
      is_integer(source_line) and
        not source_line_contains?(
          repo_root,
          record["source_path"],
          source_line,
          reference["raw_text"]
        ),
      "#{prefix} reference raw_text is absent from its source line"
    )
  end

  defp validate_reference(_repo_root, _record, _reference, _id_set, prefix),
    do: ["#{prefix} reference must be an object"]

  defp validate_rule_example_separation(records) do
    examples_by_rule =
      records
      |> Enum.filter(&(&1["record_kind"] == "example"))
      |> Enum.group_by(& &1["parent_id"])

    records
    |> Enum.filter(&(&1["record_kind"] == "rule"))
    |> Enum.flat_map(fn rule ->
      examples_by_rule
      |> Map.get(rule["record_id"], [])
      |> Enum.flat_map(fn example ->
        if String.contains?(rule["retrieval_text"], example["display_text"]) do
          ["#{rule["record_id"]}: retrieval_text contains a complete labelled example region"]
        else
          []
        end
      end)
    end)
  end

  defp validate_domain_ordinals(records) do
    Enum.flat_map(@expected_counts, fn {domain, _counts} ->
      ordinals =
        records
        |> Enum.filter(&(&1["domain"] == domain))
        |> Enum.map(& &1["ordinal"])

      expected = Enum.to_list(1..length(ordinals))

      if ordinals == expected do
        []
      else
        ["dist/#{domain}/retrieval.jsonl: ordinals must be unique and contiguous in source order"]
      end
    end)
  end

  defp validate_legacy(records) do
    expected_keys = ~w(applies_to body description domain id tags title) |> Enum.sort()
    clean_records = Enum.map(records, &Map.delete(&1, "__validation_path__"))

    domain_errors =
      Enum.flat_map(@expected_counts, fn {domain, expected} ->
        actual = Enum.count(clean_records, &(&1["domain"] == domain))

        if actual == expected.adrs do
          []
        else
          ["dist/#{domain}/adrs.jsonl: expected #{expected.adrs} rows, found #{actual}"]
        end
      end)

    row_errors =
      Enum.flat_map(records, fn record ->
        path = record["__validation_path__"]
        clean = Map.delete(record, "__validation_path__")

        []
        |> add_if(
          Map.keys(clean) |> Enum.sort() != expected_keys,
          "#{path}: legacy row fields changed"
        )
        |> add_if(not is_integer(clean["id"]), "#{path}: legacy id must remain numeric")
        |> add_if(not nonempty_string?(clean["body"]), "#{path}: legacy body is empty")
      end)

    domain_errors ++ row_errors
  end

  defp validate_evaluation(rows, retrieval_records) do
    clean_rows = Enum.map(rows, &Map.delete(&1, "__validation_path__"))
    clean_records = Enum.map(retrieval_records, &Map.delete(&1, "__validation_path__"))
    record_ids = MapSet.new(Enum.map(clean_records, & &1["record_id"]))

    rule_ids =
      clean_records |> Enum.filter(&(&1["record_kind"] == "rule")) |> Enum.map(& &1["record_id"])

    query_ids = Enum.map(clean_rows, & &1["query_id"])
    class_counts = Enum.frequencies_by(clean_rows, & &1["query_class"])

    (duplicate_errors(query_ids, "evaluation query_id") ++
       [])
    |> add_if(
      length(clean_rows) != 403,
      "eval/: expected 403 queries, found #{length(clean_rows)}"
    )
    |> evaluation_class_count_error(class_counts, "exact", 113)
    |> evaluation_class_count_error(class_counts, "scenario", 113)
    |> evaluation_class_count_error(class_counts, "code", 113)
    |> evaluation_class_count_error(class_counts, "hard_negative", 24)
    |> evaluation_class_count_error(class_counts, "multi_rule", 15)
    |> evaluation_class_count_error(class_counts, "no_answer", 15)
    |> evaluation_class_count_error(class_counts, "citation", 10)
    |> Kernel.++(Enum.flat_map(rows, &validate_query(&1, record_ids)))
    |> Kernel.++(validate_rule_query_coverage(rule_ids, MapSet.new(query_ids)))
    |> Kernel.++(validate_bidirectional_hard_negatives(clean_rows))
    |> Kernel.++(validate_hard_negative_adr_pair_coverage(clean_rows))
  end

  defp validate_query(row, record_ids) do
    path = row["__validation_path__"] || "eval/queries.jsonl"
    row = Map.delete(row, "__validation_path__")
    id = row["query_id"] || "<missing query_id>"
    prefix = "#{path}: #{id}:"
    missing = @required_query_fields -- Map.keys(row)

    errors =
      []
      |> add_if(missing != [], "#{prefix} missing fields: #{Enum.join(missing, ", ")}")
      |> add_if(not nonempty_string?(row["query"]), "#{prefix} query is empty")
      |> add_if(row["query_class"] not in @query_classes, "#{prefix} query_class is invalid")
      |> add_if(
        not string_list?(row["scope_domains"]) or row["scope_domains"] == [],
        "#{prefix} scope_domains is invalid"
      )
      |> add_if(not is_boolean(row["should_abstain"]), "#{prefix} should_abstain must be boolean")
      |> add_if(not nonempty_string?(row["review_notes"]), "#{prefix} review_notes are required")

    relevance_errors = validate_relevance(row["relevance"], record_ids, prefix)
    negative_errors = validate_hard_negative_ids(row["hard_negative_ids"], record_ids, prefix)
    class_errors = validate_query_class_shape(row, prefix)
    errors ++ relevance_errors ++ negative_errors ++ class_errors
  end

  defp validate_relevance(relevance, record_ids, prefix) when is_list(relevance) do
    Enum.flat_map(relevance, fn judgment ->
      []
      |> add_if(not is_map(judgment), "#{prefix} relevance entry must be an object")
      |> add_if(
        not MapSet.member?(record_ids, judgment["record_id"]),
        "#{prefix} relevance ID is unresolved"
      )
      |> add_if(judgment["grade"] not in 1..3, "#{prefix} relevance grade must be 1..3")
    end)
  end

  defp validate_relevance(_relevance, _record_ids, prefix),
    do: ["#{prefix} relevance must be a list"]

  defp validate_hard_negative_ids(ids, record_ids, prefix) when is_list(ids) do
    Enum.flat_map(ids, fn id ->
      if MapSet.member?(record_ids, id),
        do: [],
        else: ["#{prefix} hard-negative ID is unresolved: #{inspect(id)}"]
    end)
  end

  defp validate_hard_negative_ids(_ids, _record_ids, prefix),
    do: ["#{prefix} hard_negative_ids must be a list"]

  defp validate_query_class_shape(%{"query_class" => "no_answer"} = row, prefix) do
    []
    |> add_if(row["should_abstain"] != true, "#{prefix} no_answer must require abstention")
    |> add_if(row["relevance"] != [], "#{prefix} no_answer relevance must be empty")
  end

  defp validate_query_class_shape(%{"query_class" => "hard_negative"} = row, prefix) do
    []
    |> add_if(row["should_abstain"] != false, "#{prefix} hard_negative must be answerable")
    |> add_if(
      length(row["hard_negative_ids"] || []) == 0,
      "#{prefix} hard_negative requires a distractor"
    )
  end

  defp validate_query_class_shape(%{"query_class" => "multi_rule"} = row, prefix) do
    add_if(
      [],
      length(row["relevance"] || []) < 2,
      "#{prefix} multi_rule requires at least two judgments"
    )
  end

  defp validate_query_class_shape(row, prefix) do
    add_if([], row["should_abstain"] == true, "#{prefix} answerable class must not abstain")
  end

  defp validate_rule_query_coverage(rule_ids, query_ids) do
    Enum.flat_map(rule_ids, fn rule_id ->
      Enum.flat_map(~w(exact scenario code), fn class ->
        expected = "q:#{rule_id}:#{class}"
        if MapSet.member?(query_ids, expected), do: [], else: ["eval/: missing #{expected}"]
      end)
    end)
  end

  defp validate_bidirectional_hard_negatives(rows) do
    pairs = rows |> hard_negative_rule_pairs() |> MapSet.new()

    Enum.flat_map(pairs, fn {primary, negative} ->
      if MapSet.member?(pairs, {negative, primary}) do
        []
      else
        ["eval/cross-domain: hard-negative pair is not bidirectional: #{primary} / #{negative}"]
      end
    end)
  end

  @spec validate_hard_negative_adr_pair_coverage([map()]) :: [String.t()]
  def validate_hard_negative_adr_pair_coverage(rows) do
    distinct_pairs =
      rows
      |> hard_negative_rule_pairs()
      |> Enum.map(&normalize_adr_pair/1)
      |> Enum.reject(fn {primary, negative} -> primary == negative end)
      |> MapSet.new()

    count_errors =
      add_if(
        [],
        MapSet.size(distinct_pairs) < @minimum_distinct_hard_negative_adr_pairs,
        "eval/cross-domain: expected at least " <>
          "#{@minimum_distinct_hard_negative_adr_pairs} distinct cross-ADR hard-negative pairs, " <>
          "found #{MapSet.size(distinct_pairs)}"
      )

    required_pair_errors =
      @required_hard_negative_adr_pairs
      |> Enum.reject(&MapSet.member?(distinct_pairs, &1))
      |> Enum.map(fn {left, right} ->
        "eval/cross-domain: missing required hard-negative ADR pair: #{left} / #{right}"
      end)

    count_errors ++ required_pair_errors
  end

  defp hard_negative_rule_pairs(rows) do
    rows
    |> Enum.filter(&(&1["query_class"] == "hard_negative"))
    |> Enum.flat_map(fn row ->
      primary =
        row
        |> Map.get("relevance", [])
        |> Enum.find(fn judgment -> judgment["grade"] == 3 end)
        |> case do
          nil -> nil
          judgment -> judgment["record_id"]
        end

      negatives = Map.get(row, "hard_negative_ids", [])

      if is_binary(primary) and is_list(negatives) do
        negatives
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&{primary, &1})
      else
        []
      end
    end)
  end

  defp normalize_adr_pair({primary, negative}) do
    [parent_adr_id(primary), parent_adr_id(negative)]
    |> Enum.sort()
    |> List.to_tuple()
  end

  defp parent_adr_id(record_id) when is_binary(record_id) do
    String.replace(record_id, ~r/:rule-\d+\z/, "")
  end

  defp parent_adr_id(_record_id), do: nil

  defp validate_catalog(repo_root, records) do
    path = Path.join([repo_root, "dist", "retrieval-catalog.json"])

    case File.read(path) do
      {:ok, body} -> validate_catalog_body(repo_root, path, body, records)
      {:error, reason} -> ["#{path}: missing or unreadable catalog: #{inspect(reason)}"]
    end
  end

  defp validate_catalog_body(repo_root, path, body, records) do
    case Jason.decode(body) do
      {:ok, catalog} -> validate_catalog_object(repo_root, path, catalog, records)
      {:error, reason} -> ["#{path}: invalid JSON: #{Exception.message(reason)}"]
    end
  end

  defp validate_catalog_object(repo_root, path, catalog, records) do
    domains = catalog["domains"] || []
    domain_names = Enum.map(domains, & &1["domain"])
    expected_domains = @expected_counts |> Map.keys() |> Enum.sort()
    frequencies = Enum.frequencies_by(records, & &1["record_kind"])

    []
    |> add_if(catalog["schema_version"] != "retrieval-v1", "#{path}: invalid schema_version")
    |> add_if(not is_list(catalog["domains"]), "#{path}: domains must be a list")
    |> add_if(domain_names != Enum.sort(domain_names), "#{path}: domains are not sorted")
    |> add_if(domain_names != expected_domains, "#{path}: domain inventory does not match dist/")
    |> Kernel.++(validate_catalog_counts(path, catalog["counts"], frequencies, length(records)))
    |> Kernel.++(Enum.flat_map(domains, &validate_catalog_domain(repo_root, path, &1, records)))
  end

  defp validate_catalog_domain(repo_root, catalog_path, domain_entry, records) do
    domain = domain_entry["domain"] || "<missing domain>"
    artifact = domain_entry["artifact"]
    expected_artifact = "#{domain}/retrieval.jsonl"

    artifact_path =
      if is_binary(artifact), do: Path.join([repo_root, "dist", artifact]), else: nil

    domain_records = Enum.filter(records, &(&1["domain"] == domain))
    frequencies = Enum.frequencies_by(domain_records, & &1["record_kind"])

    errors =
      []
      |> add_if(
        not nonempty_string?(domain_entry["title"]),
        "#{catalog_path}: #{domain}: title is required"
      )
      |> add_if(
        not nonempty_string?(domain_entry["description"]),
        "#{catalog_path}: #{domain}: description is required"
      )
      |> add_if(
        artifact != expected_artifact,
        "#{catalog_path}: #{domain}: artifact path is invalid"
      )
      |> add_if(
        not is_binary(artifact_path) or not File.regular?(artifact_path),
        "#{catalog_path}: #{domain}: artifact is missing"
      )
      |> Kernel.++(
        validate_catalog_counts(
          "#{catalog_path}: #{domain}",
          domain_entry["counts"],
          frequencies,
          length(domain_records)
        )
      )

    checksum_error =
      if is_binary(artifact_path) and File.regular?(artifact_path) do
        expected_checksum = artifact_path |> File.read!() |> sha256()

        add_if(
          [],
          domain_entry["sha256"] != expected_checksum,
          "#{catalog_path}: #{domain}: sha256 mismatch"
        )
      else
        []
      end

    errors ++ checksum_error
  end

  defp validate_catalog_counts(path, counts, frequencies, total) when is_map(counts) do
    []
    |> add_if(counts["records"] != total, "#{path}: counts.records mismatch")
    |> add_if(
      counts["adrs"] != Map.get(frequencies, "adr_summary", 0),
      "#{path}: counts.adrs mismatch"
    )
    |> add_if(
      counts["rules"] != Map.get(frequencies, "rule", 0),
      "#{path}: counts.rules mismatch"
    )
    |> add_if(
      counts["examples"] != Map.get(frequencies, "example", 0),
      "#{path}: counts.examples mismatch"
    )
    |> add_if(
      counts["supporting"] != Map.get(frequencies, "supporting", 0),
      "#{path}: counts.supporting mismatch"
    )
  end

  defp validate_catalog_counts(path, _counts, _frequencies, _total),
    do: ["#{path}: counts must be an object"]

  defp collect_key(value, key) when is_map(value) do
    own = if Map.has_key?(value, key), do: [value[key]], else: []
    own ++ (value |> Map.values() |> Enum.flat_map(&collect_key(&1, key)))
  end

  defp collect_key(value, key) when is_list(value),
    do: Enum.flat_map(value, &collect_key(&1, key))

  defp collect_key(_value, _key), do: []

  defp count_error(errors, domain, kind, frequencies, expected) do
    actual = Map.get(frequencies, kind, 0)

    add_if(
      errors,
      actual != expected,
      "dist/#{domain}/retrieval.jsonl: expected #{expected} #{kind}, found #{actual}"
    )
  end

  defp total_count_error(errors, scope, kind, frequencies, expected) do
    actual = Map.get(frequencies, kind, 0)

    add_if(
      errors,
      actual != expected,
      "dist/: #{scope} expected #{expected} #{kind}, found #{actual}"
    )
  end

  defp evaluation_class_count_error(errors, frequencies, class, expected) do
    actual = Map.get(frequencies, class, 0)

    add_if(
      errors,
      actual != expected,
      "eval/: expected #{expected} #{class} queries, found #{actual}"
    )
  end

  defp duplicate_errors(values, label) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {value, count} when count > 1 -> ["duplicate #{label}: #{value} (#{count} occurrences)"]
      {_value, _count} -> []
    end)
  end

  defp source_exists?(repo_root, source_path) when is_binary(source_path) do
    File.regular?(Path.join(repo_root, source_path))
  end

  defp source_exists?(_repo_root, _source_path), do: false

  defp valid_record_id?(value) when is_binary(value) do
    Regex.match?(
      ~r/^[a-z][a-z0-9-]*:adr-[0-9]{3}(?::rule-[0-9]{2}(?::example:(?:correct|wrong):[0-9]{2})?|:supporting:[a-z0-9]+(?:-[a-z0-9]+)*)?$/,
      value
    )
  end

  defp valid_record_id?(_value), do: false

  defp adr_or_rule_record_id?(value) when is_binary(value) do
    Regex.match?(~r/^[a-z][a-z0-9-]*:adr-[0-9]{3}(?::rule-[0-9]{2})?$/, value)
  end

  defp adr_or_rule_record_id?(_value), do: false

  defp source_line_contains?(repo_root, source_path, line_number, raw_text)
       when is_binary(source_path) and is_binary(raw_text) do
    case File.read(Path.join(repo_root, source_path)) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: false)
        |> Enum.at(line_number - 1, "")
        |> String.contains?(raw_text)

      {:error, _reason} ->
        false
    end
  end

  defp source_line_contains?(_repo_root, _source_path, _line_number, _raw_text), do: false

  defp adr_record_id(record) do
    "#{record["domain"]}:adr-#{pad(record["adr_id"], 3)}"
  end

  defp pad(value, width) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string()
    |> String.pad_leading(width, "0")
  end

  defp pad(value, _width), do: inspect(value)

  defp positive_span?(record) do
    start_line = record["source_start_line"]
    end_line = record["source_end_line"]
    is_integer(start_line) and is_integer(end_line) and start_line >= 1 and end_line >= start_line
  end

  defp date_or_nil?(nil, true), do: true

  defp date_or_nil?(value, _nullable) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> true
      {:error, _reason} -> false
    end
  end

  defp date_or_nil?(_value, _nullable), do: false

  defp string_list?(value) when is_list(value), do: Enum.all?(value, &is_binary/1)
  defp string_list?(_value), do: false

  defp nonempty_string_list?(value) when is_list(value),
    do: Enum.all?(value, &nonempty_string?/1)

  defp nonempty_string_list?(_value), do: false

  defp unique_nonempty_string_list?(value) when is_list(value) do
    nonempty_string_list?(value) and length(value) == MapSet.size(MapSet.new(value))
  end

  defp unique_nonempty_string_list?(_value), do: false

  defp valid_applies_to?(value) when is_map(value) do
    allowed_keys = ~w(content_match paths)

    Map.keys(value) -- allowed_keys == [] and
      Enum.all?(Map.values(value), &unique_nonempty_string_list?/1)
  end

  defp valid_applies_to?(_value), do: false

  defp sha256_string?(value) when is_binary(value), do: Regex.match?(~r/^[0-9a-f]{64}$/, value)
  defp sha256_string?(_value), do: false

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp sha256(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp sha256(_value), do: nil

  defp add_if(errors, true, message), do: errors ++ [message]
  defp add_if(errors, false, _message), do: errors
end
