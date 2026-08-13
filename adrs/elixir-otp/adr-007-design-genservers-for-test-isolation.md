---
type: adr
id: 7
title: Design GenServers for Test Isolation
status: accepted
date: 2026-04-29
updated: 2026-08-09
tags: [elixir, otp, genserver, testing, dependency-injection]
description: "Every GenServer accepts a configurable :name, validates its opts at start with NimbleOptions, and converts those opts into state exactly once through a State module constructor. When the server has substitutable collaborators, inject them via opts. When it owns storage whose contract is a cache, use a cache library with a sandbox adapter; inject other purpose-built stores through Deps. Mox is reserved for collaborators the test cannot start, such as HTTP APIs and third-party SDKs."
---

# ADR-007: Design GenServers for Test Isolation

## Context

A GenServer that registers itself under a fixed global atom can only exist once per VM. Every test that touches it either serializes against every other test or shares state with it. Neither supports a healthy test suite. Test isolation begins with two universal choices: every GenServer accepts a configurable name, and every GenServer turns its opts into state in one named place. Opts arrive from a supervision tree in production and from a test in the suite, and both paths have to produce the same state. Beyond those two, additional choices apply when the server has substitutable collaborators or owns storage. Not every GenServer does. A pure-coordination server with no external dependencies needs only the configurable name and validated opts; the situational rules in this ADR apply when their conditions are met.

## Decision

### Universal rules

#### Rule 1: Every GenServer accepts a configurable :name

The server's registered name is set in opts, with the production default supplied by the supervision tree. This is non-negotiable. Without it, tests cannot spin up isolated instances.

**Correct:**

```elixir
defmodule MyApp.Inventory.Server do
  use GenServer

  def start_link(%{name: _name} = opts), do: start(opts)

  defp start(%{name: nil} = opts),
    do: GenServer.start_link(__MODULE__, opts)

  defp start(%{name: name} = opts),
    do: GenServer.start_link(__MODULE__, opts, name: name)
end

# in a test:
setup do
  server = start_supervised!({MyApp.Inventory.Server, %{name: nil}})
  {:ok, server: server}
end
```

**Wrong:**

```elixir
defmodule MyApp.Inventory.Server do
  use GenServer

  def start_link(_opts),
    do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
end
```

**Why:** `name: __MODULE__` registers the process in the node-local name registry, which is a single namespace per VM, so a second `start_link/1` with the same atom returns `{:error, {:already_started, pid}}` and `start_supervised!` raises. The only remaining way to exercise the server is to reuse the one instance the application started, which carries each test's writes into the next. In the Correct version the supervision tree passes the production name, while an ordinary test passes `name: nil`, captures the supervised PID, and avoids registration entirely. The two instances share no registry entry, mailbox, or state, and the suite runs `async: true`. When registration itself is the behavior under test, start a test Registry and use a reference-bearing identity such as `{:via, Registry, {registry, make_ref()}}`; never manufacture atoms from test data or counters.

#### Rule 2: Take opts as a validated map and build state once in a State module

Accept opts as a map, not a keyword list. Validate them at the boundary with a declarative schema. `NimbleOptions` is the usual choice, and Broadway and Finch both validate their own options with it. Declare the schema as a module attribute, let the library handle type checking, defaults, required-key enforcement, and error messages, then convert the validated opts into state exactly once, in `init/1`, by calling a constructor on a State module that lives under the subsystem namespace.

**Correct:**

```elixir
defmodule MyApp.Inventory.Server do
  use GenServer

  alias MyApp.Inventory.State

  @opts_schema NimbleOptions.new!(
                 name: [
                   type: :any,
                   required: true,
                   doc: "Registered name as an atom or `:via` tuple; `nil` starts unregistered."
                 ],
                 threshold: [type: :pos_integer, default: 100],
                 cache: [type: :atom, default: MyApp.Inventory.Cache]
               )

  def start_link(opts) when is_map(opts) do
    opts =
      opts
      |> Keyword.new()
      |> NimbleOptions.validate!(@opts_schema)
      |> Map.new()

    start(opts)
  end

  defp start(%{name: nil} = opts),
    do: GenServer.start_link(__MODULE__, opts)

  defp start(%{name: name} = opts),
    do: GenServer.start_link(__MODULE__, opts, name: name)

  @impl true
  def init(opts), do: {:ok, State.new(opts)}
end
```

**Wrong:**

```elixir
defmodule MyApp.Inventory.Server do
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {:ok, %{threshold: Keyword.get(opts, :threshold, 100)}}
  end
end
```

**Why:** `NimbleOptions.validate!/2` raises `NimbleOptions.ValidationError` from inside `start_link/1`, so a bad option surfaces as a failed `start_child` at boot, before the process is registered or reachable by any caller. With `Keyword.get(opts, :threshold, 100)`, an absent or misspelled key takes the default, while a present value of the wrong type passes through unchanged; neither behavior validates the option contract. The schema is also the single declaration of that contract, so required keys, types, defaults, and per-key documentation live in one place instead of being re-derived at each read site. Hand-rolled `validate_opts!` functions accumulate a clause per caller; a declarative schema does not.

The value `init/1` returns is built in one named place, so a test constructs the state a supervisor would have constructed by calling `State.new/1` with the same map, without starting a process to observe it, and a reviewer has one function to read to learn what the process starts with. ADR-012 Rule 1 governs that module's shape: a struct with `@enforce_keys` and a single construction function.

### Situational rules

#### Rule 3: Inject substitutable collaborators via opts (only when present)

If the server calls into a collaborator that tests need to substitute (a clock, an external API client, a mailer), accept the collaborator module as a schema key with the production module as its default. The state groups those modules behind a `Deps` struct rather than scattering them across top-level fields, per ADR-012 Rule 2 (group configuration, injected collaborators, and working state separately).

This rule does NOT apply to GenServers with no substitutable collaborators. A pure-coordination server that holds its own state, dispatches its own messages, and calls only into pure functions or already-isolated context modules needs no injection. Adding it as a ceremony hurts readability.

**Correct:**

```elixir
defmodule MyApp.Inventory.Server do
  use GenServer

  alias MyApp.Inventory.{Deps, Impl, State}

  @opts_schema NimbleOptions.new!(
                 name: [type: :any, required: true],
                 clock: [type: :atom, default: DateTime]
               )

  def start_link(opts) when is_map(opts) do
    opts =
      opts
      |> Keyword.new()
      |> NimbleOptions.validate!(@opts_schema)
      |> Map.new()

    start(opts)
  end

  defp start(%{name: nil} = opts),
    do: GenServer.start_link(__MODULE__, opts)

  defp start(%{name: name} = opts),
    do: GenServer.start_link(__MODULE__, opts, name: name)

  @impl true
  def init(opts), do: {:ok, State.new(opts)}

  @impl true
  def handle_call({:expired?, id}, _from, %State{deps: %Deps{clock: clock}} = state) do
    {:reply, Impl.expired?(state, id, clock.utc_now()), state}
  end
end

# in a test:
setup do
  opts = %{name: nil, clock: MyApp.Inventory.FrozenClock}
  server = start_supervised!({MyApp.Inventory.Server, opts})
  {:ok, server: server}
end
```

**Wrong:**

```elixir
@impl true
def init(%{name: name}) do
  {:ok, State.new(%{name: name, clock: DateTime})}
end
```

**Why:** A module named literally in `init/1` is compiled into the state as a fixed atom, so no seam remains for a test to reach and the substitution has to be bolted on somewhere else. Both places it gets bolted on are worse. `Application.put_env/3` writes to one VM-wide key/value store that every process on the node reads, so one test's frozen clock is every concurrent test's clock, and the file gives up `async: true` to stay correct. Declaring a behaviour and mocking it pays Rule 5's costs for a collaborator that has none of Mox's justifications. An injected module travels in the state struct of one process, so two servers started by two concurrent tests hold two different clock modules and neither can observe the other's choice. The reverse failure is equally concrete: a GenServer with no substitutable collaborator that grows opt-injected dependencies pays the indirection of a module atom in place of a call a reader can jump to, and buys no isolation, because there was no shared resource to isolate.

#### Rule 4: Delegate caches to a cache library with a sandbox adapter (only when the contract is a cache)

If the subsystem owns storage whose contract is cache semantics (misses are acceptable, entries expire or may be evicted, and operations are key-scoped), do not hand-roll it with `:ets.new/2` inside `init/1`. Use a library that provides an adapter pattern over cache backends and a sandbox adapter for test isolation.

This rule does NOT apply to GenServers with no storage of their own, and it does not turn every purpose-built store into a cache. A presence store, durable ledger, or application-specific projection retains its own contract and lives outside the GenServer; inject its module or handle through `Deps`. State that lives in the process struct is fine without ceremony when every field is fixed at boot or is bounded coordination state removed on every terminal path. ADR-003 Rule 1 carries the heap mechanism behind that boundary.

**Correct:**

```elixir
defmodule MyApp.Inventory.Cache do
  use Cache,
    adapter: Cache.ETS,
    name: :inventory_cache,
    sandbox?: Mix.env() === :test,
    opts: []
end

# lib/my_app/application.ex - the cache is a process and needs a supervisor.
# Declaring the module without starting it leaves every read returning an error.
def start(_type, _args) do
  children = [
    MyApp.Inventory.Cache,
    {MyApp.Inventory.Server, %{name: MyApp.Inventory.Server}}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

**Wrong:**

```elixir
defmodule MyApp.Inventory.Server do
  use GenServer

  alias MyApp.Inventory.State

  @impl true
  def init(opts) do
    :ets.new(:inventory_cache, [:named_table, :public, read_concurrency: true])
    {:ok, State.new(opts)}
  end

  @impl true
  def handle_call({:level, sku}, _from, %State{} = state) do
    {:reply, :ets.lookup(:inventory_cache, sku), state}
  end
end
```

**Why:** `Mix.env()` is resolved here while the module is compiled, which is what separates it from the `Mix.env()` call ADR-011 Rule 4 rejects inside `start/2`, where a release has no `Mix` to call. Be exact about why, because the usual shorthand has it backwards: being a macro is what makes compile-time resolution possible, not what performs it. `use` receives its options as unevaluated AST, and the value is fixed during compilation only because the expansion puts it in compile-time position. A macro that injected the same expression into a generated function body instead would call `Mix.env()` at runtime and fail in exactly the way Rule 4 of ADR-011 describes. `:named_table` puts `:inventory_cache` in a namespace of table names that is VM-wide, not process-local. A second server started by a parallel test raises `ArgumentError` from `:ets.new/2` inside `init/1`, so the two tests cannot run at once; and a test that instead reuses the application-started server reads rows a different test wrote, because the table's lifetime is the owning process's, not the test's. Avoiding concurrent name collisions costs `async: false`, but that still does not reset shared rows between sequential tests; recovering per-test state also requires explicit reset/recreation or, preferably, the sandbox or per-test resource shown here. The table is also unswappable: `:ets.lookup/2` in the callback body pins the storage backend. In the Correct version, `elixir_cache` (or a comparable adapter-pattern library) exposes one cache API across backends, and under `sandbox?: true` the `Cache.Sandbox` adapter resolves the caller through `Cache.SandboxRegistry` to an Agent registered for that test process, so concurrent tests use disjoint state through the same module name. Parameterizing the ETS table name via opts fixes the name collision but leaves cache semantics welded to raw `:ets` calls. Storage whose contract is not a cache stays behind its own injected boundary instead.

#### Rule 5: Inject internal collaborators via opts; reserve Mox for collaborators the test cannot start

Mox is for collaborators a test cannot start in-process: an HTTP API on another host or a third-party SDK holding a remote session. Every collaborator whose real implementation the test can start (caches, task supervisors, registries, mailers backed by your own modules) is injected via opts per Rule 3 and exercised for real. A clock is injected the same way and tested with a deterministic implementation such as `FrozenClock`; it does not require Mox.

**Correct:**

```elixir
# the server reads its cache module out of state, per Rule 3:
@impl true
def init(opts), do: {:ok, State.new(opts)}

@impl true
def handle_call({:level, sku}, _from, %State{deps: %Deps{cache: cache}} = state) do
  {:reply, cache.get(sku), state}
end

# test_helper.exs, which starts the sandbox registry once:
Cache.SandboxRegistry.start_link()
ExUnit.start()

# register this test process with its isolated cache in every setup:
setup do
  Cache.SandboxRegistry.start(MyApp.Inventory.Cache)
  opts = %{name: nil, cache: MyApp.Inventory.Cache}
  server = start_supervised!({MyApp.Inventory.Server, opts})
  {:ok, server: server}
end
```

**Wrong:**

```elixir
defmodule MyApp.Inventory.CacheBehaviour do
  @callback get(String.t()) :: ErrorMessage.t_res(term())
end

defmodule MyApp.Inventory.Server do
  use GenServer

  alias MyApp.Inventory.State

  @impl true
  def handle_call({:level, sku}, _from, %State{} = state) do
    cache = Application.get_env(:my_app, :cache, MyApp.Inventory.Cache)
    {:reply, cache.get(sku), state}
  end
end

# test_helper.exs:
Mox.defmock(MyApp.Inventory.MockCache, for: MyApp.Inventory.CacheBehaviour)
Application.put_env(:my_app, :cache, MyApp.Inventory.MockCache)

# in every test:
expect(MyApp.Inventory.MockCache, :get, fn _sku -> {:ok, 5} end)
```

**Why:** Under `async: true` Mox runs in private mode, where an expectation is owned by the process that declared it and every call is resolved by looking the caller up in Mox's ownership registry. The server started by `start_supervised!` is a different process, so the mock call inside `handle_call/3` raises `Mox.UnexpectedCallError` until the test adds `Mox.allow(MyApp.Inventory.MockCache, self(), server_pid)` for every mock and every server it starts, and the documented escape, `set_mox_global/1`, raises when the case is `async: true`. The second seam fails the same way for a different reason: `Application.get_env/3` reads one VM-wide store, so `put_env` in `test_helper.exs` sets the cache module for every process on the node and no file can choose a different one while others are running. Beyond isolation, the two versions test different things. A stubbed `{:ok, 5}` asserts what the test already decided; the sandbox exercises the real cache-facing path while giving each test isolated Agent-backed state. It does not prove the production adapter's TTL or concurrency behavior, because the shown sandbox adapter's `put` ignores TTL, so those adapter guarantees need their own boundary tests.

## Consequences

- Every GenServer takes a configurable name, is testable in isolation, and fails fast on bad opts before it accepts traffic.
- Opts are maps everywhere they appear: callers, `start_link`, `init`, and the state constructor. Pattern matching is the default tool for accessing them.
- Validated opts become state exactly once, through a State module constructor, so a test builds the state a supervisor would have built with no process running.
- Opts injection appears where a collaborator is substitutable. Storage whose contract is a cache uses a cache abstraction with a sandbox adapter; other purpose-built stores retain their own injected boundary. Pure-coordination GenServers need neither and stay simple.
- Mox appears only at collaborators the test cannot start, such as HTTP APIs and third-party SDKs. Internal collaborators and deterministic clocks are opts-injected and run for real.
- Tests run `async: true` by default. Unregistered per-test PIDs with per-test collaborators are the norm; reference-bearing `:via` names are reserved for tests of registration itself.
