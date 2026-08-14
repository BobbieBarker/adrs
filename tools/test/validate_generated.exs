#!/usr/bin/env elixir

Code.require_file("test_helper.exs", __DIR__)

case AdrDist.PackageValidator.validate(AdrDist.TestSupport.repo_root()) do
  {:ok, stats} ->
    IO.puts(
      "Validated #{stats.retrieval_records} retrieval records, " <>
        "#{stats.legacy_records} legacy records, and " <>
        "#{stats.evaluation_queries} evaluation queries."
    )

  {:error, errors} ->
    Enum.each(errors, &IO.puts(:stderr, "error: #{&1}"))
    System.halt(1)
end
