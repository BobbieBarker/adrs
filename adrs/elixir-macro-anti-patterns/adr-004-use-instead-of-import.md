---
type: adr
id: 4
title: "`use` instead of `import`"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, macros, use, code-generation, modularity]
description: "`use M` expands at compile time to `M.__using__/1`, whose quoted body is injected verbatim into the caller, hiding propagated imports, behaviours, and definitions and creating compile-time dependencies. Prefer lexically scoped `import`/`alias` when no code injection is required."
---
# ADR-004: `use` instead of `import`

## Context

`import`, `alias`, and `use` all establish dependencies between modules, but `use` is categorically different. `import` and `alias` are lexically scoped directives: they shorten name resolution inside the file that writes them and generate no code. `use M, opts` instead expands at compile time to `require M; M.__using__(opts)`, and `__using__/1` is a macro whose returned quoted expression is spliced verbatim into the calling module.

Because that injected expression is arbitrary, it can import modules, alias modules, define functions, register attributes, and declare behaviours, all invisibly. The `use M` line at the call site reveals none of it. Reading it requires reading the internal details of `__using__/1` in `M`. This broad scope is the smell: an injected `import` silently shadows or conflicts with the caller's own functions, and a propagated `import` makes the caller compile-depend on a module it never named (the compile-time dependency machinery is ADR-001 and ADR-005). When the injected block grows large it compounds into ADR-002, and the question of whether the macro should exist at all is ADR-003.

## Decision

### Rule 1: Use `import`/`alias` when no code injection is needed

**Correct:**

```elixir
defmodule MyApp.Library do
  def from_lib, do: "from library"
end

defmodule MyApp.Client do
  import MyApp.Library

  def foo, do: "local client function"

  def run, do: from_lib() <> " - " <> foo()
end
```

**Wrong:**

```elixir
defmodule MyApp.Helpers do
  def foo, do: "from helpers"
end

defmodule MyApp.Library do
  defmacro __using__(_opts) do
    quote do
      import MyApp.Library
      import MyApp.Helpers   # propagates a dependency the caller never named
    end
  end

  def from_lib, do: "from library"
end

defmodule MyApp.Client do
  use MyApp.Library

  # ** (CompileError) imported MyApp.Helpers.foo/0 conflicts with local function
  def foo, do: "local client function"

  def run, do: from_lib() <> " - " <> foo()
end
```

**Why:** `use MyApp.Library` expands to `MyApp.Library.__using__([])`, and the macro's quoted body (two `import` directives) is spliced into `MyApp.Client`. Nothing at the `use` line states that `MyApp.Helpers` is now imported, so `foo/0` collides with the local definition and the module fails to compile. The caller also picks up a compile-time dependency on every propagated import (ADR-001, ADR-005). `import` and `alias` are lexically scoped: they only affect name resolution in the file that writes them and emit no code, so the dependency set and the available names are exactly what the directives list.

### Rule 2: When `use` is genuinely required, publish a nutrition facts label

**Correct:**

```elixir
defmodule MyApp.Worker do
  @moduledoc """
  A supervised worker base.

  > #### `use MyApp.Worker` {: .info}
  >
  > When you `use MyApp.Worker`, it sets `@behaviour MyApp.Worker`
  > and defines a `child_spec/1` function so your module can be
  > started directly under a supervisor.
  """

  @callback handle_job(term()) :: :ok

  defmacro __using__(_opts) do
    quote do
      @behaviour MyApp.Worker

      def child_spec(arg) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
      end
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Worker do
  @moduledoc "A supervised worker base."

  defmacro __using__(_opts) do
    quote do
      @behaviour MyApp.Worker
      import MyApp.Worker.Internals

      def child_spec(arg) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
      end
    end
  end
end
```

**Why:** Some cases legitimately need injection: declaring a behaviour, defining `child_spec/1`, registering attributes (whether the macro is warranted at all is ADR-003). What the wrong version omits is any record of it. A developer reading `use MyApp.Worker` cannot see that a behaviour, a public `child_spec/1`, and an `import MyApp.Worker.Internals` were added without opening `__using__/1`. The `{: .info}` admonition is the documented contract for the names `use` injects into the caller. List only public-API additions: a private attribute such as `@_worker_meta` stays out of the label.

## Consequences

- Plain delegation uses lexically scoped `import`/`alias`; `use` is reserved for cases that genuinely require code injection.
- Name conflicts surface at the call site instead of being introduced by hidden propagated imports.
- The modules a file compile-depends on are visible in its directives rather than buried inside a `__using__/1` body (ADR-005).
- Where `use` remains, the moduledoc nutrition facts label documents exactly what it injects into the caller's public API.
