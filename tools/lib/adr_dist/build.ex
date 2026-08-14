defmodule AdrDist.Build do
  @moduledoc """
  Orchestrates source loading, record construction, staged rendering, validation,
  and atomic publication of the ADR distributions.
  """

  alias AdrDist.{Error, Renderer, Retrieval, Source, Validator}

  @type build_summary :: %{
          required(String.t()) => non_neg_integer() | [String.t()]
        }

  @spec run() :: {:ok, build_summary()} | {:error, Error.t()}
  def run, do: build("adrs", "dist")

  @spec build(String.t(), String.t()) :: {:ok, build_summary()} | {:error, Error.t()}
  def build(source_root, output_root)
      when is_binary(source_root) and is_binary(output_root) do
    case Source.load(source_root) do
      {:ok, domains} -> build_domains(domains, output_root)
      {:error, %Error{}} = error -> error
    end
  rescue
    error ->
      {:error,
       Error.new(:build_failed, Exception.message(error),
         path: output_root,
         details: error.__struct__
       )}
  end

  defp build_domains(domains, output_root) do
    adrs = Enum.flat_map(domains, & &1.adrs)

    case Retrieval.build(adrs) do
      {:ok, records} ->
        validate_and_publish(domains, records, output_root)

      {:error, [%Error{} = error | _remaining]} ->
        {:error, error}

      {:error, errors} ->
        {:error,
         Error.new(:retrieval_build_failed, "could not build retrieval records", details: errors)}
    end
  end

  defp validate_and_publish(domains, records, output_root) do
    case Validator.validate_records(records) do
      :ok -> publish(domains, records, output_root)
      {:error, %Error{}} = error -> error
    end
  end

  defp publish(domains, records, output_root) do
    staging_root = temporary_sibling(output_root, "staging")

    try do
      case Renderer.render(staging_root, domains, records) do
        :ok -> validate_staging_and_promote(staging_root, output_root, domains, records)
        {:error, %Error{}} = error -> error
      end
    after
      File.rm_rf!(staging_root)
    end
  end

  defp validate_staging_and_promote(staging_root, output_root, domains, records) do
    case Validator.validate_staged(staging_root, domains, records) do
      :ok -> promote_and_summarize(staging_root, output_root, domains, records)
      {:error, %Error{}} = error -> error
    end
  end

  defp promote_and_summarize(staging_root, output_root, domains, records) do
    case promote(staging_root, output_root) do
      :ok -> {:ok, summary(domains, records)}
      {:error, %Error{}} = error -> error
    end
  end

  defp promote(staging_root, output_root) do
    expanded_output = Path.expand(output_root)
    File.mkdir_p!(Path.dirname(expanded_output))

    if File.exists?(expanded_output) do
      replace_existing(staging_root, expanded_output)
    else
      rename(staging_root, expanded_output, :publish_failed)
    end
  end

  defp replace_existing(staging_root, output_root) do
    backup_root = temporary_sibling(output_root, "backup")

    case File.rename(output_root, backup_root) do
      :ok ->
        promote_over_backup(staging_root, output_root, backup_root)

      {:error, reason} ->
        {:error,
         Error.new(:publish_failed, "could not stage the existing distribution for replacement",
           path: output_root,
           details: reason
         )}
    end
  end

  defp promote_over_backup(staging_root, output_root, backup_root) do
    case File.rename(staging_root, output_root) do
      :ok ->
        File.rm_rf!(backup_root)
        :ok

      {:error, reason} ->
        restore_result = File.rename(backup_root, output_root)

        {:error,
         Error.new(:publish_failed, "could not promote the validated distribution",
           path: output_root,
           details: %{promote: reason, restore: restore_result}
         )}
    end
  end

  defp rename(source, destination, code) do
    case File.rename(source, destination) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(code, "could not publish the validated distribution",
           path: destination,
           details: reason
         )}
    end
  end

  defp summary(domains, records) do
    counts = Retrieval.counts(records)

    %{
      "domains" => Enum.map(domains, & &1.domain),
      "records" => counts["records"],
      "adrs" => counts["adrs"],
      "rules" => counts["rules"],
      "examples" => counts["examples"],
      "supporting" => counts["supporting"]
    }
  end

  defp temporary_sibling(path, purpose) do
    expanded = Path.expand(path)
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(expanded), ".#{Path.basename(expanded)}.#{purpose}.#{suffix}")
  end
end
