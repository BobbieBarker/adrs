tools_root = __DIR__

[
  "lib/adr_dist/error.ex",
  "lib/adr_dist/adr.ex",
  "lib/adr_dist/markdown.ex",
  "lib/adr_dist/source.ex",
  "lib/adr_dist/references.ex",
  "lib/adr_dist/retrieval.ex",
  "lib/adr_dist/renderer.ex",
  "lib/adr_dist/validator.ex",
  "lib/adr_dist/build.ex"
]
|> Enum.each(&Code.require_file(Path.join(tools_root, &1)))
