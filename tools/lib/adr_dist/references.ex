defmodule AdrDist.References.Reference do
  @moduledoc false

  @enforce_keys [:raw_text, :source_line, :domain, :adr_number, :rule_numbers]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          raw_text: String.t(),
          source_line: pos_integer(),
          domain: String.t(),
          adr_number: pos_integer(),
          rule_numbers: [pos_integer()]
        }
end

defmodule AdrDist.References do
  @moduledoc """
  Extracts domain-aware ADR citations and resolves them to stable retrieval IDs.

  Bare ADR numbers resolve inside the source ADR's domain. A citation that names
  another domain resolves there. Rule-qualified citations resolve to rule IDs;
  ADR-only citations resolve to ADR IDs. Every resolved target retains the exact
  citation text and its one-based source line as retrieval evidence.
  """

  alias AdrDist.References.Reference

  @citation ~r/(?:(`[a-z][a-z0-9-]+`|elixir-[a-z0-9-]+)\s+)?ADR-(\d{3})(?![A-Za-z0-9])(?:\s+Rules?\s+(\d+(?:(?:,\s*(?:and\s+)?|\s+and\s+)\d+)*))?/u

  @type extract_error :: {:malformed_reference, pos_integer(), String.t()}
  @type resolution_error :: {:unresolved_reference, String.t(), String.t(), pos_integer()}
  @type resolved_reference :: %{
          required(String.t()) => String.t() | pos_integer()
        }

  @spec extract(String.t(), String.t()) ::
          {:ok, [Reference.t()]} | {:error, [extract_error()]}
  def extract(content, current_domain) when is_binary(content) and is_binary(current_domain) do
    matches = citation_matches(content, current_domain)
    malformed = malformed_references(content, matches)

    case malformed do
      [] -> {:ok, Enum.map(matches, & &1.reference)}
      _ -> {:error, malformed}
    end
  end

  @spec resolve(String.t(), String.t(), MapSet.t(String.t()), String.t()) ::
          {:ok, [resolved_reference()]} | {:error, [extract_error() | resolution_error()]}
  def resolve(content, current_domain, known_ids, source_record_id)
      when is_binary(content) and is_binary(current_domain) and is_binary(source_record_id) do
    case extract(content, current_domain) do
      {:ok, references} -> resolve_references(references, known_ids, source_record_id)
      {:error, _errors} = error -> error
    end
  end

  defp citation_matches(content, current_domain) do
    @citation
    |> Regex.scan(content, return: :index)
    |> Enum.map(&to_match(&1, content, current_domain))
    |> Enum.reject(&identity_heading?(content, &1))
  end

  defp to_match([full, qualifier, adr, rules], content, current_domain) do
    {start, length} = full
    source_line = source_line(content, start)
    raw_text = capture_text(content, full)
    qualifier_text = capture_text(content, qualifier)
    domain = qualifier_domain(qualifier_text) || current_domain

    rule_numbers =
      content
      |> capture_text(rules)
      |> parse_rule_numbers()

    %{
      start: start,
      line_start: start - line_start_offset(content, start),
      length: length,
      reference: %Reference{
        raw_text: raw_text,
        source_line: source_line,
        domain: domain,
        adr_number: content |> capture_text(adr) |> String.to_integer(),
        rule_numbers: rule_numbers
      }
    }
  end

  defp to_match([full, qualifier, adr], content, current_domain) do
    to_match([full, qualifier, adr, {-1, 0}], content, current_domain)
  end

  defp capture_text(_content, {-1, 0}), do: ""
  defp capture_text(content, {start, length}), do: :binary.part(content, start, length)

  defp qualifier_domain(""), do: nil

  defp qualifier_domain(qualifier) do
    qualifier
    |> String.trim_leading("`")
    |> String.trim_trailing("`")
  end

  defp parse_rule_numbers(""), do: []

  defp parse_rule_numbers(rules) do
    ~r/\d+/
    |> Regex.scan(rules)
    |> List.flatten()
    |> Enum.map(&String.to_integer/1)
  end

  defp source_line(content, byte_offset) do
    content
    |> :binary.part(0, byte_offset)
    |> :binary.matches("\n")
    |> length()
    |> Kernel.+(1)
  end

  defp line_start_offset(content, byte_offset) do
    prefix = :binary.part(content, 0, byte_offset)

    case :binary.matches(prefix, "\n") do
      [] -> 0
      matches -> matches |> List.last() |> elem(0) |> Kernel.+(1)
    end
  end

  defp identity_heading?(content, match) do
    line = line_at(content, match.reference.source_line)
    String.match?(line, ~r/^\s*#\s+ADR-\d{3}:/)
  end

  defp malformed_references(content, matches) do
    content
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if String.contains?(line, "ADR-") and not String.match?(line, ~r/^\s*#\s+ADR-\d{3}:/) do
        malformed_on_line(line, line_number, matches)
      else
        []
      end
    end)
  end

  defp malformed_on_line(line, line_number, matches) do
    line_matches = Enum.filter(matches, &(&1.reference.source_line == line_number))

    uncovered =
      :binary.matches(line, "ADR-")
      |> Enum.reject(fn {adr_start, _length} ->
        Enum.any?(line_matches, fn match ->
          line_start = match.line_start
          adr_start >= line_start and adr_start < line_start + match.length
        end)
      end)

    continuation_errors =
      Enum.flat_map(line_matches, fn match ->
        line_start = match.line_start
        suffix_start = line_start + match.length
        suffix = :binary.part(line, suffix_start, byte_size(line) - suffix_start)

        if malformed_suffix?(match.reference.raw_text, suffix) do
          [{suffix_start, 0}]
        else
          []
        end
      end)

    (uncovered ++ continuation_errors)
    |> Enum.map(fn {_offset, _length} ->
      {:malformed_reference, line_number, String.trim(line)}
    end)
    |> Enum.uniq()
  end

  defp malformed_suffix?(raw_text, suffix) do
    cond do
      Regex.match?(~r/^\s+Rules?\b/u, suffix) ->
        true

      String.contains?(raw_text, " Rule") and
          Regex.match?(~r/^(?:[A-Za-z0-9_]|\s*(?:-|\/|&|\+)\s*\d+)/u, suffix) ->
        true

      String.contains?(raw_text, " Rule") and
          Regex.match?(~r/^\s+(?:and|or|through|to)\b/u, suffix) ->
        true

      String.contains?(raw_text, " Rule") and
          Regex.match?(~r/^\s*,\s*(?:\d|(?:and|or)\s+\d)/u, suffix) ->
        true

      String.contains?(raw_text, " Rule") and
          Regex.match?(~r/^\.\d/u, suffix) ->
        true

      true ->
        false
    end
  end

  defp line_at(content, line_number) do
    content
    |> String.split("\n", trim: false)
    |> Enum.at(line_number - 1, "")
  end

  defp resolve_references(references, known_ids, source_record_id) do
    {resolved, errors} =
      Enum.reduce(references, {[], []}, fn reference, {valid, invalid} ->
        Enum.reduce(reference_targets(reference), {valid, invalid}, fn target, {found, missing} ->
          if MapSet.member?(known_ids, target) do
            resolved = %{
              "target_id" => target,
              "raw_text" => reference.raw_text,
              "source_line" => reference.source_line
            }

            {[resolved | found], missing}
          else
            error =
              {:unresolved_reference, source_record_id, target, reference.source_line}

            {found, [error | missing]}
          end
        end)
      end)

    case errors do
      [] -> {:ok, Enum.reverse(resolved)}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp reference_targets(%Reference{rule_numbers: []} = reference) do
    [adr_id(reference.domain, reference.adr_number)]
  end

  defp reference_targets(%Reference{} = reference) do
    Enum.map(reference.rule_numbers, fn rule_number ->
      rule_id(reference.domain, reference.adr_number, rule_number)
    end)
  end

  defp adr_id(domain, adr_number), do: "#{domain}:adr-#{pad(adr_number, 3)}"

  defp rule_id(domain, adr_number, rule_number) do
    "#{adr_id(domain, adr_number)}:rule-#{pad(rule_number, 2)}"
  end

  defp pad(value, width) do
    value
    |> Integer.to_string()
    |> String.pad_leading(width, "0")
  end
end
