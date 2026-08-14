#!/usr/bin/env elixir

Code.require_file("test_helper.exs", __DIR__)

__DIR__
|> Path.join("**/*_test.exs")
|> Path.wildcard()
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

case ExUnit.run() do
  %{failures: 0} -> :ok
  _results -> System.halt(1)
end
