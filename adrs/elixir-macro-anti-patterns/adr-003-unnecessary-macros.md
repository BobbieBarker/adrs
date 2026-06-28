---
type: adr
id: 3
title: "Unnecessary macros"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, macros, meta-programming, compile-time]
description: "A macro receives unevaluated AST at compile time and expands inline at every call site, forcing callers to `require` it; a function receives values at runtime and is shared as one compiled body. Use `defmacro` only when the code must manipulate unevaluated code, otherwise a named function is simpler and carries no compile-time dependency."
---
# ADR-003: Unnecessary macros

## Context

A macro is meta-programming. Its arguments arrive as quoted AST at compile time, its return value is also AST, and that AST is spliced into the call site and compiled in place. A function is different: it receives already-evaluated values at runtime and runs as one shared compiled body. The two mechanisms are not interchangeable. A macro is the right tool only when the code must inspect or transform unevaluated code before it runs (deferred evaluation, AST inspection, generating definitions).

Reaching for `defmacro` where a plain function would do adds cost and removes capability for nothing. Every caller must `require` the defining module, which creates a compile-time dependency on it (ADR-001), and when that dependency goes untracked it silently goes stale (ADR-005). The macro body expands into each call site instead of living in one place, and the macro is not a runtime value, so it cannot be captured with `&`, passed as an argument, or piped. Because macros are harder to write, read, and reason about, indiscriminate use compromises maintainability while buying nothing in return.

## Decision

### Rule 1: Use a named function unless the code must manipulate unevaluated code

**Correct:**

```elixir
defmodule MyApp.Math do
  def sum(a, b), do: a + b
end

MyApp.Math.sum(3, 5)
MyApp.Math.sum(3 + 1, 5 + 6)
```

**Wrong:**

```elixir
defmodule MyApp.Math do
  defmacro sum(a, b) do
    quote do
      unquote(a) + unquote(b)
    end
  end
end

require MyApp.Math
MyApp.Math.sum(3, 5)
```

**Why:** The macro computes nothing the function cannot; both produce `8`. But `sum/2` as a macro runs at compile time on the AST of its arguments, forces every caller to `require MyApp.Math`, and expands `unquote(a) + unquote(b)` inline at each call site instead of sharing one compiled body. That `require` is a compile-time dependency (ADR-001). The function version drops the `require`, exists as a real runtime value (capturable as `&MyApp.Math.sum/2`, passable, pipeable), and is simpler to read, test, and reason about. Reserve `defmacro` for code that must operate on unevaluated AST.

## Consequences

- `defmacro` is reserved for code that must inspect or transform unevaluated AST, so its presence signals genuine meta-programming rather than an ordinary computation in disguise.
- The logic stays plain runtime code: directly testable in isolation and composable with the rest of the language, with no quoting, unquoting, or macro hygiene to get wrong.
- Readers and tooling reason about the call as data flow, not as an expansion they must perform in their heads.
