#!/usr/bin/env elixir
#
# Regenerates dist/ from adrs/<domain>/ + adrs/<domain>/adr-rules.yaml.
# Run: elixir tools/build_dist.exs
#
# Outputs (per domain):
#   dist/<domain>/cursor/*.mdc                 - native Cursor rules
#   dist/<domain>/claude-code/CLAUDE.md        - authority directive
#   dist/<domain>/claude-code/.claude/rules/*  - per-ADR rule files
#   dist/<domain>/adrs.jsonl            - pre-chunked manifest for retrievers
#   dist/<domain>/bundle.md             - single concatenated file

Mix.install([
  {:yaml_elixir, "~> 2.11"},
  {:jason, "~> 1.4"}
])

defmodule BuildDist do
  @adrs_root "adrs"
  @dist_root "dist"

  def run do
    File.rm_rf!(@dist_root)
    File.mkdir_p!(@dist_root)

    @adrs_root
    |> File.ls!()
    |> Enum.sort()
    |> Enum.filter(&domain?/1)
    |> Enum.each(&build_domain/1)

    IO.puts("Done.")
  end

  defp domain?(name) do
    File.dir?(Path.join(@adrs_root, name)) and
      File.exists?(Path.join([@adrs_root, name, "adr-rules.yaml"]))
  end

  defp build_domain(domain) do
    manifest = load_manifest(domain)
    adrs = load_adrs(domain, manifest)
    dist_dir = Path.join(@dist_root, domain)
    File.mkdir_p!(dist_dir)

    build_cursor(dist_dir, domain, manifest, adrs)
    build_claude_code(dist_dir, domain, manifest, adrs)
    build_jsonl(dist_dir, domain, adrs)
    build_bundle(dist_dir, manifest, adrs)

    IO.puts("Built #{domain} (#{length(adrs)} ADRs)")
  end

  defp load_manifest(domain) do
    [@adrs_root, domain, "adr-rules.yaml"]
    |> Path.join()
    |> YamlElixir.read_from_file!()
  end

  defp load_adrs(domain, manifest) do
    Enum.map(manifest["adrs"], fn entry ->
      path = Path.join([@adrs_root, domain, entry["file"]])
      raw = File.read!(path)
      {_fm_raw, body, fm_parsed} = split_frontmatter(raw)

      Map.merge(entry, %{
        "raw" => raw,
        "body" => body,
        "frontmatter" => fm_parsed
      })
    end)
  end

  defp split_frontmatter(raw) do
    case String.split(raw, ~r/^---\s*$/m, parts: 3) do
      ["", fm_raw, body] ->
        fm_parsed = YamlElixir.read_from_string!(fm_raw)
        {String.trim(fm_raw), String.trim_leading(body), fm_parsed}

      _ ->
        {"", raw, %{}}
    end
  end

  # ---------- Cursor ----------
  #
  # Per https://cursor.com/docs/context/rules:
  # - Files end in .mdc (not .mdx).
  # - `globs` is a comma-separated string, not a YAML array.
  # - Omitting `globs` while providing `description` gives "Apply Intelligently"
  #   (agent-requested) mode. Emitting `globs: ""` is not the documented form,
  #   so for content-only ADRs we omit the `globs` field entirely.

  defp build_cursor(dist_dir, _domain, manifest, adrs) do
    cursor_dir = Path.join(dist_dir, "cursor")
    File.mkdir_p!(cursor_dir)

    Enum.each(adrs, fn adr ->
      path = Path.join(cursor_dir, "adr-#{pad(adr["id"])}.mdc")
      File.write!(path, render_cursor_mdc(adr))
    end)

    File.write!(Path.join(cursor_dir, "README.md"), render_cursor_readme(manifest))
  end

  defp render_cursor_mdc(adr) do
    globs = adr |> get_in(["applies_to", "paths"]) |> List.wrap()

    fm_lines =
      [
        "description: " <> yaml_quote(adr["description"])
      ] ++
        case globs do
          [] -> []
          gs -> ["globs: " <> yaml_quote(Enum.join(gs, ","))]
        end ++
        ["alwaysApply: false"]

    """
    ---
    #{Enum.join(fm_lines, "\n")}
    ---

    #{adr["body"]}
    """
  end

  defp render_cursor_readme(manifest) do
    """
    # #{manifest["title"]} - Cursor rules

    Copy the `*.mdc` files in this directory into `.cursor/rules/` in your project.

    Each rule's behavior is set by its frontmatter:

    - Rules with `globs` are auto-attached when you edit a matching file ("Apply to Specific Files").
    - Rules without `globs` are pulled in by the agent when their `description` is relevant ("Apply Intelligently").

    These rules are pre-rendered from `adrs/#{manifest["domain"]}/adr-rules.yaml`. Do
    not edit them by hand. To regenerate, edit the source ADRs or manifest and run
    `elixir tools/build_dist.exs` from the repo root.

    Reference: https://cursor.com/docs/context/rules
    """
  end

  # ---------- Claude Code ----------
  #
  # Per https://code.claude.com/docs/en/memory:
  # - .claude/rules/<name>.md files with `paths:` YAML-array frontmatter auto-attach
  #   when Claude reads matching files. Rules without `paths` load unconditionally.
  # - Project-root CLAUDE.md is loaded at session start, not "every turn."
  #
  # We ship a minimal CLAUDE.md asserting authority + per-ADR rule files in
  # .claude/rules/. Path-scoped ADRs use the rule file's `paths` frontmatter.
  # Content-only ADRs ship without `paths` and load unconditionally.

  defp build_claude_code(dist_dir, _domain, manifest, adrs) do
    cc_dir = Path.join(dist_dir, "claude-code")
    rules_dir = Path.join([cc_dir, ".claude", "rules"])
    File.mkdir_p!(rules_dir)

    Enum.each(adrs, fn adr ->
      File.write!(
        Path.join(rules_dir, "adr-#{pad(adr["id"])}.md"),
        render_claude_rule(adr)
      )
    end)

    File.write!(Path.join(cc_dir, "CLAUDE.md"), render_claude_md(manifest))
    File.write!(Path.join(cc_dir, "README.md"), render_claude_readme(manifest))
  end

  defp render_claude_rule(adr) do
    paths = adr |> get_in(["applies_to", "paths"]) |> List.wrap()

    fm =
      case paths do
        [] ->
          ""

        ps ->
          """
          ---
          paths:
          #{Enum.map_join(ps, "\n", &"  - \"#{&1}\"")}
          ---

          """
      end

    fm <> adr["body"]
  end

  defp render_claude_md(manifest) do
    """
    # #{manifest["title"]} Conventions

    The ADRs in `.claude/rules/` are authoritative for #{manifest["domain"]} code in this project.

    Path-scoped ADRs auto-attach when you read a matching file. Content-only ADRs are always in context for this project.

    Before writing or modifying matching code:

    1. Read the relevant ADR.
    2. Write code that conforms to it.

    If your generated code conflicts with an ADR, change the code, not the ADR. If you believe an ADR is wrong for this project's context, raise it explicitly before deviating.
    """
  end

  defp render_claude_readme(manifest) do
    """
    # #{manifest["title"]} - Claude Code bundle

    Copy `CLAUDE.md` and `.claude/` into your project root. If your project already
    has a `CLAUDE.md`, append the contents of this one rather than overwriting.

    Claude Code reads `CLAUDE.md` at the start of every session. It also picks up
    `.claude/rules/*.md` files: rules with `paths:` frontmatter auto-attach when
    Claude reads matching files; rules without `paths` are loaded into every
    session unconditionally.

    These files are pre-rendered from `adrs/#{manifest["domain"]}/`. Do not edit
    them by hand. To regenerate, edit the source ADRs or manifest and run
    `elixir tools/build_dist.exs` from the repo root.

    Reference: https://code.claude.com/docs/en/memory
    """
  end

  # ---------- JSONL ----------

  defp build_jsonl(dist_dir, domain, adrs) do
    lines =
      Enum.map_join(adrs, "\n", fn adr ->
        Jason.encode!(%{
          id: adr["id"],
          domain: domain,
          title: adr["title"],
          description: adr["description"],
          tags: get_in(adr, ["frontmatter", "tags"]) || [],
          applies_to: adr["applies_to"] || %{},
          body: adr["body"]
        })
      end)

    File.write!(Path.join(dist_dir, "adrs.jsonl"), lines <> "\n")
  end

  # ---------- Bundle ----------

  defp build_bundle(dist_dir, manifest, adrs) do
    # Use *** as the inter-ADR separator. --- collides with the next ADR's
    # YAML frontmatter and can confuse Markdown parsers.
    header = """
    # #{manifest["title"]} - ADRs

    #{manifest["description"]}

    Source: https://github.com/BobbieBarker/adrs

    """

    body = Enum.map_join(adrs, "\n\n***\n\n", & &1["raw"])
    File.write!(Path.join(dist_dir, "bundle.md"), header <> body <> "\n")
  end

  # ---------- helpers ----------

  defp pad(id) when is_integer(id), do: id |> Integer.to_string() |> String.pad_leading(3, "0")

  defp yaml_quote(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end
end

BuildDist.run()
