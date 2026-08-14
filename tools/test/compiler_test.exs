defmodule AdrDist.CompilerTest do
  use ExUnit.Case, async: false

  alias AdrDist.TestSupport

  test "the reusable Elixir modules compile with warnings treated as errors" do
    output_path = TestSupport.temporary_directory!("adr-dist-beams")
    on_exit(fn -> File.rm_rf!(output_path) end)

    code_path_args =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&["-pa", &1])

    source_files =
      TestSupport.repo_root()
      |> Path.join("tools/lib/adr_dist/*.ex")
      |> Path.wildcard()
      |> Enum.sort()

    args = ["--warnings-as-errors", "-o", output_path] ++ code_path_args ++ source_files
    {output, status} = System.cmd(System.find_executable("elixirc"), args, stderr_to_stdout: true)

    assert status == 0, output
  end
end
