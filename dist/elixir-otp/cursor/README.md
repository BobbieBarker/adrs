# Elixir OTP / GenServer - Cursor rules

Copy the `*.mdc` files in this directory into `.cursor/rules/` in your project.

Each rule's behavior is set by its frontmatter:

- Rules with `globs` are auto-attached when you edit a matching file ("Apply to Specific Files").
- Rules without `globs` are pulled in by the agent when their `description` is relevant ("Apply Intelligently").

These rules are pre-rendered from `adrs/elixir-otp/adr-rules.yaml`. Do
not edit them by hand. To regenerate, edit the source ADRs or manifest and run
`elixir tools/build_dist.exs` from the repo root.

Reference: https://cursor.com/docs/context/rules
