defmodule AdrDist.Validator do
  @moduledoc """
  Validates in-memory records and the fully rendered staging tree before publish.

  `AdrDist.Retrieval.validate/1` implements the retrieval-v1 schema semantics so
  validation does not depend on a particular JSON Schema library.
  """

  alias AdrDist.{Error, Retrieval}
  alias AdrDist.Source.Domain

  @legacy_fields ~w(applies_to body description domain id tags title)

  @spec validate_records([map()]) :: :ok | {:error, Error.t()}
  def validate_records(records) when is_list(records) do
    case Retrieval.validate(records) do
      {:ok, ^records} ->
        :ok

      {:ok, _different_records} ->
        {:error, Error.new(:record_validation_failed, "validator changed records")}

      {:error, errors} ->
        {:error,
         Error.new(:record_validation_failed, "retrieval records violate retrieval-v1",
           details: errors
         )}
    end
  end

  @spec validate_staged(String.t(), [Domain.t()], [map()]) :: :ok | {:error, Error.t()}
  def validate_staged(staging_root, domains, expected_records)
      when is_binary(staging_root) and is_list(domains) and is_list(expected_records) do
    generated_records = read_domain_records!(staging_root, domains)

    case Retrieval.validate(generated_records) do
      {:ok, ^expected_records} ->
        validate_legacy_then_catalog(staging_root, domains, generated_records)

      {:ok, _different_records} ->
        {:error,
         Error.new(:staged_validation_failed, "rendered rows differ from validated records",
           path: staging_root
         )}

      {:error, errors} ->
        {:error,
         Error.new(:staged_validation_failed, "rendered rows violate retrieval-v1",
           path: staging_root,
           details: errors
         )}
    end
  rescue
    error ->
      {:error,
       Error.new(:staged_validation_failed, Exception.message(error),
         path: staging_root,
         details: error.__struct__
       )}
  end

  defp validate_legacy_then_catalog(staging_root, domains, generated_records) do
    case validate_legacy(staging_root, domains) do
      :ok -> validate_catalog(staging_root, domains, generated_records)
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_legacy(staging_root, domains) do
    errors = Enum.flat_map(domains, &legacy_domain_errors(staging_root, &1))

    case errors do
      [] ->
        :ok

      _ ->
        {:error,
         Error.new(:legacy_validation_failed, "staged legacy adrs.jsonl is invalid",
           path: staging_root,
           details: errors
         )}
    end
  end

  defp legacy_domain_errors(staging_root, %Domain{} = domain_data) do
    path = Path.join([staging_root, domain_data.domain, "adrs.jsonl"])

    case read_jsonl(path) do
      {:ok, rows} -> compare_legacy_rows(path, rows, domain_data)
      {:error, reason} -> ["#{path}: could not decode legacy JSONL: #{reason}"]
    end
  end

  defp compare_legacy_rows(path, rows, domain_data) do
    expected = Enum.map(domain_data.adrs, &legacy_row/1)

    field_errors =
      rows
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {row, line} ->
        if Enum.sort(Map.keys(row)) == Enum.sort(@legacy_fields),
          do: [],
          else: ["#{path}:#{line}: legacy row must contain exactly seven public fields"]
      end)

    count_errors =
      if length(rows) == length(expected),
        do: [],
        else: ["#{path}: expected #{length(expected)} rows, found #{length(rows)}"]

    value_errors =
      if rows == expected,
        do: [],
        else: ["#{path}: legacy rows do not match loaded manifest/source ADR values"]

    field_errors ++ count_errors ++ value_errors
  end

  defp legacy_row(adr) do
    %{
      "id" => adr.id,
      "domain" => adr.domain,
      "title" => adr.title,
      "description" => adr.description,
      "tags" => Map.get(adr.frontmatter, "tags", []),
      "applies_to" => adr.applies_to,
      "body" => adr.body
    }
  end

  defp read_domain_records!(staging_root, domains) do
    Enum.flat_map(domains, fn domain_data ->
      staging_root
      |> Path.join(domain_data.domain)
      |> Path.join("retrieval.jsonl")
      |> read_jsonl!()
    end)
  end

  defp validate_catalog(staging_root, domains, generated_records) do
    catalog_path = Path.join(staging_root, "retrieval-catalog.json")
    catalog = catalog_path |> File.read!() |> Jason.decode!()
    expected_domains = Enum.map(domains, & &1.domain)
    catalog_domains = Enum.map(catalog["domains"], & &1["domain"])

    metadata_errors =
      []
      |> add_error(
        catalog["schema_version"] != Retrieval.schema_version(),
        "invalid schema_version"
      )
      |> add_error(
        catalog["counts"] != Retrieval.counts(generated_records),
        "invalid aggregate counts"
      )
      |> add_error(catalog_domains != expected_domains, "domains are missing or not sorted")

    entry_errors =
      Enum.flat_map(catalog["domains"] || [], fn entry ->
        validate_catalog_entry(staging_root, generated_records, entry)
      end)

    case Enum.reverse(metadata_errors) ++ entry_errors do
      [] ->
        :ok

      errors ->
        {:error,
         Error.new(:catalog_validation_failed, "retrieval catalog is invalid",
           path: catalog_path,
           details: errors
         )}
    end
  end

  defp validate_catalog_entry(staging_root, generated_records, entry) do
    artifact = entry["artifact"]

    artifact_path =
      if is_binary(artifact), do: Path.join(staging_root, artifact), else: staging_root

    domain_records = Enum.filter(generated_records, &(&1["domain"] == entry["domain"]))

    []
    |> add_error(
      not File.regular?(artifact_path),
      "missing artifact for #{inspect(entry["domain"])}"
    )
    |> add_error(
      File.regular?(artifact_path) and
        entry["sha256"] != artifact_path |> File.read!() |> sha256(),
      "checksum mismatch for #{inspect(entry["domain"])}"
    )
    |> add_error(
      entry["counts"] != Retrieval.counts(domain_records),
      "count mismatch for #{inspect(entry["domain"])}"
    )
    |> Enum.reverse()
  end

  defp read_jsonl!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp read_jsonl(path) do
    case File.read(path) do
      {:ok, contents} ->
        decode_jsonl(contents, path)

      {:error, reason} ->
        {:error, Exception.message(%File.Error{reason: reason, action: "read", path: path})}
    end
  end

  defp decode_jsonl(contents, path) do
    contents
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, line_number}, {:ok, rows} ->
      if String.trim(line) == "" do
        {:cont, {:ok, rows}}
      else
        decode_jsonl_line(path, line, line_number, rows)
      end
    end)
    |> reverse_jsonl_rows()
  end

  defp decode_jsonl_line(path, line, line_number, rows) do
    case Jason.decode(line) do
      {:ok, row} when is_map(row) ->
        {:cont, {:ok, [row | rows]}}

      {:ok, _value} ->
        {:halt, {:error, "#{path}:#{line_number}: expected a JSON object"}}

      {:error, reason} ->
        {:halt, {:error, "#{path}:#{line_number}: invalid JSON: #{Exception.message(reason)}"}}
    end
  end

  defp reverse_jsonl_rows({:ok, rows}), do: {:ok, Enum.reverse(rows)}
  defp reverse_jsonl_rows({:error, _reason} = error), do: error

  defp add_error(errors, true, message), do: [message | errors]
  defp add_error(errors, false, _message), do: errors

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
