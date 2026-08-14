defmodule AdrDist.Renderer do
  @moduledoc """
  Renders legacy harness bundles and retrieval-v1 artifacts into an empty tree.
  """

  alias AdrDist.{Adr, Error, Retrieval}
  alias AdrDist.Source.Domain

  @spec render(String.t(), [Domain.t()], [map()]) :: :ok | {:error, Error.t()}
  def render(output_root, domains, records)
      when is_binary(output_root) and is_list(domains) and is_list(records) do
    File.mkdir_p!(output_root)

    Enum.each(domains, fn domain_data ->
      domain_records = Enum.filter(records, &(&1["domain"] == domain_data.domain))
      write_domain(output_root, domain_data, domain_records)
    end)

    write_catalog(output_root, domains, records)
    :ok
  rescue
    error ->
      {:error,
       Error.new(:render_failed, Exception.message(error),
         path: output_root,
         details: error.__struct__
       )}
  end

  defp write_domain(output_root, %Domain{} = domain_data, records) do
    dist_dir = Path.join(output_root, domain_data.domain)
    File.mkdir_p!(dist_dir)
    build_cursor(dist_dir, domain_data.manifest, domain_data.adrs)
    build_claude_code(dist_dir, domain_data.manifest, domain_data.adrs)
    build_legacy_jsonl(dist_dir, domain_data.adrs)
    build_retrieval_jsonl(dist_dir, records)
    build_bundle(dist_dir, domain_data.manifest, domain_data.adrs)
  end

  defp build_cursor(dist_dir, manifest, adrs) do
    cursor_dir = Path.join(dist_dir, "cursor")
    File.mkdir_p!(cursor_dir)

    Enum.each(adrs, fn adr ->
      File.write!(Path.join(cursor_dir, "adr-#{pad(adr.id, 3)}.mdc"), render_cursor_mdc(adr))
    end)

    File.write!(Path.join(cursor_dir, "README.md"), render_cursor_readme(manifest))
  end

  defp render_cursor_mdc(%Adr{} = adr) do
    globs = adr.applies_to |> Map.get("paths") |> List.wrap()

    frontmatter =
      ["description: " <> yaml_quote(adr.description)] ++
        if(globs == [], do: [], else: ["globs: " <> yaml_quote(Enum.join(globs, ","))]) ++
        ["alwaysApply: false"]

    """
    ---
    #{Enum.join(frontmatter, "\n")}
    ---

    #{adr.body}
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

  defp build_claude_code(dist_dir, manifest, adrs) do
    claude_dir = Path.join(dist_dir, "claude-code")
    rules_dir = Path.join([claude_dir, ".claude", "rules"])
    File.mkdir_p!(rules_dir)

    Enum.each(adrs, fn adr ->
      File.write!(Path.join(rules_dir, "adr-#{pad(adr.id, 3)}.md"), render_claude_rule(adr))
    end)

    File.write!(Path.join(claude_dir, "CLAUDE.md"), render_claude_md(manifest))
    File.write!(Path.join(claude_dir, "README.md"), render_claude_readme(manifest))
  end

  defp render_claude_rule(%Adr{} = adr) do
    paths = adr.applies_to |> Map.get("paths") |> List.wrap()

    frontmatter =
      if paths == [] do
        ""
      else
        """
        ---
        paths:
        #{Enum.map_join(paths, "\n", &"  - \"#{&1}\"")}
        ---

        """
      end

    frontmatter <> adr.body
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

  defp build_legacy_jsonl(dist_dir, adrs) do
    rows =
      Enum.map(adrs, fn adr ->
        %{
          "id" => adr.id,
          "domain" => adr.domain,
          "title" => adr.title,
          "description" => adr.description,
          "tags" => Map.get(adr.frontmatter, "tags", []),
          "applies_to" => adr.applies_to,
          "body" => adr.body
        }
      end)

    write_jsonl(Path.join(dist_dir, "adrs.jsonl"), rows)
  end

  defp build_retrieval_jsonl(dist_dir, records) do
    write_jsonl(Path.join(dist_dir, "retrieval.jsonl"), records)
  end

  defp write_jsonl(path, rows) do
    contents = Enum.map_join(rows, "\n", &Jason.encode!/1)
    File.write!(path, contents <> if(contents == "", do: "", else: "\n"))
  end

  defp build_bundle(dist_dir, manifest, adrs) do
    header = """
    # #{manifest["title"]} - ADRs

    #{manifest["description"]}

    Source: https://github.com/BobbieBarker/adrs

    """

    body = Enum.map_join(adrs, "\n\n***\n\n", & &1.raw)
    File.write!(Path.join(dist_dir, "bundle.md"), header <> body <> "\n")
  end

  defp write_catalog(output_root, domains, records) do
    entries =
      Enum.map(domains, fn domain_data ->
        domain_records = Enum.filter(records, &(&1["domain"] == domain_data.domain))
        retrieval_path = Path.join([output_root, domain_data.domain, "retrieval.jsonl"])

        %{
          "domain" => domain_data.domain,
          "title" => domain_data.manifest["title"],
          "description" => domain_data.manifest["description"],
          "artifact" => Path.join([domain_data.domain, "retrieval.jsonl"]),
          "sha256" => retrieval_path |> File.read!() |> sha256(),
          "counts" => Retrieval.counts(domain_records)
        }
      end)

    catalog = %{
      "schema_version" => Retrieval.schema_version(),
      "domains" => entries,
      "counts" => Retrieval.counts(records)
    }

    File.write!(
      Path.join(output_root, "retrieval-catalog.json"),
      Jason.encode!(catalog, pretty: true) <> "\n"
    )
  end

  defp yaml_quote(value), do: "\"" <> String.replace(value, "\"", "\\\"") <> "\""

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp pad(value, width) do
    value
    |> Integer.to_string()
    |> String.pad_leading(width, "0")
  end
end
