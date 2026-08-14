defmodule AdrDist.Retrieval do
  @moduledoc """
  Builds and validates provider-neutral retrieval records for the ADR corpus.

  Rule records are the canonical retrieval unit. Example hits hydrate their
  parent Rule, while ADR summaries and supporting decision aids can be used for
  routing and broader architectural questions.
  """

  alias AdrDist.{Adr, Error, Markdown, References}
  alias AdrDist.Markdown.{Example, Rule, Section}

  @schema_version "retrieval-v1"
  @required_fields ~w(
    schema_version record_id record_kind parent_id hydrate_id ordinal domain adr_id
    rule_number polarity adr_title routing_title rule_title heading_path status date
    updated tags source_description routing_description applies_to source_path
    source_start_line source_end_line languages source_sha256 retrieval_sha256
    references retrieval_text display_text
  )
  @record_kinds ~w(adr_summary supporting rule example)
  @summary_fields ~w(context decision consequences)
  @allowed_fields @required_fields ++ @summary_fields

  @type retrieval_record :: %{required(String.t()) => term()}
  @type build_error ::
          {:duplicate_record_id, String.t()}
          | {:invalid_parent, String.t(), String.t() | nil}
          | {:invalid_record, String.t(), String.t()}
          | Error.t()

  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @spec build([Adr.t()]) :: {:ok, [retrieval_record()]} | {:error, [build_error()]}
  def build(adrs) when is_list(adrs) do
    records = Enum.flat_map(adrs, &adr_records/1)
    known_ids = known_reference_ids(adrs)

    case resolve_references(records, known_ids) do
      {:ok, resolved} -> resolved |> assign_ordinals() |> validate()
      {:error, _errors} = error -> error
    end
  end

  @spec validate([retrieval_record()]) ::
          {:ok, [retrieval_record()]} | {:error, [build_error()]}
  def validate(records) when is_list(records) do
    ids = Enum.map(records, &Map.get(&1, "record_id"))
    id_set = MapSet.new(ids)

    errors =
      duplicate_id_errors(ids) ++
        duplicate_retrieval_errors(records) ++
        ordinal_errors(records) ++
        Enum.flat_map(records, &record_errors(&1, id_set))

    case errors do
      [] -> {:ok, records}
      _ -> {:error, errors}
    end
  end

  @spec counts([retrieval_record()]) :: map()
  def counts(records) when is_list(records) do
    by_kind = Enum.frequencies_by(records, &Map.get(&1, "record_kind"))

    %{
      "records" => length(records),
      "adrs" => Map.get(by_kind, "adr_summary", 0),
      "rules" => Map.get(by_kind, "rule", 0),
      "examples" => Map.get(by_kind, "example", 0),
      "supporting" => Map.get(by_kind, "supporting", 0)
    }
  end

  defp adr_records(%Adr{} = adr) do
    child_groups =
      Enum.map(adr.document.supporting, fn section ->
        {section.start_line, [supporting_record(adr, section)]}
      end) ++
        Enum.map(adr.document.rules, fn rule ->
          {rule.start_line, rule_records(adr, rule)}
        end)

    [
      summary_record(adr)
      | child_groups |> Enum.sort_by(&elem(&1, 0)) |> Enum.flat_map(&elem(&1, 1))
    ]
  end

  defp summary_record(%Adr{} = adr) do
    record_id = Adr.stable_id(adr)
    context = Markdown.section_content(adr.document.context)
    decision = Markdown.section_content(adr.document.decision)
    consequences = Markdown.section_content(adr.document.consequences)
    display_text = Enum.join([context, decision, consequences], "\n\n")

    rule_headings =
      adr.document.rules
      |> Enum.map(& &1.heading)
      |> Enum.join("\n")

    retrieval_text =
      retrieval_join([
        "Record: #{record_id}",
        "Domain: #{adr.domain}",
        "ADR: #{source_title(adr)}",
        "Routing title: #{adr.title}",
        "Routing description: #{adr.description}",
        "Source description: #{source_description(adr)}",
        context,
        decision,
        consequences,
        if(rule_headings == "", do: nil, else: "Rule headings:\n#{rule_headings}")
      ])

    adr
    |> base_record(%{
      "record_id" => record_id,
      "record_kind" => "adr_summary",
      "parent_id" => nil,
      "hydrate_id" => record_id,
      "rule_number" => nil,
      "polarity" => nil,
      "rule_title" => nil,
      "heading_path" => [adr.document.title],
      "source_start_line" => adr.document.context.start_line,
      "source_end_line" => adr.document.consequences.end_line,
      "retrieval_text" => retrieval_text,
      "display_text" => display_text,
      "context" => context,
      "decision" => decision,
      "consequences" => consequences,
      "__reference_regions__" => [
        {context, adr.document.context.start_line},
        {decision, adr.document.decision.start_line},
        {consequences, adr.document.consequences.start_line}
      ]
    })
  end

  defp supporting_record(%Adr{} = adr, %Section{} = section) do
    record_id = "#{Adr.stable_id(adr)}:supporting:#{slug(section.title)}"
    display_text = Markdown.section_content(section)

    retrieval_text =
      retrieval_join([
        "Record: #{record_id}",
        "Domain: #{adr.domain}",
        "ADR: #{source_title(adr)}",
        "Routing title: #{adr.title}",
        "Routing description: #{adr.description}",
        Markdown.section_content(adr.document.context),
        display_text
      ])

    adr
    |> base_record(%{
      "record_id" => record_id,
      "record_kind" => "supporting",
      "parent_id" => Adr.stable_id(adr),
      "hydrate_id" => record_id,
      "rule_number" => nil,
      "polarity" => nil,
      "rule_title" => nil,
      "heading_path" => without_document_title(section.path),
      "source_start_line" => section.start_line,
      "source_end_line" => section.end_line,
      "retrieval_text" => retrieval_text,
      "display_text" => display_text,
      "__reference_regions__" => [{display_text, section.start_line}]
    })
  end

  defp rule_records(%Adr{} = adr, %Rule{} = rule) do
    [
      rule_record(adr, rule),
      example_record(adr, rule, rule.correct, 1),
      example_record(adr, rule, rule.wrong, 1)
    ]
  end

  defp rule_record(%Adr{} = adr, %Rule{} = rule) do
    record_id = Adr.rule_id(adr, rule.number)
    display_text = rule.display_text

    retrieval_text =
      retrieval_join([
        "Record: #{record_id}",
        "Domain: #{adr.domain}",
        "ADR: #{source_title(adr)}",
        rule.heading,
        rule.statement,
        "Why: #{rule.why}"
      ])

    adr
    |> base_record(%{
      "record_id" => record_id,
      "record_kind" => "rule",
      "parent_id" => Adr.stable_id(adr),
      "hydrate_id" => record_id,
      "rule_number" => rule.number,
      "polarity" => nil,
      "rule_title" => rule.title,
      "heading_path" => without_document_title(rule.path),
      "source_start_line" => rule.start_line,
      "source_end_line" => rule.end_line,
      "retrieval_text" => retrieval_text,
      "display_text" => display_text,
      "__reference_regions__" => [{display_text, rule.start_line}]
    })
  end

  defp example_record(%Adr{} = adr, %Rule{} = rule, %Example{} = example, index) do
    rule_id = Adr.rule_id(adr, rule.number)
    kind = Atom.to_string(example.kind)
    record_id = "#{rule_id}:example:#{kind}:#{pad(index, 2)}"
    polarity = if example.kind == :correct, do: "positive", else: "negative"
    display_text = Markdown.example_content(example)

    retrieval_text =
      retrieval_join([
        "Record: #{record_id}",
        "Domain: #{adr.domain}",
        "ADR: #{source_title(adr)}",
        "Routing title: #{adr.title}",
        "Rule #{rule.number}: #{rule.title}",
        "#{String.capitalize(kind)} example (#{polarity})",
        rule.statement,
        display_text,
        "Why: #{rule.why}"
      ])

    adr
    |> base_record(%{
      "record_id" => record_id,
      "record_kind" => "example",
      "parent_id" => rule_id,
      "hydrate_id" => rule_id,
      "rule_number" => rule.number,
      "polarity" => polarity,
      "rule_title" => rule.title,
      "heading_path" => without_document_title(rule.path) ++ [example.label],
      "source_start_line" => example.start_line,
      "source_end_line" => example.end_line,
      "retrieval_text" => retrieval_text,
      "display_text" => display_text,
      "__reference_regions__" => [{display_text, example.start_line}]
    })
  end

  defp base_record(%Adr{} = adr, fields) do
    display_text = Map.fetch!(fields, "display_text")
    retrieval_text = Map.fetch!(fields, "retrieval_text")

    %{
      "schema_version" => @schema_version,
      "record_id" => Map.fetch!(fields, "record_id"),
      "record_kind" => Map.fetch!(fields, "record_kind"),
      "parent_id" => Map.fetch!(fields, "parent_id"),
      "hydrate_id" => Map.fetch!(fields, "hydrate_id"),
      "ordinal" => nil,
      "domain" => adr.domain,
      "adr_id" => adr.id,
      "rule_number" => Map.fetch!(fields, "rule_number"),
      "polarity" => Map.fetch!(fields, "polarity"),
      "adr_title" => source_title(adr),
      "routing_title" => adr.title,
      "rule_title" => Map.fetch!(fields, "rule_title"),
      "heading_path" => Map.fetch!(fields, "heading_path"),
      "status" => Map.get(adr.frontmatter, "status"),
      "date" => normalize_date(Map.get(adr.frontmatter, "date")),
      "updated" => normalize_date(Map.get(adr.frontmatter, "updated")),
      "tags" => Map.get(adr.frontmatter, "tags", []),
      "source_description" => source_description(adr),
      "routing_description" => adr.description,
      "applies_to" => adr.applies_to || %{},
      "source_path" => adr.source_path,
      "source_start_line" => Map.fetch!(fields, "source_start_line"),
      "source_end_line" => Map.fetch!(fields, "source_end_line"),
      "languages" => languages(display_text),
      "source_sha256" => sha256(display_text),
      "retrieval_sha256" => sha256(retrieval_text),
      "references" => [],
      "retrieval_text" => retrieval_text,
      "display_text" => display_text,
      "__reference_regions__" => Map.fetch!(fields, "__reference_regions__")
    }
    |> Map.merge(Map.take(fields, ["context", "decision", "consequences"]))
  end

  defp known_reference_ids(adrs) do
    adrs
    |> Enum.flat_map(fn adr ->
      [Adr.stable_id(adr) | Enum.map(adr.document.rules, &Adr.rule_id(adr, &1.number))]
    end)
    |> MapSet.new()
  end

  defp resolve_references(records, known_ids) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, resolved_records} ->
      case resolve_record_references(record, known_ids) do
        {:ok, resolved_record} -> {:cont, {:ok, [resolved_record | resolved_records]}}
        {:error, _errors} = error -> {:halt, error}
      end
    end)
    |> reverse_success()
  end

  defp resolve_record_references(record, known_ids) do
    record_id = Map.fetch!(record, "record_id")
    domain = Map.fetch!(record, "domain")

    record
    |> Map.fetch!("__reference_regions__")
    |> Enum.reduce_while({:ok, []}, fn {content, source_start_line}, {:ok, references} ->
      case References.resolve(content, domain, known_ids, record_id) do
        {:ok, region_references} ->
          absolute =
            Enum.map(region_references, fn reference ->
              Map.update!(reference, "source_line", &(&1 + source_start_line - 1))
            end)

          {:cont, {:ok, references ++ absolute}}

        {:error, errors} ->
          {:halt, {:error, normalize_reference_errors(errors, record, source_start_line - 1)}}
      end
    end)
    |> case do
      {:ok, references} ->
        {:ok, record |> Map.delete("__reference_regions__") |> Map.put("references", references)}

      {:error, _errors} = error ->
        error
    end
  end

  defp normalize_reference_errors(errors, record, offset) do
    record_id = Map.fetch!(record, "record_id")
    source_path = Map.fetch!(record, "source_path")

    Enum.map(errors, fn
      {:malformed_reference, line, text} ->
        Error.new(
          :malformed_reference,
          "malformed ADR reference in #{record_id}: #{text}",
          path: source_path,
          line: line + offset,
          details: %{record_id: record_id, raw_text: text}
        )

      {:unresolved_reference, source, target, line} ->
        Error.new(
          :unresolved_reference,
          "unresolved ADR reference #{target} in #{source}",
          path: source_path,
          line: line + offset,
          details: %{record_id: record_id, target_id: target}
        )
    end)
  end

  defp reverse_success({:ok, records}), do: {:ok, Enum.reverse(records)}
  defp reverse_success({:error, _errors} = error), do: error

  defp assign_ordinals(records) do
    {numbered, _counters} =
      Enum.map_reduce(records, %{}, fn record, counters ->
        domain = Map.fetch!(record, "domain")
        ordinal = Map.get(counters, domain, 0) + 1
        {Map.put(record, "ordinal", ordinal), Map.put(counters, domain, ordinal)}
      end)

    numbered
  end

  defp duplicate_id_errors(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {id, count} when count > 1 -> [{:duplicate_record_id, id}]
      {_id, _count} -> []
    end)
  end

  defp record_errors(record, id_set) do
    record_id = Map.get(record, "record_id", "<unknown>")

    missing =
      Enum.flat_map(@required_fields, fn field ->
        if Map.has_key?(record, field),
          do: [],
          else: [{:invalid_record, record_id, "missing #{field}"}]
      end)

    missing ++
      additional_field_errors(record, record_id) ++
      kind_errors(record, record_id) ++
      type_errors(record, record_id) ++
      identity_errors(record, record_id) ++
      relation_errors(record, id_set, record_id) ++
      reference_errors(record, id_set, record_id) ++
      payload_errors(record, record_id)
  end

  defp additional_field_errors(record, record_id) do
    unknown = Map.keys(record) -- @allowed_fields

    summary_field_errors =
      if Map.get(record, "record_kind") == "adr_summary" do
        []
      else
        present = Enum.filter(@summary_fields, &Map.has_key?(record, &1))

        if present == [],
          do: [],
          else: ["summary-only fields present: #{Enum.join(present, ", ")}"]
      end

    Enum.map(unknown, &{:invalid_record, record_id, "unknown field #{&1}"}) ++
      Enum.map(summary_field_errors, &{:invalid_record, record_id, &1})
  end

  defp kind_errors(record, record_id) do
    if Map.get(record, "record_kind") in @record_kinds,
      do: [],
      else: [{:invalid_record, record_id, "unknown record_kind"}]
  end

  defp type_errors(record, record_id) do
    errors =
      []
      |> error_if(Map.get(record, "schema_version") != @schema_version, "invalid schema_version")
      |> error_if(
        not non_empty_string?(Map.get(record, "record_id")),
        "record_id must be a string"
      )
      |> error_if(not valid_domain?(Map.get(record, "domain")), "domain is invalid")
      |> error_if(not valid_record_id?(Map.get(record, "record_id")), "record_id is invalid")
      |> error_if(not positive_integer?(Map.get(record, "ordinal")), "ordinal must be positive")
      |> error_if(not positive_integer?(Map.get(record, "adr_id")), "adr_id must be positive")
      |> error_if(
        not (is_nil(Map.get(record, "rule_number")) or
               positive_integer?(Map.get(record, "rule_number"))),
        "rule_number must be nil or positive"
      )
      |> error_if(
        Map.get(record, "polarity") not in [nil, "positive", "negative"],
        "invalid polarity"
      )
      |> error_if(
        not non_empty_string?(Map.get(record, "adr_title")),
        "adr_title must be present"
      )
      |> error_if(
        not non_empty_string?(Map.get(record, "routing_title")),
        "routing_title must be present"
      )
      |> error_if(
        not (is_nil(Map.get(record, "rule_title")) or
               non_empty_string?(Map.get(record, "rule_title"))),
        "rule_title must be nil or present"
      )
      |> error_if(
        not non_empty_string_list?(Map.get(record, "heading_path")),
        "invalid heading_path"
      )
      |> error_if(not non_empty_string?(Map.get(record, "status")), "status must be present")
      |> error_if(not iso_date?(Map.get(record, "date")), "date must use YYYY-MM-DD")
      |> error_if(
        not (is_nil(Map.get(record, "updated")) or iso_date?(Map.get(record, "updated"))),
        "updated must be nil or YYYY-MM-DD"
      )
      |> error_if(not unique_string_list?(Map.get(record, "tags")), "invalid tags")
      |> error_if(
        not non_empty_string?(Map.get(record, "source_description")),
        "source_description must be present"
      )
      |> error_if(
        not non_empty_string?(Map.get(record, "routing_description")),
        "routing_description must be present"
      )
      |> error_if(not valid_applies_to?(Map.get(record, "applies_to")), "invalid applies_to")
      |> error_if(not valid_source_path?(Map.get(record, "source_path")), "invalid source_path")
      |> error_if(
        not positive_integer?(Map.get(record, "source_start_line")),
        "source_start_line must be positive"
      )
      |> error_if(
        not positive_integer?(Map.get(record, "source_end_line")),
        "source_end_line must be positive"
      )
      |> error_if(
        not unique_non_empty_string_list?(Map.get(record, "languages")),
        "invalid languages"
      )
      |> error_if(not is_list(Map.get(record, "references")), "references must be a list")

    Enum.map(errors, &{:invalid_record, record_id, &1})
  end

  defp identity_errors(record, record_id) do
    domain = Map.get(record, "domain")
    adr_id = Map.get(record, "adr_id")
    rule_number = Map.get(record, "rule_number")
    kind = Map.get(record, "record_kind")
    base_id = if is_binary(domain) and is_integer(adr_id), do: "#{domain}:adr-#{pad(adr_id, 3)}"

    errors =
      case kind do
        "adr_summary" ->
          []
          |> error_if(record_id != base_id, "ADR summary record_id does not match its metadata")
          |> error_if(Map.get(record, "parent_id") != nil, "ADR summary parent_id must be nil")
          |> error_if(
            Map.get(record, "hydrate_id") != record_id,
            "ADR summary must hydrate itself"
          )
          |> error_if(not is_nil(rule_number), "ADR summary rule_number must be nil")
          |> error_if(
            not is_nil(Map.get(record, "rule_title")),
            "ADR summary rule_title must be nil"
          )
          |> error_if(not is_nil(Map.get(record, "polarity")), "ADR summary polarity must be nil")
          |> error_if(
            Enum.any?(@summary_fields, &(not non_empty_string?(Map.get(record, &1)))),
            "ADR summary sections must be present"
          )

        "supporting" ->
          []
          |> error_if(
            not (is_binary(base_id) and is_binary(record_id) and
                   Regex.match?(
                     ~r/^#{Regex.escape(base_id)}:supporting:[a-z0-9]+(?:-[a-z0-9]+)*$/,
                     record_id
                   )),
            "supporting record_id does not match its metadata"
          )
          |> error_if(
            Map.get(record, "parent_id") != base_id,
            "supporting parent_id must be the ADR"
          )
          |> error_if(
            Map.get(record, "hydrate_id") != record_id,
            "supporting record must hydrate itself"
          )
          |> error_if(not is_nil(rule_number), "supporting rule_number must be nil")
          |> error_if(
            not is_nil(Map.get(record, "rule_title")),
            "supporting rule_title must be nil"
          )
          |> error_if(not is_nil(Map.get(record, "polarity")), "supporting polarity must be nil")

        "rule" ->
          expected =
            if is_binary(base_id) and is_integer(rule_number),
              do: "#{base_id}:rule-#{pad(rule_number, 2)}"

          []
          |> error_if(record_id != expected, "Rule record_id does not match its metadata")
          |> error_if(Map.get(record, "parent_id") != base_id, "Rule parent_id must be the ADR")
          |> error_if(Map.get(record, "hydrate_id") != record_id, "Rule must hydrate itself")
          |> error_if(
            not non_empty_string?(Map.get(record, "rule_title")),
            "Rule title must be present"
          )
          |> error_if(not is_nil(Map.get(record, "polarity")), "Rule polarity must be nil")

        "example" ->
          rule_id =
            if is_binary(base_id) and is_integer(rule_number),
              do: "#{base_id}:rule-#{pad(rule_number, 2)}"

          polarity = Map.get(record, "polarity")
          expected_kind = if polarity == "positive", do: "correct", else: "wrong"

          []
          |> error_if(
            not (is_binary(rule_id) and is_binary(record_id) and
                   Regex.match?(
                     ~r/^#{Regex.escape(rule_id)}:example:#{expected_kind}:[0-9]{2}$/,
                     record_id
                   )),
            "example record_id does not match its polarity"
          )
          |> error_if(
            Map.get(record, "parent_id") != rule_id,
            "example parent_id must be the Rule"
          )
          |> error_if(Map.get(record, "hydrate_id") != rule_id, "example must hydrate its Rule")
          |> error_if(
            not non_empty_string?(Map.get(record, "rule_title")),
            "example rule title must be present"
          )
          |> error_if(polarity not in ["positive", "negative"], "example polarity is required")

        _ ->
          []
      end

    Enum.map(errors, &{:invalid_record, record_id, &1})
  end

  defp relation_errors(record, id_set, record_id) do
    parent_id = Map.get(record, "parent_id")
    hydrate_id = Map.get(record, "hydrate_id")

    parent_errors =
      cond do
        Map.get(record, "record_kind") == "adr_summary" and is_nil(parent_id) -> []
        is_binary(parent_id) and MapSet.member?(id_set, parent_id) -> []
        true -> [{:invalid_parent, record_id, parent_id}]
      end

    hydrate_errors =
      if is_binary(hydrate_id) and MapSet.member?(id_set, hydrate_id),
        do: [],
        else: [{:invalid_record, record_id, "invalid hydrate_id"}]

    parent_errors ++ hydrate_errors
  end

  defp reference_errors(record, id_set, record_id) do
    start_line = Map.get(record, "source_start_line")
    end_line = Map.get(record, "source_end_line")

    if is_list(Map.get(record, "references")) do
      record
      |> Map.get("references")
      |> Enum.flat_map(fn reference ->
        valid_keys =
          is_map(reference) and
            Map.keys(reference) |> Enum.sort() == ~w(raw_text source_line target_id)

        target_id = if is_map(reference), do: Map.get(reference, "target_id")
        source_line = if is_map(reference), do: Map.get(reference, "source_line")
        raw_text = if is_map(reference), do: Map.get(reference, "raw_text")

        errors =
          []
          |> error_if(not valid_keys, "reference fields are invalid")
          |> error_if(not MapSet.member?(id_set, target_id), "reference target does not exist")
          |> error_if(
            not adr_or_rule_record_id?(target_id),
            "reference target must be an ADR summary or Rule"
          )
          |> error_if(not non_empty_string?(raw_text), "reference raw_text must be present")
          |> error_if(
            not (is_integer(source_line) and is_integer(start_line) and is_integer(end_line) and
                   source_line >= start_line and source_line <= end_line),
            "reference source_line is outside the record span"
          )

        Enum.map(errors, &{:invalid_record, record_id, &1})
      end)
    else
      []
    end
  end

  defp payload_errors(record, record_id) do
    display_text = Map.get(record, "display_text")
    retrieval_text = Map.get(record, "retrieval_text")

    text_errors =
      if is_binary(retrieval_text) and String.trim(retrieval_text) != "",
        do: [],
        else: [{:invalid_record, record_id, "retrieval_text must not be empty"}]

    display_errors =
      if is_binary(display_text) and String.trim(display_text) != "",
        do: [],
        else: [{:invalid_record, record_id, "display_text must not be empty"}]

    source_hash_errors =
      if is_binary(display_text) and Map.get(record, "source_sha256") == sha256(display_text),
        do: [],
        else: [{:invalid_record, record_id, "source_sha256 mismatch"}]

    retrieval_hash_errors =
      if is_binary(retrieval_text) and
           Map.get(record, "retrieval_sha256") == sha256(retrieval_text),
         do: [],
         else: [{:invalid_record, record_id, "retrieval_sha256 mismatch"}]

    span_errors =
      if is_integer(Map.get(record, "source_start_line")) and
           is_integer(Map.get(record, "source_end_line")) and
           Map.get(record, "source_start_line") <= Map.get(record, "source_end_line"),
         do: [],
         else: [{:invalid_record, record_id, "source line span is invalid"}]

    text_errors ++ display_errors ++ source_hash_errors ++ retrieval_hash_errors ++ span_errors
  end

  defp duplicate_retrieval_errors(records) do
    records
    |> Enum.group_by(&Map.get(&1, "retrieval_text"))
    |> Enum.flat_map(fn
      {text, duplicates} when is_binary(text) and length(duplicates) > 1 ->
        [
          {:invalid_record, Map.get(hd(duplicates), "record_id", "<unknown>"),
           "duplicate retrieval_text"}
        ]

      {_text, _records} ->
        []
    end)
  end

  defp ordinal_errors(records) do
    records
    |> Enum.group_by(&Map.get(&1, "domain"))
    |> Enum.flat_map(fn {domain, domain_records} ->
      ordinals = Enum.map(domain_records, &Map.get(&1, "ordinal"))

      if ordinals == Enum.to_list(1..length(domain_records)),
        do: [],
        else: [{:invalid_record, to_string(domain), "ordinals must be contiguous from 1"}]
    end)
  end

  defp languages(content) do
    {found, _fence} =
      content
      |> String.split("\n", trim: false)
      |> Enum.reduce({[], nil}, &language_line/2)

    Enum.uniq(found)
  end

  defp language_line(line, {found, nil}) do
    case Regex.run(~r/^\s*(`{3,}|~{3,})([^\s`]*)/, line) do
      [_, marker, language] ->
        next = {String.first(marker), String.length(marker)}
        languages = if language == "", do: found, else: found ++ [language]
        {languages, next}

      nil ->
        {found, nil}
    end
  end

  defp language_line(line, {found, {character, length} = fence}) do
    escaped = Regex.escape(character)

    if Regex.match?(~r/^\s*#{escaped}{#{length},}\s*$/, line),
      do: {found, nil},
      else: {found, fence}
  end

  defp source_title(%Adr{} = adr), do: Map.get(adr.frontmatter, "title", adr.document.title)

  defp source_description(%Adr{} = adr) do
    Map.get(adr.frontmatter, "description", adr.description)
  end

  defp retrieval_join(parts) do
    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp without_document_title([_document_title | rest]), do: rest
  defp without_document_title([]), do: []

  defp normalize_date(nil), do: nil
  defp normalize_date(%Date{} = date), do: Date.to_iso8601(date)
  defp normalize_date(%DateTime{} = date), do: DateTime.to_iso8601(date)
  defp normalize_date(value) when is_binary(value), do: value
  defp normalize_date(value), do: to_string(value)

  defp error_if(errors, true, message), do: [message | errors]
  defp error_if(errors, false, _message), do: errors

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp non_empty_string_list?(value) do
    is_list(value) and value != [] and Enum.all?(value, &non_empty_string?/1)
  end

  defp unique_string_list?(value) do
    is_list(value) and Enum.all?(value, &non_empty_string?/1) and
      length(value) == length(Enum.uniq(value))
  end

  defp unique_non_empty_string_list?(value), do: unique_string_list?(value)

  defp iso_date?(value) when is_binary(value) do
    Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value) and
      match?({:ok, _date}, Date.from_iso8601(value))
  end

  defp iso_date?(_value), do: false

  defp valid_source_path?(value) when is_binary(value) do
    Regex.match?(~r|^adrs/[a-z][a-z0-9-]*/adr-[0-9]{3}-[^/]+\.md$|, value)
  end

  defp valid_source_path?(_value), do: false

  defp valid_domain?(value) when is_binary(value),
    do: Regex.match?(~r/^[a-z][a-z0-9-]*$/, value)

  defp valid_domain?(_value), do: false

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

  defp valid_applies_to?(value) when is_map(value) do
    Map.keys(value) -- ["paths", "content_match"] == [] and
      Enum.all?(value, fn {_key, entries} -> unique_string_list?(entries) end)
  end

  defp valid_applies_to?(_value), do: false

  defp slug(title) do
    title
    |> String.downcase()
    |> String.replace("`", "")
    |> String.replace(~r/[^\p{L}\p{N}\s-]/u, "")
    |> String.replace(~r/[\s-]+/u, "-")
    |> String.trim("-")
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp pad(value, width) do
    value
    |> Integer.to_string()
    |> String.pad_leading(width, "0")
  end
end
