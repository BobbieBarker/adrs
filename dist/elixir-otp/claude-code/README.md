# Elixir OTP / GenServer - Claude Code bundle

Copy `CLAUDE.md` and `.claude/` into your project root. If your project already
has a `CLAUDE.md`, append the contents of this one rather than overwriting.

Claude Code reads `CLAUDE.md` at the start of every session. It also picks up
`.claude/rules/*.md` files: rules with `paths:` frontmatter auto-attach when
Claude reads matching files; rules without `paths` are loaded into every
session unconditionally.

These files are pre-rendered from `adrs/elixir-otp/`. Do not edit
them by hand. To regenerate, edit the source ADRs or manifest and run
`elixir tools/build_dist.exs` from the repo root.

Reference: https://code.claude.com/docs/en/memory
