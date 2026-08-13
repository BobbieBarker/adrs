# adrs

Architecture Decision Records, packaged as agent context. Each ADR is a single rule with a Wrong example, a Correct example, and a Why paragraph that names the mechanism behind the difference. Written for engineers and shaped for LLMs to consume: the format reads cleanly as a reference and drops into Cursor, Claude Code, Aider, and custom retrieval-based agents so the rules load automatically when you write or review code.

The rules are grouped into domains. Each domain is a self-contained set with its own pre-rendered bundles under `dist/<domain>/`; adopt one or several.

## Domains

| Domain | Covers | ADRs |
|---|---|---|
| [`elixir-otp`](adrs/elixir-otp) | OTP, GenServer, supervision, BEAM scheduling, interprocess data, stateful-process testing | 12 |
| [`elixir-conventions`](adrs/elixir-conventions) | Structural dispatch, runtime algorithm selection, pipeline composition, structs, `with` chains, streaming, effect compensation, structured errors | 8 |
| [`elixir-ecto`](adrs/elixir-ecto) | Transaction boundaries and the commit contract | 1 |
| [`elixir-code-anti-patterns`](adrs/elixir-code-anti-patterns) | The official Elixir code anti-patterns | 10 |
| [`elixir-design-anti-patterns`](adrs/elixir-design-anti-patterns) | The official Elixir design anti-patterns | 6 |
| [`elixir-macro-anti-patterns`](adrs/elixir-macro-anti-patterns) | The official Elixir meta-programming anti-patterns | 5 |

### elixir-otp

Working with GenServer and the BEAM rewards a precise mental model of how they actually behave. The wrong model produces the same predictable production failures: a callback blocks the processing loop, a process hoards state and pays for it in GC pauses, a `cast` pipeline grows an unbounded mailbox, `terminate/2` cleanup is silently skipped on a brutal kill. Humans build the wrong model. LLMs build the wrong model, often more confidently.

- [ADR-001: Reach for Simpler Primitives Before GenServer](adrs/elixir-otp/adr-001-reach-for-simpler-primitives-before-genserver.md)
- [ADR-002: Own State in the Process; Separate Transitions From Server Mechanics](adrs/elixir-otp/adr-002-separate-business-logic-from-server-mechanics.md)
- [ADR-003: Keep GenServer State Small; Push Storage Out of Process](adrs/elixir-otp/adr-003-keep-state-small-push-storage-out-of-process.md)
- [ADR-004: Never Block the GenServer Processing Loop](adrs/elixir-otp/adr-004-never-block-the-processing-loop.md)
- [ADR-005: Get Slow Work Off the Processing Loop](adrs/elixir-otp/adr-005-get-slow-work-off-the-loop.md)
- [ADR-006: Use GenStage for Producer-Consumer Pipelines](adrs/elixir-otp/adr-006-use-genstage-for-producer-consumer-pipelines.md)
- [ADR-007: Design GenServers for Test Isolation](adrs/elixir-otp/adr-007-design-genservers-for-test-isolation.md)
- [ADR-008: Graceful Shutdown Requires trap_exit and a Realistic :shutdown](adrs/elixir-otp/adr-008-graceful-shutdown-requires-trap-exit-and-realistic-shutdown.md)
- [ADR-009: Send Minimal Data Between Processes](adrs/elixir-otp/adr-009-send-minimal-data-between-processes.md)
- [ADR-010: Supervise Every Long-Lived Process](adrs/elixir-otp/adr-010-supervise-long-lived-processes.md)
- [ADR-011: Test OTP Code Through Real Processes](adrs/elixir-otp/adr-011-test-otp-code-through-real-processes.md)
- [ADR-012: The Shape of GenServer State](adrs/elixir-otp/adr-012-shape-of-genserver-state.md)

### elixir-conventions

These are the decisions a reader makes constantly and rarely writes down: which construct expresses
a branch, whether an algorithm is chosen by the value or by the wiring, when a pipeline beats a
rebinding, what a domain entity is made of, what may appear inside a `with`, and what a failure
looks like once it leaves the function that produced it. Each rule names the compiler or runtime
mechanism that separates the correct form from the plausible one.

- [ADR-001: Structural Dispatch Over Imperative Branching](adrs/elixir-conventions/adr-001-structural-dispatch-over-imperative-branching.md)
- [ADR-002: The Strategy Pattern in Elixir](adrs/elixir-conventions/adr-002-strategy-pattern-in-elixir.md)
- [ADR-003: Compose with Pipes, Not Named Intermediates](adrs/elixir-conventions/adr-003-compose-with-pipes-not-named-intermediates.md)
- [ADR-004: Use Structs for Domain Entities](adrs/elixir-conventions/adr-004-use-structs-for-domain-entities.md)
- [ADR-005: Keep `with` Chains Pure](adrs/elixir-conventions/adr-005-keep-with-chains-pure.md)
- [ADR-006: Stream Pass-Through Data, Source to Sink](adrs/elixir-conventions/adr-006-stream-pass-through-data.md)
- [ADR-007: Compensate Completed Effects in Fallible Chains](adrs/elixir-conventions/adr-007-compensate-completed-effects.md)
- [ADR-008: Represent Domain Errors as a Structured Value](adrs/elixir-conventions/adr-008-represent-domain-errors-as-a-structured-value.md)

### elixir-ecto

Database access decisions. Currently one: the transaction wrapper whose commit is decided by
inspecting what your callback returned, rather than by whether it happened to raise.

- [ADR-001: Use Repo.transact for Database Transactions](adrs/elixir-ecto/adr-001-use-repo-transact-for-transactions.md)

### elixir-code-anti-patterns

The code-related anti-patterns from the official Elixir documentation, each codified as one rule: the mistake as the Wrong example, the refactoring as the Correct example, and the mechanism in the Why.

- [ADR-001: Comments overuse](adrs/elixir-code-anti-patterns/adr-001-comments-overuse.md)
- [ADR-002: Complex `else` clauses in `with`](adrs/elixir-code-anti-patterns/adr-002-complex-else-clauses-in-with.md)
- [ADR-003: Complex extractions in clauses](adrs/elixir-code-anti-patterns/adr-003-complex-extractions-in-clauses.md)
- [ADR-004: Dynamic atom creation](adrs/elixir-code-anti-patterns/adr-004-dynamic-atom-creation.md)
- [ADR-005: Long parameter list](adrs/elixir-code-anti-patterns/adr-005-long-parameter-list.md)
- [ADR-006: Namespace trespassing](adrs/elixir-code-anti-patterns/adr-006-namespace-trespassing.md)
- [ADR-007: Non-assertive map access](adrs/elixir-code-anti-patterns/adr-007-non-assertive-map-access.md)
- [ADR-008: Non-assertive pattern matching](adrs/elixir-code-anti-patterns/adr-008-non-assertive-pattern-matching.md)
- [ADR-009: Non-assertive truthiness](adrs/elixir-code-anti-patterns/adr-009-non-assertive-truthiness.md)
- [ADR-010: Structs with 32 fields or more](adrs/elixir-code-anti-patterns/adr-010-structs-with-32-fields-or-more.md)

### elixir-design-anti-patterns

The design-related anti-patterns from the official Elixir documentation: return-type consistency, boolean and primitive obsession, exceptions for control flow, unrelated multi-clause functions, and library configuration.

- [ADR-001: Alternative return types](adrs/elixir-design-anti-patterns/adr-001-alternative-return-types.md)
- [ADR-002: Boolean obsession](adrs/elixir-design-anti-patterns/adr-002-boolean-obsession.md)
- [ADR-003: Exceptions for control-flow](adrs/elixir-design-anti-patterns/adr-003-exceptions-for-control-flow.md)
- [ADR-004: Primitive obsession](adrs/elixir-design-anti-patterns/adr-004-primitive-obsession.md)
- [ADR-005: Unrelated multi-clause function](adrs/elixir-design-anti-patterns/adr-005-unrelated-multi-clause-function.md)
- [ADR-006: Using application configuration for libraries](adrs/elixir-design-anti-patterns/adr-006-using-application-configuration-for-libraries.md)

### elixir-macro-anti-patterns

The meta-programming anti-patterns from the official Elixir documentation: compile-time dependencies (tracked and untracked), code-generation size, unnecessary macros, and `use` versus `import`.

- [ADR-001: Compile-time dependencies](adrs/elixir-macro-anti-patterns/adr-001-compile-time-dependencies.md)
- [ADR-002: Large code generation](adrs/elixir-macro-anti-patterns/adr-002-large-code-generation.md)
- [ADR-003: Unnecessary macros](adrs/elixir-macro-anti-patterns/adr-003-unnecessary-macros.md)
- [ADR-004: `use` instead of `import`](adrs/elixir-macro-anti-patterns/adr-004-use-instead-of-import.md)
- [ADR-005: Untracked compile-time dependencies](adrs/elixir-macro-anti-patterns/adr-005-untracked-compile-time-dependencies.md)

> The anti-pattern domains codify the patterns documented at <https://hexdocs.pm/elixir/what-anti-patterns.html>. The process anti-patterns are not a separate domain because `elixir-otp` already covers that ground: *Code organization by process* and *Scattered process interfaces* fall under ADR-001 and ADR-002, and *Sending unnecessary data* and *Unsupervised processes* are ADR-009 and ADR-010. Nothing is restated across domains.

## Integration

Pre-rendered bundles live in `dist/<domain>/`, one set per domain. Pick your domain (the examples below use `elixir-otp`; substitute any domain from the table above) and your harness.

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

Claude Code reads `CLAUDE.md` at the start of every session and picks up files in `.claude/rules/` automatically. Rules with `paths:` frontmatter auto-attach when Claude reads matching files; rules without `paths` load into every session unconditionally.

Reference: <https://code.claude.com/docs/en/memory>

### Aider, raw API harnesses, one-off use

```sh
aider --read /path/to/adrs/dist/elixir-otp/bundle.md
```

Aider has no auto-discovery; you always pass the file via `--read`. To avoid retyping the path on every invocation, put it in `.aider.conf.yml`:

```yaml
# .aider.conf.yml
read:
  - /path/to/adrs/dist/elixir-otp/bundle.md
```

`bundle.md` is the domain's ADRs concatenated into one file. It pays full token cost on every turn and gets cached if prompt caching is enabled. Use the harness-specific bundles above when you can; fall back to this when you can't.

References: <https://aider.chat/docs/usage/conventions.html>, <https://aider.chat/docs/config/aider_conf.html>

### Custom harness or your own retriever (RAG)

`dist/<domain>/adrs.jsonl` is one ADR per row, with `id`, `domain`, `title`, `description`, `tags`, `applies_to`, and `body`. Embed the `body` field with the model of your choice; store the rest as metadata. The `applies_to` patterns are advisory; your retriever decides what to do with them.

The `applies_to` shape (`paths` globs and `content_match` substrings) is the same data used to generate the harness-specific bundles, so a custom retriever can match those bundles' behavior by consuming this manifest directly.

### Obsidian + qmd / ClawVault

The ADRs use vault-conformant frontmatter (`type: adr`, `id`, `title`, `status`, `date`, `tags`, `description`). Clone the repo into your vault's directory and existing semantic-retrieval tooling will index them.

## Repo layout

```
adrs/<domain>/
├── adr-rules.yaml          # path/content patterns per ADR
└── adr-NNN-*.md            # one ADR per file

dist/<domain>/              # generated; do not edit by hand
├── cursor/                 # Cursor .mdc rules
├── claude-code/            # CLAUDE.md + .claude/rules/
├── adrs.jsonl              # one ADR per row
└── bundle.md               # concatenated

tools/
└── build_dist.exs          # regenerates dist/
```

Run `elixir tools/build_dist.exs` after editing the source ADRs or manifests. Requires Elixir 1.12 or later (uses `Mix.install`). CI blocks PRs when `dist/` is out of sync with `adrs/`.

## License

[MIT](LICENSE).
