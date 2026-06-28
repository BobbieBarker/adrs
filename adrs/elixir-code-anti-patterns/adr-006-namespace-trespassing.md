---
type: adr
id: 6
title: "Namespace trespassing"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, modules, libraries, code-loading]
description: "A library must define every module under a prefix derived from its own package name, because the BEAM loads exactly one module per fully qualified name per node, so two libraries defining the same name become mutually incompatible."
---
# ADR-006: Namespace trespassing

## Context

The BEAM identifies a module by its fully qualified name, which is an atom. At any instant the virtual machine holds exactly one loaded instance per module name across the entire node. Two libraries that both define a module under the same name cannot coexist in a single release: code loading is keyed on the name alone, so whichever beam file loads wins and the other library silently runs against an implementation it did not write.

A library prevents this by treating its own name as a prefix and defining every module beneath it. A package named `:my_lib` defines `MyLib`, `MyLib.User`, `MyLib.Application`, and nothing outside the `MyLib` namespace. The prefix is the only thing that makes the names globally unique, because the runtime has no per-library scoping. Defining a module outside your own namespace, trespassing into a namespace owned by another package or the standard library, is the anti-pattern.

The hazard is latent and lands on someone else. An extension package `:plug_auth` that defines `Plug.Auth` works fine until `Plug` itself ships a `Plug.Auth` module in a later release. From that point the two packages define the same name and become mutually incompatible, and the clash surfaces at a downstream user's dependency resolution rather than at your build.

## Decision

### Rule 1: Prefix every module with your library's name

**Correct:**

```elixir
# package :plug_auth
defmodule PlugAuth do
  # ...
end

defmodule PlugAuth.Pipeline do
  # ...
end
```

**Wrong:**

```elixir
# package :plug_auth
defmodule Plug.Auth do
  # ...
end
```

**Why:** The BEAM loads exactly one module per fully qualified name per node. If `Plug` later defines its own `Plug.Auth`, the two definitions collide and the libraries cannot be used together, with the loaded one shadowing the other. A unique top-level prefix derived from the package name is the only guarantee against this collision. Three exceptions are sanctioned: protocol implementations are defined under the protocol's namespace by design (`defimpl`); a namespace owner may explicitly invite extensions into a sub-namespace, as Elixir does with custom Mix tasks under `Mix.Tasks.*`; and if you maintain both packages, you may share a namespace and own the responsibility for any future conflict.

## Consequences

- Two of your library's modules can never clash with a third party's, because the unique prefix is carried by every name.
- Module names read as self-documenting ownership: the prefix tells a reader and a tool which package a module belongs to.
- Extensions of another library (`:plug_auth`, `:ecto_enum`) carry their own root namespace instead of borrowing the host's.
- The sanctioned exceptions stay narrow: `defimpl`, owner-invited sub-namespaces such as `Mix.Tasks.*`, and packages you maintain on both sides of the boundary.
