---
type: adr
id: 6
title: "Using application configuration for libraries"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, configuration, library-design, application-environment, supervision]
description: "A library that reads its own configuration from the application environment exposes a single node-global value per key, so every consumer and every call site is locked into one behavior. Take configuration as function arguments, consumer-owned child specs, or required options on `use` instead."
---
# ADR-006: Using application configuration for libraries

## Context

The application environment (`Application.get_env/3`, `Application.fetch_env!/2`, `Application.compile_env/3`) is a node-global key-value store, indexed by application name and key, used to parameterize values across an Elixir system. It is a useful mechanism and not an anti-pattern by itself. The anti-pattern is a library author reaching for it to configure the library's own behavior.

Because the store is global, there is exactly one value for each `{application, key}` pair on the node. A library that reads its configuration from the application environment therefore exposes exactly one configurable value to the entire world: every application that depends on the library, and every call site within those applications, shares it. Two consumers of the same library cannot configure the same aspect differently, and a single consumer cannot vary it between two calls.

The fix in every case is to source configuration from the caller rather than from library-owned global state: function arguments for runtime values, consumer-owned child specs for processes, and required options on `use` for compile-time values. Each pushes the decision to the point where the library is consumed.

## Decision

### Rule 1: Take runtime configuration as function arguments

**Correct:**

```elixir
defmodule DashSplitter do
  def split(string, opts \\ []) when is_binary(string) and is_list(opts) do
    parts = Keyword.get(opts, :parts, 2)
    String.split(string, "-", parts: parts)
  end
end

# Each call site chooses its own behavior:
DashSplitter.split("a-b-c-d", parts: 3)
DashSplitter.split("a-b-c-d")
```

**Wrong:**

```elixir
# config/config.exs
config :dash_splitter, parts: 3

defmodule DashSplitter do
  def split(string) when is_binary(string) do
    parts = Application.fetch_env!(:dash_splitter, :parts)
    String.split(string, "-", parts: parts)
  end
end
```

**Why:** The application environment is a node-global store indexed by `{application, key}`, so a library that calls `Application.fetch_env!(:dash_splitter, :parts)` reads exactly one slot for the entire node. Every dependent application, and every call site within them, is forced into the same `parts` value, and a single caller cannot ask for three parts here and five parts there. A keyword list parameter moves the choice to the call site: the default lives in the function head and any caller overrides it per call. The legitimate exception is using the application environment to swap one behaviour-conforming dependency for another (for example, an alternate CSV parser): that is fine because the outcome must be identical regardless of which implementation is chosen.

### Rule 2: Expose a child spec instead of starting your own supervision tree

**Correct:**

```elixir
# The library provides a child spec; the consumer starts it under its own tree
# and reads its own application env only if it wants per-environment values.
children = [
  {DNSCluster, query: Application.get_env(:my_app, :dns_cluster_query) || :ignore}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

**Wrong:**

```elixir
# The library starts its own tree and reads global config to parameterize it.
defmodule DNSCluster.Application do
  use Application

  def start(_type, _args) do
    query = Application.fetch_env!(:dns_cluster, :query)
    children = [{DNSCluster.Worker, query: query}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

**Why:** An application starts exactly one supervision tree, so if the library starts its own and reads its options from the global application environment, those options are fixed once per node for all consumers. Exposing a child specification inverts ownership: the consumer lists the process under its own supervision tree and passes options at init time, reading its own application's environment only if and when it wants per-environment values. The library never forces the global lookup on anyone.

### Rule 3: Take compile-time configuration as options on `use`

**Correct:**

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, adapter: Ecto.Adapters.Postgres
end

# The consumer decides for itself whether to vary the value per environment:
defmodule MyApp.Repo do
  use Ecto.Repo, adapter: Application.compile_env(:my_app, :repo_adapter)
end
```

**Wrong:**

```elixir
# The library bakes one global adapter at compile time for every consumer.
defmodule Ecto.Repo do
  defmacro __using__(_opts) do
    quote do
      @adapter Application.compile_env(:ecto, :adapter)
      # ... a single repo, configured once for the whole node
    end
  end
end
```

**Why:** `Application.compile_env/3` is read once during compilation from the same node-global store and frozen into the compiled artifact, so a library that calls it internally bakes a single value for every consumer (for a repository library, that means one repo for the whole node). Requiring the value as an option on `use` generates the configured code per call site, so a consumer can define as many repositories as it needs and choose for itself whether to source each adapter from its own application environment. Code generation carries its own tradeoffs, so reserve it for configuration that genuinely must be fixed at compile time.

## Consequences

- Configuration lives at the call site (keyword lists), in the consumer's own supervision tree (child specs), or in the consumer's own module (`use` options), never in node-global application environment owned by the library.
- Multiple consumers, and multiple call sites within one consumer, configure the same library aspect independently.
- Library behavior is determined by its arguments, so tests do not mutate shared application environment between runs and can stay `async: true`.
- Acceptable residual uses remain: swapping a behaviour-conforming implementation, or providing customizable defaults when generating code from data files, where the chosen value does not change the outcome.
- Mix tasks read per-project configuration via `Mix.Project.config/0` or `OptionParser` command-line arguments rather than the global application environment.
