# adrs

Architecture Decision Records, written for engineers and shaped for LLMs to consume.

The first set covers Elixir OTP and GenServer practice. Future sets will cover other domains; the layout supports that without renaming anything.

## Read the ADRs

### Elixir OTP / GenServer

- [ADR-001: Reach for Simpler Primitives Before GenServer](adrs/elixir-otp/adr-001-reach-for-simpler-primitives-before-genserver.md)
- [ADR-002: Separate GenServer Business Logic From Server Mechanics](adrs/elixir-otp/adr-002-separate-business-logic-from-server-mechanics.md)
- [ADR-003: Keep GenServer State Small; Push Storage Out of Process](adrs/elixir-otp/adr-003-keep-state-small-push-storage-out-of-process.md)
- [ADR-004: Never Block the GenServer Processing Loop](adrs/elixir-otp/adr-004-never-block-the-processing-loop.md)
- [ADR-005: Get Slow Work Off the Processing Loop](adrs/elixir-otp/adr-005-get-slow-work-off-the-loop.md)
- [ADR-006: Use GenStage for Producer-Consumer Pipelines](adrs/elixir-otp/adr-006-use-genstage-for-producer-consumer-pipelines.md)
- [ADR-007: Design GenServers for Test Isolation](adrs/elixir-otp/adr-007-design-genservers-for-test-isolation.md)
- [ADR-008: Graceful Shutdown Requires trap_exit and a Realistic :shutdown](adrs/elixir-otp/adr-008-graceful-shutdown-requires-trap-exit-and-realistic-shutdown.md)

## Use these in your agentic workflow

The ADRs in `adrs/<domain>/` are the source of truth. The `dist/<domain>/` folder carries pre-rendered bundles for the dominant agent harnesses. Pick the path that matches your tooling.

### Cursor

```sh
# from your project root
mkdir -p .cursor/rules
cp /path/to/adrs/dist/elixir-otp/cursor/*.mdc .cursor/rules/
```

Each rule's behavior is set by its frontmatter:

- Rules with `globs` auto-attach when you edit a matching file ("Apply to Specific Files").
- Rules without `globs` are pulled in by the agent when their `description` is relevant ("Apply Intelligently").

Reference: <https://cursor.com/docs/context/rules>

### Claude Code

```sh
# from your project root
cp /path/to/adrs/dist/elixir-otp/claude-code/CLAUDE.md ./CLAUDE.md
mkdir -p .claude/rules
cp /path/to/adrs/dist/elixir-otp/claude-code/.claude/rules/*.md .claude/rules/
```

If your project already has a `CLAUDE.md`, append the contents of the rendered one rather than overwriting. The per-file copy of the rules avoids touching any existing `.claude/agents/`, `.claude/settings.json`, or unrelated rule files.

Claude Code reads `CLAUDE.md` at the start of every session and picks up files in `.claude/rules/` automatically. Rules with `paths:` frontmatter auto-attach when Claude reads matching files; rules without `paths` are loaded into every session unconditionally.

Reference: <https://code.claude.com/docs/en/memory>

### Aider, raw API harnesses, one-off use

```sh
# Aider: read the bundle as a read-only context file
aider --read /path/to/adrs/dist/elixir-otp/bundle.md
```

Aider has no auto-discovery for a `CONVENTIONS.md` file; you always pass it via `--read`. By convention people name the file `CONVENTIONS.md`, but the name does not matter to Aider. To avoid retyping the path on every invocation, put it in `.aider.conf.yml`:

```yaml
# .aider.conf.yml
read:
  - /path/to/adrs/dist/elixir-otp/bundle.md
```

`bundle.md` is the eight ADRs concatenated. It pays full token cost on every turn and gets cached if prompt caching is enabled. Use the harness-specific bundles above when you can; fall back to this when you can't.

References: <https://aider.chat/docs/usage/conventions.html>, <https://aider.chat/docs/config/aider_conf.html>

### Custom harness or your own retriever (RAG)

`dist/<domain>/adrs.jsonl` is one ADR per row, with `id`, `domain`, `title`, `description`, `tags`, `applies_to`, and `body`. Embed the `body` field with the model of your choice; store the rest as metadata. The `applies_to` patterns are advisory; your retriever decides what to do with them.

The `applies_to` shape (`paths` globs and `content_match` substrings) is the same data used to generate the harness-specific bundles, so a custom retriever can match the bundles' behavior by consuming this manifest directly.

### Obsidian + qmd / ClawVault

The ADRs in `adrs/<domain>/` use vault-conformant frontmatter (`type: adr`, `id`, `title`, `status`, `date`, `tags`, `description`). Clone the repo into your vault's directory and your existing semantic-retrieval tooling will index them.

## How this repo is organized

```
adrs/
└── <domain>/                     # source of truth (Markdown + manifest)
    ├── adr-rules.yaml            # path/content patterns per ADR
    └── adr-NNN-...md             # one ADR per file

dist/                             # pre-rendered, regenerated on release
└── <domain>/
    ├── cursor/                   # native Cursor rule files
    ├── claude-code/              # CLAUDE.md + adrs/ drop-in bundle
    ├── adrs.jsonl                # for retriever-based use
    └── bundle.md                 # single concatenated file

tools/
└── build_dist.exs                # regenerates dist/ from adrs/ + manifests
```

## Regenerating `dist/`

`dist/` is checked in so consumers can `curl` files from raw GitHub without cloning. To regenerate:

```sh
elixir tools/build_dist.exs
```

The script reads each `adrs/<domain>/adr-rules.yaml`, renders all four bundle formats, and writes them under `dist/<domain>/`. Requires Elixir 1.12 or later (uses `Mix.install`).

Edit the source ADRs and the manifest. Do not edit files in `dist/`; they are overwritten on every build.

## License

[MIT](LICENSE). Do whatever you want with these. A reference back if you publish a fork or a derived work is appreciated, not required.
