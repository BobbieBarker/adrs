---
type: adr
id: 8
title: "Non-assertive pattern matching"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, pattern-matching, error-handling, assertive-code]
description: "Defensive accessors like Enum.at/2 and catch-all `_` clauses return a plausible value for malformed or unexpected input instead of failing, so corruption escapes the process that produced it. Destructure with a match and enumerate the expected case clauses so a mismatch raises a localized MatchError or CaseClauseError the supervisor can act on."
---
# ADR-008: Non-assertive pattern matching

## Context

Elixir systems are built from many supervised processes. An error in one process is localized: the supervisor detects it, reports it, and can restart the process while the rest of the application keeps running. That containment only works if errors actually surface. Code that defends against malformed input by returning a plausible-looking value instead of failing defeats containment, because the bad value escapes the process that produced it and corrupts callers far from the source.

The BEAM offers assertive constructs for exactly this: a match with `=`, function-head and `case/2` patterns, and guards. A failed match raises `MatchError` (or `CaseClauseError`) at the precise line of the mismatch, with the offending value in the message. That is a loud, localized failure a supervisor can act on. Defensive accessors like `Enum.at/2`, which returns `nil` for an out-of-range index, instead convert a structural violation into a silent wrong answer that looks like success.

This is the pattern-matching sibling of ADR-007 Non-assertive map access, which covers reading keys out of maps.

## Decision

### Rule 1: Destructure with a match, not positional accessors

**Correct:**

```elixir
defmodule MyApp.Extract do
  def get_value(query_string, desired_key) do
    query_string
    |> String.split("&")
    |> Enum.find_value(fn pair ->
      [key, value] = String.split(pair, "=")
      key == desired_key && value
    end)
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Extract do
  def get_value(query_string, desired_key) do
    query_string
    |> String.split("&")
    |> Enum.find_value(fn pair ->
      key_value = String.split(pair, "=")
      Enum.at(key_value, 0) == desired_key && Enum.at(key_value, 1)
    end)
  end
end
```

**Why:** A well-formed pair `"lab=ASERG"` splits to `["lab", "ASERG"]`, but a malformed segment `"university=institution=UFMG"` splits to `["university", "institution", "UFMG"]`. `Enum.at/2` never fails on the malformed list: it reads index 0 and index 1 and reports `"institution"` as the value, so `get_value/2` returns a wrong answer that looks correct and propagates to its caller. The match `[key, value] = String.split(pair, "=")` asserts exactly two parts and raises `MatchError` on anything else, naming the offending list in the message. The crash is localized to the process that hit it and hands the decision (treat as invalid, or handle a newly discovered case) back to the caller instead of silently emitting corrupt data.

### Rule 2: Match every expected return shape, not a catch-all `_`

**Correct:**

```elixir
case MyApp.Accounts.fetch_user(id) do
  {:ok, user} -> render(user)
  {:error, _reason} -> render_error()
end
```

**Wrong:**

```elixir
case MyApp.Accounts.fetch_user(id) do
  {:ok, user} -> render(user)
  _ -> render_error()
end
```

**Why:** A bare `_` clause matches any value, so it absorbs return shapes the author never considered. If `fetch_user/1` later gains a `{:pending, token}` return, the catch-all swallows it and renders an error for a non-error result, with no crash to point at the regression. The correct version asserts the `{:error, _reason}` tuple shape (only the unused reason is wildcarded) and leaves any unanticipated shape unmatched, so a new return raises `CaseClauseError` at the call site. That loud, localized failure is the signal that the contract changed. Reserve `_` for the inner values that are genuinely irrelevant, not for the whole result.

## Consequences

- Malformed input crashes at the line that destructures it, naming the offending value, instead of producing a plausible wrong answer somewhere downstream.
- Failures stay inside the process that hit them, where the supervisor can report and restart, rather than propagating corrupt data to callers.
- Adding a new return shape to a matched function surfaces as a `CaseClauseError` at every call site that did not handle it, instead of being silently captured by `_`.
- Wildcards are reserved for values that are genuinely unused, keeping each clause's intent explicit.
