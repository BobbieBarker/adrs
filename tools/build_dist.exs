#!/usr/bin/env elixir

if Version.compare(System.version(), "1.18.0") == :lt do
  Code.compiler_options(warnings_as_errors: true)
end

Mix.install([
  {:yaml_elixir, "~> 2.11"},
  {:jason, "~> 1.4"}
])

Code.require_file("load_adr_dist.exs", __DIR__)

case AdrDist.Build.run() do
  {:ok, summary} ->
    IO.puts(
      "Built #{length(summary["domains"])} domains, #{summary["records"]} retrieval records " <>
        "(#{summary["adrs"]} ADR summaries, #{summary["rules"]} rules, " <>
        "#{summary["examples"]} examples, #{summary["supporting"]} supporting sections)."
    )

  {:error, reason} ->
    message =
      case reason do
        %{__struct__: AdrDist.Error} = error -> AdrDist.Error.format(error)
        other -> inspect(other)
      end

    IO.puts(:stderr, "Build failed: #{message}")
    System.halt(1)
end
