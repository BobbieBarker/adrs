---
type: adr
id: 1
title: "Alternative return types"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, design, api-design, return-types, typespecs]
description: "A function whose options change its return type forces its spec into a union of every possible shape that no caller can narrow, because the option selecting the shape is a runtime value. Give each return shape its own named function so each has a single, statically knowable return type."
---
# ADR-001: Alternative return types

## Context

This anti-pattern is a function that takes an options keyword list where one of those options changes the function's return type. The classic shape is a parser whose `:discard_rest` option flips the result between a bare `integer()` and a `{integer(), String.t()}` tuple.

Options are optional and are frequently built dynamically: merged from application config, request parameters, or computed defaults. When the value that selects the return shape is itself a runtime value, no caller can statically know which shape comes back without tracing where every option was set.

The mechanism is type resolution at the call site. Elixir resolves the return shape here at runtime, so the function's typespec degenerates into a union of every shape any option combination can produce (`integer() | {integer(), String.t()} | :error`). Nothing ties a given call site to a single member of that union, so both a human reader and the type checker must treat every call as possibly returning any member. The wider the union, the less a `case` on the result can be made exhaustive, and the more defensive every call site becomes.

## Decision

### Rule 1: One function name per return type

Give each return shape its own named function. Do not let an option select the return type.

**Correct:**

```elixir
defmodule MyApp.Parser do
  @spec parse(String.t()) :: {integer(), String.t()} | :error
  def parse(string) do
    Integer.parse(string)
  end

  @spec parse_discard_rest(String.t()) :: integer() | :error
  def parse_discard_rest(string) do
    case Integer.parse(string) do
      {int, _rest} -> int
      :error -> :error
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Parser do
  @spec parse(String.t(), keyword()) :: integer() | {integer(), String.t()} | :error
  def parse(string, options \\ []) when is_list(options) do
    if Keyword.get(options, :discard_rest, false) do
      case Integer.parse(string) do
        {int, _rest} -> int
        :error -> :error
      end
    else
      Integer.parse(string)
    end
  end
end
```

**Why:** In the wrong version the selecting option (`:discard_rest`) is a runtime value, so neither a reader nor the type checker can narrow the return at a call site. The spec collapses to a three-member union that every caller must defensively destructure, even though any concrete call returns exactly one shape. A `case` on the result cannot be made total, because the compiler cannot rule out the other members. Splitting into two named functions gives each a single, statically knowable return type: the name announces the shape, each spec is a smaller union, and the compiler's type inference can check each call site against one concrete return. Options remain appropriate for behavior that does not change the return type.

## Consequences

- Each function has one documented return type, and the function name announces which shape the caller gets.
- Specs narrow from a union-of-all-options into one type per function, so type inference and Dialyzer can check call sites instead of widening every caller to the full union.
- Callers pattern match the result exhaustively without inspecting which options were passed or where they were set.
- Options stay available for behavior that does not alter the return type; only the return-type-selecting option is removed.
