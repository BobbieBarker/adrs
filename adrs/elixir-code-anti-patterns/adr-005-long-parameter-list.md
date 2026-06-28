---
type: adr
id: 5
title: "Long parameter list"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, function-design, api-design, maps]
description: "Functions with many positional parameters bind arguments by position, not by name, so same-typed parameters transpose silently with no MatchError or compiler warning. Group related arguments into a map or struct so each value is named at the call site, and split unrelated arguments into separate functions."
---
# ADR-005: Long parameter list

## Context

Elixir functions take all their inputs explicitly and return all their outputs, rather than reaching through shared mutable state. As a function accrues responsibility, its parameter count grows, and at some arity the interface becomes a memory test for the caller.

The mechanism that makes this dangerous is positional binding. Elixir matches arguments by position, not by name. When several adjacent parameters share a type (four strings in a row, two integers), transposing any two of them compiles cleanly, raises no `MatchError`, and triggers no compiler warning. The function runs with swapped values and the defect surfaces far downstream from the call site. Arity is also the ordering contract: every caller must reproduce the exact sequence, and every reorder or insertion is a breaking change across all of them.

The refactoring is to stop passing loose positional values. Group related arguments into a map or struct so each value is addressed by name, and split arguments that do not belong to one entity into separate functions.

## Decision

### Rule 1: Group related arguments into a map or struct

**Correct:**

```elixir
defmodule Library do
  def loan(user, book) when is_map(user) and is_map(book) do
    # reads user.email, book.title, ...
  end
end

# Caller names every value at the boundary:
Library.loan(
  %{name: name, email: email, password: password, alias: alias},
  %{title: title, ed: ed}
)
```

**Wrong:**

```elixir
defmodule Library do
  def loan(user_name, email, password, user_alias, book_title, book_ed) do
    # ...
  end
end

# email and password transposed: compiles clean, wrong at runtime.
Library.loan(name, password, email, alias, title, ed)
```

**Why:** In the six-arity version `email`, `password`, `user_alias`, `book_title`, and `book_ed` are all strings, so the transposed call binds the wrong value to each name with no `MatchError` and no warning. Grouping removes the positional slots that made the swap possible: in the literal `%{email: email, password: password}` written at the call site each value sits next to its own key, so transposing email and password is impossible by construction, there is no positional slot left to swap. Arity also drops from `loan/6` to `loan/2`, retiring the ordering contract every caller had to reproduce. Bind each group to a single variable and read its fields in the body rather than destructuring every key in the head (see ADR-003); if a grouping struct grows past the field count in ADR-010, that is a separate concern. For a private function, one mechanical split is two maps: one for data that changes and one for read-only data. Keep optional inputs in a trailing keyword list so adding one does not change arity.

### Rule 2: Split unrelated arguments into separate functions

**Correct:**

```elixir
defmodule Report do
  def build(rows, opts) do
    rows
    |> sort(opts.sort_key)
    |> paginate(opts.page_size)
    |> format(opts.locale, opts.currency)
  end
end

# Delivery is a separate responsibility, not a parameter of build:
defmodule Report.Mailer do
  def deliver(report, recipient, host) do
    # ...
  end
end
```

**Wrong:**

```elixir
defmodule Report do
  # Sorting, pagination, formatting, and delivery in one head.
  def generate(rows, sort_key, page_size, locale, currency, smtp_host, recipient) do
    # ...
  end
end
```

**Why:** When half a dozen parameters do not share a domain entity, the arity is counting responsibilities, not one entity's fields, and the function is trying to do too much. Forcing `smtp_host` and `recipient` into the same map as `sort_key` would be a false grouping the data does not justify. Each independent parameter is a separate axis of change, so a function that holds all of them has multiple reasons to change. Splitting gives `build/2` only the report-shaping inputs and `deliver/3` only the delivery inputs, so each function changes for one reason and composes with the others through the pipe.

## Consequences

- Call sites name each value next to its key, so transposing two same-typed arguments is impossible by construction instead of compiling into swapped data.
- Arity drops (`loan/6` becomes `loan/2`), removing the positional ordering contract callers had to memorize.
- Optional inputs live in a trailing keyword list, so adding one does not change arity or break existing callers.
- Functions whose parameters do not share a domain entity get split, surfacing multi-responsibility that the long signature was hiding.
