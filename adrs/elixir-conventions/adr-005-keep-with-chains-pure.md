---
type: adr
id: 5
title: Keep `with` Chains Pure
status: accepted
date: '2026-05-08'
updated: '2026-08-09'
tags: [elixir, control-flow, with, error-handling, fallible-chains]
description: "Inside a `with` chain, every clause uses `<-` with a refutable success pattern. Plain `=` matches never participate in fall-through, and an irrefutable `value <- operation()` is the same smuggling in different syntax. Avoid `else`; normalize return shapes in called functions. Use `with` only when two or more fallible steps compose; return one unchanged result directly, use `case` to transform one result, and use pipelines for pure transformations."
---

# ADR-005: Keep `with` Chains Pure

## Context

`with` is Elixir's special form for chaining operations where each step can fail. The `<-` arrow performs a pattern-match-or-fall-through: a successful match binds and continues; a returned value that does not match aborts the chain and becomes the result of the `with`. Raises, exits, and throws do not fall through. This semantic is the macro's reason for existing: it replaces nested `case` with a flat sequence and propagates the first non-matching return without manual pass-through clauses.

Three failure modes appear when authors use `with` without internalizing this semantic:

1. **Mixing plain `=` bindings into the chain.** `=` remains Elixir's match operator inside `with`. A mismatch raises `MatchError`; it never participates in fall-through. A match against a fresh variable always succeeds and merely smuggles infallible work into the chain shape.
2. **Adding an `else` block.** Once a `with` has an `else`, every step's non-matching return funnels through it, and which step produced that value becomes opaque. A value that matches no `else` clause raises `WithClauseError`. The fix is to make each called function return a fully formed error shape so the bare `with` can let mismatches fall through unchanged.
3. **Using `with` for shapes that do not need it.** Return one fallible call directly when it already has the desired public result. Use `case` when that one result needs transformation or differentiated handling. A sequence of guaranteed-success transformations is a pipeline. `with` earns its shape when two or more fallible operations compose.

This ADR names each as a Rule. ADR-001 Rule 3 covers the complementary side, when to reach for `with` at all.

## Decision

A `with` chain contains only `<-` steps with refutable success patterns, returns non-matching values unchanged, and is reserved for sequences where at least two fallible steps conditionally compose.

### Rule 1: Every step in a `with` chain uses `<-`, never plain `=`

A `with` chain is a sequence of pattern-match-or-fall-through steps. Every clause uses `<-` with a refutable success pattern such as `:ok` or `{:ok, value}`. Plain `=` matches inside the chain are a misuse of the macro: a mismatch raises `MatchError`, while a fresh-variable match always succeeds and merely smuggles infallible work into the chain. Writing `value <- operation()` does not repair that misuse because the fresh variable matches every returned value. Extract a composing helper or move the infallible binding into the `do` block.

**Correct:**

```elixir
defmodule MyApp.CLI do
  def parse(raw_argv) do
    with :ok <- verify(),
         {:ok, opts} <- parse_options(raw_argv) do
      run(opts)
    end
  end

  defp parse_options(raw_argv) do
    case raw_argv |> normalize_argv() |> OptionParser.parse(strict: @opts_spec) do
      {opts, [], []} ->
        {:ok, opts}

      {_opts, _argv, errs} ->
        {:error,
         ErrorMessage.unprocessable_entity(
           "Bad options",
           %{
             operation: :parse_cli_options,
             validation_errors: normalize_option_errors(errs)
           }
         )}
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.CLI do
  def parse(raw_argv) do
    with :ok <- verify(),
         argv = normalize_argv(raw_argv),
         {:ok, opts} <- parse_options(argv) do
      run(opts)
    end
  end
end
```

**Why:** In the Wrong version, `argv` is fresh, so `argv = normalize_argv(raw_argv)` always matches. It does no pattern-match-or-fall-through work and is present only to prepare the next `<-` argument. If its left side were refutable and did not match, `=` would raise `MatchError` rather than return the value from the `with`. The Correct version extracts `parse_options/1` to bundle normalization and parsing into one fallible helper whose `{:ok, _}` pattern can genuinely reject a returned error. The same applies to `config = build_config(opts)`: bundle it into the fallible helper that consumes it, or move it into the `do` block where plain `=` bindings are normal Elixir code. Do not disguise it as `config <- build_config(opts)`; that fresh-variable pattern still matches everything.

### Rule 2: Normalize return shapes in the called functions so the chain needs no `else`

A bare `with` (no `else`) lets non-matching values fall through and emerges from the `with` as-is. This is almost always what you want: the failure value the called function produced is the failure value the caller receives. Adding an `else` block flattens every step's failure into a single block, obscuring which step failed.

**Correct:**

```elixir
defmodule MyApp.Accounts do
  alias MyApp.Users

  def register(email) do
    with :ok <- validate_email_format(email),
         :ok <- validate_email_policy(email),
         {:ok, user} <- insert_user(%{email: email}) do
      {:ok, user}
    end
  end

  defp validate_email_format(email) do
    if Regex.match?(@email_regex, email) do
      :ok
    else
      {:error,
       ErrorMessage.unprocessable_entity(
         "Invalid email format",
         %{operation: :register_account}
       )}
    end
  end

  defp validate_email_policy(email) do
    if MyApp.EmailPolicy.allowed?(email) do
      :ok
    else
      {:error,
       ErrorMessage.unprocessable_entity(
         "Email address is not permitted",
         %{operation: :register_account}
       )}
    end
  end

  defp insert_user(attrs) do
    case Users.insert(attrs) do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{} = changeset} ->
        normalize_insert_error(changeset)
    end
  end

  defp normalize_insert_error(changeset) do
    if email_conflict?(changeset) do
      {:error,
       ErrorMessage.conflict(
         "Email already registered",
         %{operation: :register_account}
       )}
    else
      {:error,
       ErrorMessage.unprocessable_entity(
         "Could not register account",
         %{
           operation: :register_account,
           validation_errors: normalize_validation_errors(changeset)
         }
       )}
    end
  end

  defp email_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:email, {_message, opts}} -> opts[:constraint] == :unique
      {_field, _error} -> false
    end)
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Accounts do
  alias MyApp.Users

  def register(email) do
    with :ok <- validate_email_format(email),
         :ok <- validate_email_policy(email),
         {:ok, user} <- Users.insert(%{email: email}) do
      {:ok, user}
    else
      {:error, :invalid_format} ->
        {:error,
         ErrorMessage.unprocessable_entity(
           "Invalid email format",
           %{operation: :register_account}
         )}

      {:error, :policy_rejected} ->
        {:error,
         ErrorMessage.unprocessable_entity(
           "Email address is not permitted",
           %{operation: :register_account}
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error,
         ErrorMessage.unprocessable_entity(
           "Insert failed",
           %{
             operation: :register_account,
             validation_errors: normalize_validation_errors(changeset)
           }
         )}
    end
  end
end
```

**Why:** The Wrong version puts error normalization into the `else` block. A reader scanning a failure has to identify which step produced each raw shape, and a returned value that matches no `else` clause raises `WithClauseError`. The Correct version makes both validations return their final `ErrorMessage` shape and normalizes the data-layer changeset at `insert_user/1`, the first application-owned boundary. The database's unique constraint is the authoritative conflict decision; there is no check-then-insert race. Other changeset failures become bounded, normalized validation details rather than leaking the changeset. A bare `with` can therefore pass every expected failure through unchanged. When a dependency returns another shape, adapt it in a small owned helper instead of flattening divergent failures into `else`.

### Rule 3: Reach for `with` only when two or more fallible steps conditionally compose

Return a single fallible call directly when it already has the desired public result. Use `case` when that one result needs transformation or differentiated handling. A pure-data transformation chain is a pipeline, not a `with`. `with` earns its overhead when at least two fallible steps conditionally compose: later work may consume a binding from any earlier step or may merely be allowed to run because every prior step succeeded.

**Correct:**

```elixir
defmodule MyApp.Accounts do
  alias MyApp.Users

  # The call already has the public result contract, so return it directly.
  def find_active(id) do
    Users.find(%{id: id, archived_at: nil})
  end

  # Multiple fallible steps conditionally compose through with.
  def register(email) do
    with {:ok, normalized} <- validate_and_normalize_email(email),
         {:ok, hash} <- hash_password(@temp_password),
         {:ok, user} <- Users.insert(%{email: normalized, password_hash: hash}) do
      {:ok, user}
    end
  end
end

defmodule MyApp.Filters do
  # Pure transformation: pipeline.
  def serialize(filters) do
    filters
    |> Enum.reject(&match?({_, nil}, &1))
    |> Enum.into(%{})
    |> URI.encode_query()
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Accounts do
  alias MyApp.Users

  # Single-step with: fall-through machinery with nothing later to compose.
  def find_active(id) do
    with {:ok, user} <- Users.find(%{id: id, archived_at: nil}) do
      {:ok, user}
    end
  end
end

defmodule MyApp.Filters do
  # Pure transformation forced into with by wrapping each step in {:ok, _}.
  def serialize(filters) do
    with {:ok, rejected} <- {:ok, Enum.reject(filters, &match?({_, nil}, &1))},
         {:ok, mapped} <- {:ok, Enum.into(rejected, %{})} do
      URI.encode_query(mapped)
    end
  end
end
```

**Why:** The Wrong `find_active/1` still matches and falls through on a non-match, but it has no later fallible operation to compose with and returns the same public result the call already produced. Return that call directly; if either outcome needed transformation, use `case` so its handling remains adjacent. The Wrong `serialize/1` wraps pure-data steps in synthetic success tuples solely to manufacture `<-` clauses. Both filter examples return the same string, isolating the control-flow mistake from the return contract. Reach for `with` when at least two genuinely fallible operations conditionally compose, and use a pipeline for guaranteed-success transformations.

## Consequences

- `with` chains contain only `<-` clauses with refutable success patterns. A line with `=`, or an irrefutable `value <- operation()`, is a refactor signal: extract a composing helper that returns a matchable result or move infallible work into the `do` block.
- `else` clauses are absent from almost every `with` in the codebase. When error shapes diverge, normalize them at the first application-owned boundary rather than flattening them into `else`, where an unmatched value raises `WithClauseError`.
- `with` chains have at least two fallible steps. Return one already-correct result directly, use `case` to transform one result, and use pipelines for pure transformations.
- A bare `with` returns the first value that fails an `<-` pattern unchanged. Raises, exits, and throws are not fall-through values.
