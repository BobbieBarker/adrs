---
type: adr
id: 2
title: "Complex `else` clauses in `with`"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, with, error-handling, control-flow, readability]
description: "A `with` expression's single `else` block flattens the failures of every `<-` clause into one place, stripping the provenance of which clause failed and letting structurally similar errors collapse into the wrong catch-all. Normalize each step's return in a private function so `with` expresses only the success path."
---
# ADR-002: Complex `else` clauses in `with`

## Context

A `with` expression chains fallible steps with `<-`. When a step's value does not match the pattern on the left of its `<-`, the chain aborts and hands that non-matching value to the expression's single `else` block.

That single `else` is the problem. It receives the failure value from whichever clause aborted, stripped of any indication of which clause that was. Every `<-` in the chain funnels its failures into the same block, so the error-handling logic for unrelated steps is flattened together. Reading the `else`, you cannot tell which pattern on the left produced which branch on the right.

This degrades as the chain grows. Two steps that both fail with a structurally similar value (for example both returning `{:error, _}`) collapse into one catch-all clause in the `else`. A clause written to handle one step's failure silently captures another step's failure and maps it to the wrong reason. The more `<-` clauses a `with` has, the more likely unrelated failures overlap.

The fix is to give each fallible step a return shape that is unique and self-describing at its source, so `with` can express the success path alone and drop the `else` entirely.

## Decision

### Rule 1: Normalize each step's failure in a private function, not in a shared `else`

**Correct:**

```elixir
def open_decoded_file(path) do
  with {:ok, encoded} <- file_read(path),
       {:ok, decoded} <- base_decode64(encoded) do
    {:ok, String.trim(decoded)}
  end
end

defp file_read(path) do
  case File.read(path) do
    {:ok, contents} -> {:ok, contents}
    {:error, _} -> {:error, :badfile}
  end
end

defp base_decode64(contents) do
  case Base.decode64(contents) do
    {:ok, decoded} -> {:ok, decoded}
    :error -> {:error, :badencoding}
  end
end
```

**Wrong:**

```elixir
def open_decoded_file(path) do
  with {:ok, encoded} <- File.read(path),
       {:ok, decoded} <- Base.decode64(encoded) do
    {:ok, String.trim(decoded)}
  else
    {:error, _} -> {:error, :badfile}
    :error -> {:error, :badencoding}
  end
end
```

**Why:** In the wrong version the `else` block receives the aborting value from either `<-` clause with no record of which one fired. `File.read/1` failing with `{:error, _}` and `Base.decode64/1` failing with `:error` happen to be distinguishable here only because their shapes differ. Add a third step that also returns `{:error, _}` and it collapses into the existing `{:error, _} -> {:error, :badfile}` clause, mapping an unrelated failure to `:badfile` with no warning. Normalizing inside `file_read/1` and `base_decode64/1` attaches each failure reason at the exact site that produces it, so the shapes never compete for a shared clause. The `with` then has nothing to handle but the success case and the `else` disappears.

## Consequences

- `with` reads as the success path only; each step's failure is named at the function that produces it.
- Adding a step cannot silently re-route an existing step's error, because failures no longer share one catch-all clause.
- The normalizing functions are pure, independently testable, and reusable across other call sites.
- There is no `else` block to keep synchronized as the chain grows or reorders.
