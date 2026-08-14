Mix.install([
  {:yaml_elixir, "~> 2.11"},
  {:jason, "~> 1.4"}
])

ExUnit.start(autorun: false)

if Version.compare(System.version(), "1.18.0") == :lt do
  Code.compiler_options(warnings_as_errors: true)
end

Code.require_file(Path.expand("../load_adr_dist.exs", __DIR__))

Path.join(__DIR__, "support/**/*.ex")
|> Path.wildcard()
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

defmodule AdrDist.TestSupport do
  @moduledoc false

  @repo_root Path.expand("../..", __DIR__)

  @spec repo_root() :: String.t()
  def repo_root, do: @repo_root

  @spec jsonl!(String.t()) :: [map()]
  def jsonl!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  @spec sha256(String.t()) :: String.t()
  def sha256(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end

  @spec temporary_directory!(String.t()) :: String.t()
  def temporary_directory!(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  @spec files_with_contents!(String.t()) :: [{String.t(), binary()}]
  def files_with_contents!(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn path -> {Path.relative_to(path, root), File.read!(path)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end
end
