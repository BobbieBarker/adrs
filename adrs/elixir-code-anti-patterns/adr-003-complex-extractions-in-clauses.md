---
type: adr
id: 3
title: "Complex extractions in clauses"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, pattern-matching, multi-clause, readability, functions]
description: "A multi-clause function head should bind only the variables its patterns and guards use to select a clause. Extracting body-only struct or map fields in the head hides which bindings actually drive dispatch, because nothing distinguishes a selection variable from local plumbing in the signature."
---
# ADR-003: Complex extractions in clauses

## Context

A multi-clause function dispatches on its heads. Pattern matching and guards in a head decide which clause runs; every other binding in that head is plain local plumbing that happens to be written in the signature. Elixir lets you extract any number of fields from a struct or map argument directly in the head, and use those bindings either for dispatch or only inside the body.

That flexibility hides a readability cost. When extractions are spread across several clauses and several arguments, a reader can no longer tell at a glance which extracted variables participate in clause selection and which are merely consumed by the body. The head stops being a precise statement of the dispatch contract and becomes a mix of contract and data access. With many clauses, arguments, and extracted fields, recovering "what actually decides this clause" means diffing each head against its guard by eye.

The fix is to keep the head minimal: extract only the variables a pattern or guard needs, bind the whole argument with `= var`, and pull body-only fields out inside the body where they are used.

## Decision

### Rule 1: Extract only clause-deciding variables in the head

**Correct:**

```elixir
def drive(%User{age: age} = user) when age >= 18 do
  %User{name: name} = user
  "#{name} can drive"
end

def drive(%User{age: age} = user) when age < 18 do
  %User{name: name} = user
  "#{name} cannot drive"
end
```

**Wrong:**

```elixir
def drive(%User{name: name, age: age}) when age >= 18 do
  "#{name} can drive"
end

def drive(%User{name: name, age: age}) when age < 18 do
  "#{name} cannot drive"
end
```

**Why:** Only `age` decides which clause of `drive/1` runs; `name` is never matched on and never reaches a guard. In the wrong version the head binds both, so a reader scanning the signatures cannot separate the dispatch variable (`age`) from the body-only field (`name`) without reading the guard and the body to confirm. That conflation scales with the function: more clauses, more arguments, and more extracted fields turn every head into a puzzle about what is load-bearing for dispatch. The correct version makes the head the contract: `%User{age: age} = user` says "this clause matches on age," and `%User{name: name} = user` in the body binds the rest next to the code that consumes it.

## Consequences

- Each head reads as the dispatch contract: every binding in it either pattern-matches or feeds a guard.
- Body-only fields are bound where they are used, not announced in the signature.
- Adding a clause or an extracted field no longer forces re-reading every head to recover which variables drive selection.
- Multi-argument, multi-clause functions stay legible because the heads carry only selection logic.
