defmodule AdrDist.PackageValidatorTest do
  use ExUnit.Case, async: false

  alias AdrDist.{PackageValidator, TestSupport}

  setup do
    repo_root = TestSupport.temporary_directory!("adr-package-validator")

    Enum.each(~w(adrs dist eval schema), fn directory ->
      File.cp_r!(
        Path.join(TestSupport.repo_root(), directory),
        Path.join(repo_root, directory)
      )
    end)

    on_exit(fn -> File.rm_rf!(repo_root) end)
    %{repo_root: repo_root}
  end

  test "rejects empty display text and references to non-hydration records", context do
    retrieval_path =
      Path.join([
        context.repo_root,
        "dist",
        "elixir-code-anti-patterns",
        "retrieval.jsonl"
      ])

    records = TestSupport.jsonl!(retrieval_path)
    [first | rest] = records

    empty_display =
      first
      |> Map.put("display_text", "")
      |> Map.put("source_sha256", TestSupport.sha256(""))

    write_jsonl!(retrieval_path, [empty_display | rest])
    assert {:error, display_errors} = PackageValidator.validate(context.repo_root)

    assert Enum.any?(display_errors, &String.contains?(&1, "display_text must be a non-empty"))

    rule = Enum.find(records, &(&1["record_kind"] == "rule"))
    example = Enum.find(records, &(&1["record_kind"] == "example"))

    raw_text =
      context.repo_root
      |> Path.join(rule["source_path"])
      |> File.read!()
      |> String.split("\n", trim: false)
      |> Enum.at(rule["source_start_line"] - 1)
      |> String.trim()

    invalid_reference = %{
      "target_id" => example["record_id"],
      "raw_text" => raw_text,
      "source_line" => rule["source_start_line"]
    }

    invalid_reference_records =
      Enum.map(records, fn record ->
        if record["record_id"] == rule["record_id"] do
          Map.update!(record, "references", &(&1 ++ [invalid_reference]))
        else
          record
        end
      end)

    write_jsonl!(retrieval_path, invalid_reference_records)
    assert {:error, reference_errors} = PackageValidator.validate(context.repo_root)

    assert Enum.any?(
             reference_errors,
             &String.contains?(&1, "reference target must be an ADR summary or Rule")
           )
  end

  test "accepts an empty direct Decision but rejects malformed summary fields and example indexes",
       context do
    retrieval_path =
      Path.join([
        context.repo_root,
        "dist",
        "elixir-code-anti-patterns",
        "retrieval.jsonl"
      ])

    records = TestSupport.jsonl!(retrieval_path)
    summary = Enum.find(records, &(&1["record_kind"] == "adr_summary"))
    assert summary["decision"] == ""
    assert {:ok, _stats} = PackageValidator.validate(context.repo_root)

    without_decision =
      Enum.map(records, fn record ->
        if record["record_id"] == summary["record_id"],
          do: Map.delete(record, "decision"),
          else: record
      end)

    write_jsonl!(retrieval_path, without_decision)
    assert {:error, missing_errors} = PackageValidator.validate(context.repo_root)
    assert Enum.any?(missing_errors, &String.contains?(&1, "missing fields: decision"))

    non_string_decision =
      Enum.map(records, fn record ->
        if record["record_id"] == summary["record_id"],
          do: Map.put(record, "decision", nil),
          else: record
      end)

    write_jsonl!(retrieval_path, non_string_decision)
    assert {:error, type_errors} = PackageValidator.validate(context.repo_root)

    assert Enum.any?(
             type_errors,
             &String.contains?(&1, "summary decision must be a string")
           )

    example = Enum.find(records, &(&1["record_kind"] == "example"))

    invalid_example_index =
      Enum.map(records, fn record ->
        if record["record_id"] == example["record_id"],
          do: Map.update!(record, "record_id", &String.replace_suffix(&1, ":01", ":02")),
          else: record
      end)

    write_jsonl!(retrieval_path, invalid_example_index)
    assert {:error, example_errors} = PackageValidator.validate(context.repo_root)

    assert Enum.any?(
             example_errors,
             &String.contains?(&1, "example record_id must be")
           )
  end

  defp write_jsonl!(path, rows) do
    File.write!(path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
  end
end
