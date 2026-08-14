defmodule AdrDist.Source.Domain do
  @moduledoc false

  alias AdrDist.Adr

  @enforce_keys [:domain, :manifest, :adrs]
  defstruct @enforce_keys

  @type t :: %__MODULE__{domain: String.t(), manifest: map(), adrs: [Adr.t()]}
end

defmodule AdrDist.Source do
  @moduledoc """
  Loads manifest-backed ADR domains and validates source identity and coverage.
  """

  alias AdrDist.{Adr, Error, Markdown}
  alias AdrDist.Source.Domain

  @spec load(String.t()) :: {:ok, [Domain.t()]} | {:error, Error.t()}
  def load(source_root) when is_binary(source_root) do
    result =
      if File.dir?(source_root) do
        load_source_root(source_root)
      else
        {:error, Error.new(:invalid_source, "ADR source root does not exist", path: source_root)}
      end

    result
  rescue
    error ->
      {:error,
       Error.new(:source_load_failed, Exception.message(error),
         path: source_root,
         details: error.__struct__
       )}
  end

  defp load_source_root(source_root) do
    domains =
      source_root
      |> File.ls!()
      |> Enum.sort()
      |> Enum.filter(&domain_directory?(source_root, &1))

    if domains == [] do
      {:error,
       Error.new(:invalid_source, "no manifest-backed ADR domains found", path: source_root)}
    else
      domains
      |> Enum.reduce_while({:ok, []}, fn domain, {:ok, loaded} ->
        case load_domain(source_root, domain) do
          {:ok, domain_data} -> {:cont, {:ok, [domain_data | loaded]}}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
      |> reverse_success()
    end
  end

  defp domain_directory?(source_root, name) do
    File.dir?(Path.join(source_root, name)) and
      File.regular?(Path.join([source_root, name, "adr-rules.yaml"]))
  end

  defp load_domain(source_root, domain) do
    manifest_path = Path.join([source_root, domain, "adr-rules.yaml"])

    case YamlElixir.read_from_file(manifest_path) do
      {:ok, manifest} when is_map(manifest) ->
        validate_loaded_domain(source_root, domain, manifest_path, manifest)

      {:ok, _value} ->
        {:error,
         Error.new(:invalid_manifest, "manifest YAML must contain a mapping",
           path: manifest_path,
           line: 1
         )}

      {:error, error} ->
        {:error, yaml_error(:invalid_manifest, "manifest", manifest_path, error, 0)}
    end
  end

  defp validate_loaded_domain(source_root, domain, manifest_path, manifest) do
    cond do
      manifest["domain"] != domain ->
        {:error,
         Error.new(
           :manifest_domain_mismatch,
           "manifest domain #{inspect(manifest["domain"])} does not match directory #{domain}",
           path: manifest_path
         )}

      not is_list(manifest["adrs"]) ->
        {:error,
         Error.new(:invalid_manifest, "manifest must contain an adrs list", path: manifest_path)}

      true ->
        case validate_domain_manifest(source_root, domain, manifest) do
          :ok -> load_domain_adrs(source_root, domain, manifest)
          {:error, %Error{}} = error -> error
        end
    end
  end

  defp validate_domain_manifest(source_root, domain, manifest) do
    entries = manifest["adrs"]
    ids = Enum.map(entries, & &1["id"])
    files = Enum.map(entries, & &1["file"])

    actual_files =
      source_root
      |> Path.join(domain)
      |> Path.join("adr-*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    declared_files = files |> Enum.filter(&is_binary/1) |> Enum.sort()

    errors =
      manifest_metadata_errors(manifest) ++
        duplicate_value_errors(ids, "ADR id") ++
        duplicate_value_errors(files, "ADR file") ++
        manifest_sequence_errors(ids) ++
        manifest_entry_errors(entries) ++
        coverage_errors(declared_files, actual_files)

    case errors do
      [] ->
        :ok

      _ ->
        path = Path.join([source_root, domain, "adr-rules.yaml"])

        {:error,
         Error.new(:invalid_manifest, Enum.join(errors, "; "), path: path, details: errors)}
    end
  end

  defp manifest_metadata_errors(manifest) do
    Enum.flat_map(["title", "description"], fn field ->
      if non_empty_string?(manifest[field]), do: [], else: ["manifest #{field} must be present"]
    end)
  end

  defp duplicate_value_errors(values, label) do
    values
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {value, count} when count > 1 -> ["duplicate #{label} #{inspect(value)}"]
      {_value, _count} -> []
    end)
  end

  defp manifest_sequence_errors(ids) do
    if ids != [] and Enum.all?(ids, &is_integer/1) and ids == Enum.to_list(1..length(ids)),
      do: [],
      else: ["manifest ADR ids must be contiguous and ordered from 1"]
  end

  defp manifest_entry_errors(entries) do
    Enum.flat_map(entries, fn entry ->
      id = entry["id"]
      file = entry["file"]

      invalid_file =
        if is_integer(id) and is_binary(file) and
             Regex.match?(~r/^adr-#{pad(id, 3)}-[a-z0-9][a-z0-9-]*\.md$/, file),
           do: [],
           else: ["ADR #{inspect(id)} has an invalid filename #{inspect(file)}"]

      invalid_routing =
        Enum.flat_map(["title", "description"], fn field ->
          if non_empty_string?(entry[field]),
            do: [],
            else: ["ADR #{inspect(id)} routing #{field} must be present"]
        end)

      invalid_applies_to =
        if valid_applies_to?(entry["applies_to"] || %{}),
          do: [],
          else: ["ADR #{inspect(id)} applies_to is invalid"]

      invalid_file ++ invalid_routing ++ invalid_applies_to
    end)
  end

  defp coverage_errors(declared_files, actual_files) do
    missing = declared_files -- actual_files
    unlisted = actual_files -- declared_files

    Enum.map(missing, &"manifest file is missing: #{&1}") ++
      Enum.map(unlisted, &"ADR source is not listed in the manifest: #{&1}")
  end

  defp load_domain_adrs(source_root, domain, manifest) do
    manifest["adrs"]
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, adrs} ->
      case load_adr(source_root, domain, entry) do
        {:ok, adr} -> {:cont, {:ok, [adr | adrs]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, adrs} ->
        {:ok, %Domain{domain: domain, manifest: manifest, adrs: Enum.reverse(adrs)}}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp load_adr(source_root, domain, entry) do
    file = entry["file"]
    path = Path.join([source_root, domain, file || ""])

    cond do
      not is_integer(entry["id"]) or entry["id"] < 1 ->
        {:error, Error.new(:invalid_manifest, "manifest contains an invalid ADR id", path: path)}

      not is_binary(file) or not File.regular?(path) ->
        {:error, Error.new(:missing_source, "ADR source is missing", path: path)}

      true ->
        parse_adr(path, domain, entry)
    end
  end

  defp parse_adr(path, domain, entry) do
    raw = File.read!(path)

    case split_frontmatter(raw) do
      {:ok, frontmatter, body, line_offset} ->
        parse_adr_body(path, domain, entry, raw, frontmatter, body, line_offset)

      {:error, line, message} ->
        {:error, Error.new(:invalid_frontmatter, message, path: path, line: line)}

      {:yaml_error, error} ->
        {:error, yaml_error(:invalid_frontmatter, "frontmatter", path, error, 1)}
    end
  end

  defp parse_adr_body(path, domain, entry, raw, frontmatter, body, line_offset) do
    case Markdown.parse(body, line_offset) do
      {:ok, document} ->
        case validate_source_identity(entry, frontmatter, document) do
          :ok ->
            {:ok,
             %Adr{
               id: entry["id"],
               domain: domain,
               file: entry["file"],
               source_path: Path.join(["adrs", domain, entry["file"]]),
               title: entry["title"],
               description: entry["description"],
               applies_to: entry["applies_to"] || %{},
               raw: raw,
               body: body,
               frontmatter: frontmatter,
               document: document
             }}

          {:error, messages} ->
            {:error,
             Error.new(:source_identity_mismatch, Enum.join(messages, "; "),
               path: path,
               details: messages
             )}
        end

      {:error, {:invalid_markdown, line, message} = reason} ->
        {:error,
         Error.new(:invalid_markdown, message,
           path: path,
           line: line,
           details: reason
         )}
    end
  end

  defp validate_source_identity(entry, frontmatter, document) do
    expected_heading = "ADR-#{pad(entry["id"], 3)}: #{frontmatter["title"]}"

    errors =
      []
      |> add_error(frontmatter["type"] != "adr", "frontmatter type must be adr")
      |> add_error(
        frontmatter["id"] != entry["id"],
        "frontmatter id #{inspect(frontmatter["id"])} does not match manifest id #{entry["id"]}"
      )
      |> add_error(
        not non_empty_string?(frontmatter["title"]),
        "frontmatter title must be present"
      )
      |> add_error(
        not non_empty_string?(frontmatter["status"]),
        "frontmatter status must be present"
      )
      |> add_error(not valid_date?(frontmatter["date"]), "frontmatter date must be a valid date")
      |> add_error(
        not (is_nil(frontmatter["updated"]) or valid_date?(frontmatter["updated"])),
        "frontmatter updated must be a valid date"
      )
      |> add_error(
        not unique_string_list?(frontmatter["tags"]),
        "frontmatter tags must be a unique string list"
      )
      |> add_error(
        not non_empty_string?(frontmatter["description"]),
        "frontmatter description must be present"
      )
      |> add_error(
        document.title != expected_heading,
        "H1 #{inspect(document.title)} does not match #{inspect(expected_heading)}"
      )

    Enum.reverse(errors)
    |> case do
      [] -> :ok
      messages -> {:error, messages}
    end
  end

  defp split_frontmatter(raw) do
    lines = String.split(raw, "\n", trim: false)

    case lines do
      ["---" | rest] -> split_frontmatter_lines(rest)
      _ -> {:error, 1, "expected YAML frontmatter"}
    end
  end

  defp split_frontmatter_lines(lines_after_open) do
    case Enum.find_index(lines_after_open, &(String.trim(&1) == "---")) do
      nil ->
        {:error, 1, "unclosed YAML frontmatter"}

      closing_index ->
        frontmatter_text =
          lines_after_open
          |> Enum.take(closing_index)
          |> Enum.join("\n")

        body_lines = Enum.drop(lines_after_open, closing_index + 1)
        {leading_blank, content_lines} = Enum.split_while(body_lines, &(String.trim(&1) == ""))
        body = Enum.join(content_lines, "\n")
        line_offset = closing_index + 2 + length(leading_blank)

        case YamlElixir.read_from_string(frontmatter_text) do
          {:ok, frontmatter} when is_map(frontmatter) ->
            {:ok, frontmatter, body, line_offset}

          {:ok, _value} ->
            {:error, 2, "frontmatter YAML must contain a mapping"}

          {:error, error} ->
            {:yaml_error, error}
        end
    end
  end

  defp yaml_error(code, label, path, error, line_offset) do
    parser_line = Map.get(error, :line) || 1
    parser_message = Map.get(error, :message) || Exception.message(error)

    Error.new(code, "invalid #{label} YAML: #{parser_message}",
      path: path,
      line: parser_line + line_offset,
      details: %{
        column: Map.get(error, :column),
        parser: Map.get(error, :__struct__),
        type: Map.get(error, :type)
      }
    )
  end

  defp reverse_success({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_success({:error, %Error{}} = error), do: error

  defp add_error(errors, true, message), do: [message | errors]
  defp add_error(errors, false, _message), do: errors

  defp valid_applies_to?(value) when is_map(value) do
    Map.keys(value) -- ["paths", "content_match"] == [] and
      Enum.all?(value, fn {_key, entries} -> unique_string_list?(entries) end)
  end

  defp valid_applies_to?(_value), do: false

  defp unique_string_list?(value) do
    is_list(value) and Enum.all?(value, &non_empty_string?/1) and
      length(value) == length(Enum.uniq(value))
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_date?(%Date{}), do: true

  defp valid_date?(value) when is_binary(value) do
    match?({:ok, _date}, Date.from_iso8601(value))
  end

  defp valid_date?(_value), do: false

  defp pad(value, width) do
    value
    |> Integer.to_string()
    |> String.pad_leading(width, "0")
  end
end
