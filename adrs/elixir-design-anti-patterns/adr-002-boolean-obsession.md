---
type: adr
id: 2
title: "Boolean obsession"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, design, data-modeling, atoms]
description: "Multiple overlapping boolean options or struct fields encode one piece of state across 2^N representable combinations, most of which are invalid and must be resolved by hand-written priority logic. Replace them with a single atom field (or a composite type) whose values name only the valid states."
---
# ADR-002: Boolean obsession

## Context

Boolean obsession is using booleans to encode information that a richer type models better. The booleans themselves are not the problem. The problem appears when two or more booleans describe one underlying piece of state with overlapping or mutually exclusive values. N booleans make 2^N combinations representable, but usually only a few are valid. The invalid combinations do not disappear: they have to be excluded by hand, with priority logic that silently picks a winner when two flags are set at once.

A function taking `admin: true` and `editor: true` is the canonical case: two flags configuring one notion of access.

This is the boolean-typed case of the Primitive obsession anti-pattern; see it for the general rule. The fix is the same: replace the primitives with one type whose values name exactly the valid states. An atom suffices when those states form a flat enumeration; reach for a tuple or other composite type when the collapsed state is structured rather than a flat set of names.

## Decision

### Rule 1: Collapse overlapping booleans into a single atom

When several booleans encode one mutually exclusive state, replace them with one field whose atom values enumerate the valid states.

**Correct:**

```elixir
defmodule MyApp.Invoices do
  def process(invoice, options \\ []) do
    case Keyword.get(options, :role, :default) do
      :admin -> handle_admin(invoice)
      :editor -> handle_editor(invoice)
      :default -> handle_default(invoice)
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Invoices do
  def process(invoice, options \\ []) do
    cond do
      options[:admin] -> handle_admin(invoice)
      options[:editor] -> handle_editor(invoice)
      true -> handle_default(invoice)
    end
  end
end
```

**Why:** The two booleans admit four combinations, but only three are meaningful and `admin: true, editor: true` is a contradiction. The `cond` resolves that contradiction by clause order (admin wins), so the invalid state is reachable and the priority rule is invisible at the call site. A single `:role` atom makes only `:admin`, `:editor`, and `:default` representable: the contradiction cannot be constructed, and the `case` is exhaustive over the valid set. The same applies to data: a `User` struct carrying `:admin` and `:editor` booleans should carry one `:role` field, so the struct cannot hold an admin-and-editor record.

### Rule 2: Prefer a named state atom over a lone boolean that will grow

Even a single boolean argument is better expressed as an atom when the domain has, or will have, more than two states.

**Correct:**

```elixir
MyApp.Invoices.update(invoice, status: :approved)
```

**Wrong:**

```elixir
MyApp.Invoices.update(invoice, approved: true)
```

**Why:** `approved: true` hard-codes a binary into the contract. Adding a third state such as `:pending` forces either a second boolean (`pending: true`), which reintroduces the overlapping-combination problem from Rule 1, or a breaking change to the boolean's meaning. A `status:` atom extends by adding one clause and one atom value, with no new representable contradictions. It also reads at the call site: `status: :approved` states the domain concept, `approved: true` states an implementation detail. Because booleans are internally the atoms `:true`/`:false`, there is no performance difference between the two forms.

## Consequences

- Invalid flag combinations stop being representable, and the hand-written priority logic that used to resolve them disappears.
- Adding a state is a new atom value and a new clause, not another boolean that multiplies the combination space.
- `case` over the atom is exhaustive, so the compiler and Dialyzer can flag an unhandled state.
