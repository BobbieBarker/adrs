# Elixir OTP / GenServer - ADRs

ADRs covering OTP, GenServer, supervision, BEAM scheduling, and stateful-process testing.

Source: https://github.com/BobbieBarker/adrs

---
type: adr
id: 1
title: Reach for Simpler Primitives Before GenServer
status: accepted
date: 2026-04-17
tags: [elixir, otp, genserver, concurrency, architecture]
description: GenServer serializes callers through a single mailbox. Use it only when that property is required. Default to plain modules, Agent, Task, Registry, or ETS.
---

# ADR-001: Reach for Simpler Primitives Before GenServer

## Context

GenServer is frequently reached for as a default for any stateful or service-shaped behavior. Most of those uses do not require the mailbox serialization that GenServer exists to provide. Reaching for it when a simpler primitive fits creates a single-point bottleneck, introduces a process lifecycle to reason about, and makes the code harder to test.

Simpler OTP primitives (plain modules, `Agent`, `Task`, `Registry`, and ETS) cover most cases where engineers write GenServers.

## Decision

Work the ladder. Use the first primitive that fits.

### Rule 1: Plain module for pure functions

If the behavior holds no state and coordinates nothing, write a module.

**Correct:**

```elixir
defmodule MyApp.Pricing do
  def calculate_total(items, discount_code) do
    items
    |> Enum.map(&item_total/1)
    |> Enum.sum()
    |> apply_discount(discount_code)
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Pricing do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def calculate_total(items, code), do: GenServer.call(__MODULE__, {:calc, items, code})

  def init(_), do: {:ok, nil}

  def handle_call({:calc, items, code}, _from, state) do
    total = items |> Enum.map(&item_total/1) |> Enum.sum() |> apply_discount(code)
    {:reply, total, state}
  end
end
```

**Why:** The GenServer version holds no state and adds mailbox serialization to a computation that does not require it. A pure module has no lifecycle, no supervisor relationship, and no mailbox. Calls do not queue behind unrelated traffic.

### Rule 2: Agent for simple shared state

If the operations reduce to reading or replacing a value, use `Agent`.

**Correct:**

```elixir
defmodule MyApp.FeatureFlags do
  def start_link(initial),
    do: Agent.start_link(fn -> initial end, name: __MODULE__)

  def enabled?(flag),
    do: Agent.get(__MODULE__, &Map.get(&1, flag, false))

  def set(flag, value),
    do: Agent.update(__MODULE__, &Map.put(&1, flag, value))
end
```

**Wrong:**

```elixir
defmodule MyApp.FeatureFlags do
  use GenServer

  def start_link(initial), do: GenServer.start_link(__MODULE__, initial, name: __MODULE__)
  def enabled?(flag), do: GenServer.call(__MODULE__, {:enabled?, flag})
  def set(flag, value), do: GenServer.cast(__MODULE__, {:set, flag, value})

  def init(initial), do: {:ok, initial}

  def handle_call({:enabled?, flag}, _from, state),
    do: {:reply, Map.get(state, flag, false), state}

  def handle_cast({:set, flag, value}, state),
    do: {:noreply, Map.put(state, flag, value)}
end
```

**Why:** `Agent` is a GenServer with a narrower API for the get/update case. It communicates that no message-handling complexity exists. Upgrade to GenServer when timers, `handle_info`, or custom dispatch are needed.

### Rule 3: Task or Task.Supervisor for concurrent work

If the process lifetime matches the lifetime of a unit of work, use `Task`. For supervised concurrency and cancellation, use `Task.Supervisor`.

**Correct:**

```elixir
def send_welcome_emails(users) do
  MyApp.TaskSupervisor
  |> Task.Supervisor.async_stream_nolink(
    users,
    &Mailer.send_welcome/1,
    max_concurrency: 10
  )
  |> Enum.to_list()
end
```

**Wrong:**

```elixir
defmodule MyApp.EmailSender do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def send_welcome_emails(users), do: GenServer.cast(__MODULE__, {:send_all, users})

  def init(_), do: {:ok, []}

  def handle_cast({:send_all, users}, state) do
    Enum.each(users, &Mailer.send_welcome/1)
    {:noreply, state}
  end
end
```

**Why:** `Task.Supervisor` provides concurrency limits, supervision, and per-task lifecycle. The GenServer version serializes the batch through one process (no concurrency), couples the caller to the worker, and has no built-in backpressure.

### Rule 4: Registry for named process lookup

If the purpose of the server is to map keys to processes, use `Registry`.

**Correct:**

```elixir
# Supervision tree:
{Registry, keys: :unique, name: MyApp.SessionRegistry}

# Registration via :via tuple at start time:
def start_session(session_id, opts) do
  name = {:via, Registry, {MyApp.SessionRegistry, session_id}}
  MyApp.Session.start_link(Map.put(opts, :name, name))
end

def lookup(session_id) do
  case Registry.lookup(MyApp.SessionRegistry, session_id) do
    [{pid, _meta}] -> {:ok, pid}
    [] -> {:error, :not_found}
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.SessionManager do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def lookup(id), do: GenServer.call(__MODULE__, {:lookup, id})
  def register(id, pid), do: GenServer.call(__MODULE__, {:register, id, pid})

  def init(state), do: {:ok, state}

  def handle_call({:lookup, id}, _from, state),
    do: {:reply, Map.get(state, id), state}

  def handle_call({:register, id, pid}, _from, state),
    do: {:reply, :ok, Map.put(state, id, pid)}
end
```

**Why:** `Registry` uses per-shard ETS for concurrent-read lookup, supports `:via` tuples so processes register themselves in their own child spec, and monitors registered processes to clean up entries automatically. The GenServer version serializes every lookup through one mailbox and must implement monitoring by hand.

### Rule 5: ETS for shared, concurrent-read state

If multiple processes read the same state concurrently and writes are rare or can be coordinated, use ETS with an owning process for lifecycle.

**Correct:**

```elixir
defmodule MyApp.FlagStore do
  use GenServer

  @table :feature_flags

  def start_link(initial),
    do: GenServer.start_link(__MODULE__, initial, name: __MODULE__)

  def enabled?(flag),
    do: :ets.lookup_element(@table, flag, 2, false)

  def set(flag, value),
    do: GenServer.call(__MODULE__, {:set, flag, value})

  def init(initial) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    Enum.each(initial, fn {k, v} -> :ets.insert(@table, {k, v}) end)
    {:ok, nil}
  end

  def handle_call({:set, flag, value}, _from, state) do
    :ets.insert(@table, {flag, value})
    {:reply, :ok, state}
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.FlagStore do
  use GenServer

  def start_link(initial), do: GenServer.start_link(__MODULE__, initial, name: __MODULE__)
  def enabled?(flag), do: GenServer.call(__MODULE__, {:enabled?, flag})
  def set(flag, value), do: GenServer.call(__MODULE__, {:set, flag, value})

  def init(initial), do: {:ok, initial}

  def handle_call({:enabled?, flag}, _from, state),
    do: {:reply, Map.get(state, flag, false), state}

  def handle_call({:set, flag, value}, _from, state),
    do: {:reply, :ok, Map.put(state, flag, value)}
end
```

**Why:** Reads in the ETS version bypass the owning process and scale with concurrent readers. In the map-in-state version, every read queues behind every write and every unrelated message. The owning process exists to manage table lifecycle and serialize writes; it is not on the read path.

### When a GenServer IS the right answer

Use GenServer when one or more of the following applies:

- Serialized access to mutable state with multi-field invariants that ETS atomic operations cannot preserve.
- Serialized access to a scarce resource (a TCP connection, a file handle, a rate-limited external API).
- Long-lived coordination behavior combining calls, casts, `handle_info` messages, timers, and monitor events in a non-trivial way.

If the reason does not fall into one of the above, use a simpler primitive.

## Consequences

- Most code previously written as GenServers becomes modules, Agents, Tasks, Registries, or ETS-backed code.
- Pure logic is testable in isolation without process setup.
- Operational surface area shrinks: fewer processes, fewer supervision decisions, fewer mailbox-related failure modes.
- The GenServers that remain are load-bearing, and their presence signals genuine need.
- Engineers must be fluent in the full primitive ladder (module, Agent, Task, Registry, ETS, GenServer) rather than GenServer alone.


***

---
type: adr
id: 2
title: Separate GenServer Business Logic From Server Mechanics
status: accepted
date: 2026-04-17
tags: [elixir, otp, genserver, architecture, testing]
description: "Split each GenServer into three modules across three files. The API module is the domain boundary, callers depend only on it. The Server module holds GenServer callbacks. The Impl module holds functions over explicit state with no GenServer awareness."
---

# ADR-002: Separate GenServer Business Logic From Server Mechanics

## Context

GenServers are frequently written as a single module that combines the public API, the GenServer callbacks, and the business logic. This couples three concerns that change independently:

- The public API (what callers invoke)
- The server mechanics (message dispatch, callback signatures, return tuples)
- The business logic (state transformations, rules, computation)

When these concerns are entangled, business logic can only be tested by starting a process; every change to server mechanics risks breaking logic, and moving logic from a server to a library (or the reverse) requires rewriting everything. Callers are tightly coupled to the implementation choice: any change to that choice ripples out to every call site.

The fix is a three-module split across three files. The API module is the boundary of the domain, the only module callers depend on. The Server module contains only GenServer callbacks. The Impl module contains functions that operate on explicit state and have no GenServer awareness. The point is loose coupling: callers depend on a stable interface, and the decision to implement the domain as a GenServer (or to replace it with something else later) is contained within the boundary and does not propagate to call sites.

## Decision

Split every GenServer into three modules.

### Rule 1: Three modules per GenServer, each in its own file

The file layout mirrors the module path. The domain lives in a directory; the API module sits next to that directory as the boundary callers depend on.

```
lib/my_app/
├── inventory.ex            # MyApp.Inventory             (API, boundary of the domain)
└── inventory/
    ├── server.ex           # MyApp.Inventory.Server      (GenServer callbacks)
    └── impl.ex             # MyApp.Inventory.Impl        (functions over explicit state, no GenServer awareness)
```

- **API module** (`MyApp.Inventory`, in `lib/my_app/inventory.ex`): the public entry point callers invoke. A thin boundary that hides whether the work is done by a GenServer, an Agent, plain functions, or something else.
- **Server module** (`MyApp.Inventory.Server`, in `lib/my_app/inventory/server.ex`): GenServer callbacks only. No business logic.
- **Impl module** (`MyApp.Inventory.Impl`, in `lib/my_app/inventory/impl.ex`): functions that take explicit state and return `{result, new_state}` (or equivalent). No GenServer awareness.

**Correct:**

```elixir
# lib/my_app/inventory.ex
defmodule MyApp.Inventory do
  alias MyApp.Inventory.Server

  def start_link(opts \\ %{}), do: Server.start_link(opts)

  def reserve(sku, qty, name \\ Server),
    do: GenServer.call(name, {:reserve, sku, qty})
end
```

```elixir
# lib/my_app/inventory/server.ex
defmodule MyApp.Inventory.Server do
  use GenServer
  alias MyApp.Inventory.Impl

  def start_link(opts \\ %{}) do
    opts = Map.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: opts.name)
  end

  def init(opts), do: {:ok, Impl.initial_state(opts)}

  def handle_call({:reserve, sku, qty}, _from, state) do
    {result, new_state} = Impl.reserve(state, sku, qty)
    {:reply, result, new_state}
  end
end
```

```elixir
# lib/my_app/inventory/impl.ex
defmodule MyApp.Inventory.Impl do
  def initial_state(opts),
    do: %{stock: Map.get(opts, :stock, %{}), reservations: %{}}

  def reserve(state, sku, qty) do
    case Map.get(state.stock, sku) do
      n when is_integer(n) and n >= qty ->
        new_state = %{
          state
          | stock: Map.update!(state.stock, sku, &(&1 - qty)),
            reservations: Map.update(state.reservations, sku, qty, &(&1 + qty))
        }
        {:ok, new_state}

      _ ->
        {{:error, :insufficient_stock}, state}
    end
  end
end
```

**Wrong:**

```elixir
# lib/my_app/inventory.ex - public API, callbacks, and logic all jammed into one file
defmodule MyApp.Inventory do
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def reserve(sku, qty), do: GenServer.call(__MODULE__, {:reserve, sku, qty})

  def init(opts), do: {:ok, %{stock: Map.get(opts, :stock, %{}), reservations: %{}}}

  def handle_call({:reserve, sku, qty}, _from, state) do
    case Map.get(state.stock, sku) do
      n when is_integer(n) and n >= qty ->
        new_state = %{
          state
          | stock: Map.update!(state.stock, sku, &(&1 - qty)),
            reservations: Map.update(state.reservations, sku, qty, &(&1 + qty))
        }
        {:reply, :ok, new_state}

      _ ->
        {:reply, {:error, :insufficient_stock}, state}
    end
  end
end
```

**Why:** The split is structural, not just lexical. Three modules in three files means callers `alias MyApp.Inventory` and depend on the boundary only; they never see `Server` or `Impl`. `Impl` functions are testable with explicit state and no process. Server callbacks become mechanical enough that changes to them rarely affect logic. The API module absorbs the choice of whether a GenServer exists at all: if the domain evolves into something other than a GenServer (a plain library, an Agent, a Task pool, a process per entity behind a Registry), `lib/my_app/inventory.ex` is the only file callers indirectly depend on, and the API signatures stay identical. In the single-module, single-file version, every caller imports the same module that does the work, every logic test starts a process, and any restructuring of state or dispatch touches logic.

### Rule 2: Impl has no GenServer awareness

`Impl` takes an explicit state and returns a result paired with a new state. It does not call `GenServer.reply`, does not return GenServer callback tuples (`{:reply, _, _}`, `{:noreply, _}`), and does not pattern match on `from`. Beyond that, it is ordinary Elixir: it can emit telemetry, read or write ETS tables, and call other modules (including those fronted by an Agent, Registry, or GenServer) as needed.

**Correct:**

```elixir
# lib/my_app/inventory/impl.ex
defmodule MyApp.Inventory.Impl do
  def reserve(state, sku, qty) do
    case Map.get(state.stock, sku) do
      n when is_integer(n) and n >= qty ->
        :telemetry.execute([:inventory, :reserved], %{qty: qty}, %{sku: sku})
        {:ok, deduct_stock(state, sku, qty)}

      _ ->
        {{:error, :insufficient_stock}, state}
    end
  end

  defp deduct_stock(state, sku, qty) do
    %{state | stock: Map.update!(state.stock, sku, &(&1 - qty))}
  end
end
```

**Wrong:**

```elixir
# lib/my_app/inventory/impl.ex
defmodule MyApp.Inventory.Impl do
  # Returns GenServer callback tuples and accepts `from` -
  # couples Impl to the callback it is invoked from.
  def reserve(state, sku, qty, from) do
    case Map.get(state.stock, sku) do
      n when is_integer(n) and n >= qty ->
        GenServer.reply(from, :ok)
        {:noreply, deduct_stock(state, sku, qty)}

      _ ->
        {:reply, {:error, :insufficient_stock}, state}
    end
  end
end
```

**Why:** What makes `Impl` testable is that it operates on plain state and speaks in the vocabulary of functions, not GenServer callbacks. Once `Impl` returns `{:reply, _, _}` or accepts a `from` tuple, the Server and Impl collapse into each other, and tests can only exercise Impl through a live process.

Things that are NOT required for Impl to be testable, despite common confusion: the absence of telemetry, the absence of calls to other (possibly named) processes, or the absence of timers. A timer is scheduled with `Process.send_after(self(), _, _)` inside `Impl` is a coupling choice to weigh on a case-by-case basis (`self()` points to the test process when called from a test), but it is not categorically wrong.

### Rule 3: Server callbacks are thin dispatchers

Each callback calls one `Impl` function and wraps the result in the appropriate GenServer return tuple. No business logic in callback bodies.

**Correct:**

```elixir
# lib/my_app/inventory/server.ex
def handle_call({:reserve, sku, qty}, _from, state) do
  {result, new_state} = Impl.reserve(state, sku, qty)
  {:reply, result, new_state}
end

def handle_info(:cleanup_expired_reservations, state) do
  new_state = Impl.expire_reservations(state, DateTime.utc_now())
  {:noreply, new_state}
end
```

**Wrong:**

```elixir
# lib/my_app/inventory/server.ex
def handle_call({:reserve, sku, qty}, _from, state) do
  case Map.get(state.stock, sku) do
    n when is_integer(n) and n >= qty ->
      new_state = %{state | stock: Map.update!(state.stock, sku, &(&1 - qty))}
      {:reply, :ok, new_state}

    _ ->
      {:reply, {:error, :insufficient_stock}, state}
  end
end
```

**Why:** Callback-embedded logic cannot be tested without starting the process, and it accumulates. Thin callbacks make the Server module boring to review (one pattern per callback shape) and keep `Impl` the single place reviewers look for logic changes.

### Rule 4: Callers depend on the API module, not the Server

The API module is the boundary of the domain. Callers' alias and call it. `MyApp.Inventory.Server` and `MyApp.Inventory.Impl` is implementation detail, addressable only from inside the domain.

**Correct:**

```elixir
# anywhere in lib/my_app/...
alias MyApp.Inventory
Inventory.reserve("sku-1", 3)
```

**Wrong:**

```elixir
# call site reaching past the boundary into the Server
GenServer.call(MyApp.Inventory.Server, {:reserve, "sku-1", 3})
```

**Why:** Loose coupling is what makes the implementation choice reversible. When every caller depends on `MyApp.Inventory`. The question of whether the domain is a GenServer, an Agent, a Task pool, a process per entity behind a Registry, or just a plain library lies entirely within `lib/my_app/inventory/`. Swapping implementations does not propagate to call sites. If callers reach through to `GenServer.call(MyApp.Inventory.Server, ...)` directly, the server is no longer an implementation detail; it is part of the public contract, and removing it means touching every call site in the codebase.

## Consequences

- Business-logic tests run directly against `Impl` with explicit state. No `start_supervised!`, no async ceremony.
- Process-level tests cover only the dispatch, startup, and handle_info paths.
- Moving logic between a GenServer and a plain library is a single-file change at the API layer.
- The question from ADR-001 ("Should this be a GenServer at all?") is cheap to revisit because the logic does not move.


***

---
type: adr
id: 3
title: Keep GenServer State Small; Push Storage Out of Process
status: accepted
date: 2026-04-18
tags: [elixir, otp, genserver, performance, state, gc]
description: GC pauses scale with a process's live heap. A GenServer should hold coordination and identity state, not bulk data. Bulk data belongs in ETS, Postgres, or a cache abstraction.
---

# ADR-003: Keep GenServer State Small; Push Storage Out of Process

## Context

BEAM uses per-process heaps with a generational semi-space collector. GC pauses scale with the live heap size of the process being collected. A GenServer holding bulk data (a large map, a growing cache, accumulated events) pays visible GC pauses on that process only. The blame shows up as tail-latency on one endpoint, not as a whole-system slowdown, which makes it hard to attribute.

A GenServer's state should represent what the process coordinates, not what the process stores. Storage belongs somewhere that can be read concurrently by many processes (ETS, Postgres, Redis, a purpose-built cache) while the server's state holds only the identity and in-flight coordination information needed to do its job.

## Decision

### Rule 1: Push bulk data out of the process

If the state contains data that grows with usage (entries accumulated over time, caches, batches, event history), that data lives outside the process.

**Correct:**

```elixir
defmodule MyApp.Inventory.Impl do
  def initial_state(%{name: name}) do
    %{
      name: name,
      pending_reservations: %{}
    }
  end

  def reserve(state, sku, qty) do
    case MyApp.Inventory.Cache.get(sku) do
      n when is_integer(n) and n >= qty ->
        :ok = MyApp.Inventory.Cache.decrement(sku, qty)
        reservation_id = System.unique_integer([:positive])
        new_state = put_in(state, [:pending_reservations, reservation_id], {sku, qty})
        {{:ok, reservation_id}, new_state}

      _ ->
        {{:error, :insufficient_stock}, state}
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Inventory.Impl do
  def initial_state(%{name: name}) do
    %{
      name: name,
      stock: load_all_stock_from_db(),
      pending_reservations: %{},
      completed_reservations: []
    }
  end

  def reserve(state, sku, qty) do
    case Map.get(state.stock, sku) do
      n when is_integer(n) and n >= qty ->
        {:ok, record_reservation(state, sku, qty)}

      _ ->
        {{:error, :insufficient_stock}, state}
    end
  end
end
```

**Why:** In the wrong version, the entire stock map and the full history of reservations live on the server's heap. Every GC cycle scans and possibly copies all of it, and pauses grow with the data. Concurrent callers wait longer for their `call` to be served because reads queue behind whatever else is in the mailbox. In the correct version, stock is in a shared store that callers can read without going through the server mailbox, and state holds only the reservations currently being coordinated.

### Rule 2: Separate working state from configuration state

The state has two parts that behave differently. Configuration is what the server was booted with, converted once at init. The working state is what changes as the server runs. Model them as distinct fields of the state struct (or as distinct modules) so the shape is obvious to a reviewer.

**Correct:**

```elixir
defmodule MyApp.RateLimiter.Config do
  defstruct [:window_ms, :max_requests, :buckets_per_key]

  def from(opts) do
    %__MODULE__{
      window_ms: duration_to_ms(Map.get(opts, :window, "10s")),
      max_requests: Map.get(opts, :max_requests, 100),
      buckets_per_key: Map.get(opts, :buckets, 10)
    }
  end
end

defmodule MyApp.RateLimiter.Impl do
  alias MyApp.RateLimiter.Config

  def initial_state(opts) do
    %{
      config: Config.from(opts),
      in_flight: %{}
    }
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.RateLimiter.Impl do
  def initial_state(opts) do
    %{
      window: Map.get(opts, :window, "10s"),
      max_requests: Map.get(opts, :max_requests, 100),
      buckets: Map.get(opts, :buckets, 10),
      in_flight: %{}
    }
  end
end
```

**Why:** The correct version communicates shape at a glance. `config` is stable and read-heavy; `in_flight` is what mutates. The wrong version forces a reviewer to scan every callback to learn which fields change, and re-parses `"10s"` into an integer on every request instead of converting once at init. Establishing this separation at init time pays the conversion cost once and keeps hot-path callbacks cheap.

### Legitimate exceptions

Some state genuinely belongs in the process:

- State that must be strictly ordered through the server's mailbox and would lose those ordering guarantees if moved to ETS with concurrent writers.
- Derived state whose recomputation from external storage is more expensive than the GC cost of carrying it.
- State that is genuinely small: a flag, a counter, a struct with a handful of fields.

The rule is "default to off-process storage; justify in-process state when you keep it." The burden of proof is on keeping data in.

## Consequences

- Most GenServer state shrinks to coordination metadata. The process no longer dominates its own GC cost.
- Reads of bulk data happen against a shared store (ETS, Postgres, cache) with concurrent-read semantics and do not queue behind unrelated server traffic.
- State structure communicates intent: configuration is stable and read-heavy, working state is mutable and churny.
- Bulk-data performance tuning (cache policy, read concurrency, eviction) happens in the storage layer, not inside the server.


***

---
type: adr
id: 4
title: Never Block the GenServer Processing Loop
status: accepted
date: 2026-04-22
tags: [elixir, otp, genserver, performance, callbacks]
description: GenServer callbacks handle one message at a time. Blocking I/O or unbounded computation in a callback stalls every other caller. Raising the call timeout papers over the problem instead of fixing it.
---

# ADR-004: Never Block the GenServer Processing Loop

## Context

A GenServer handles one message at a time. Every callback body runs to completion before the next message is pulled from the mailbox. Blocking operations inside a callback (HTTP calls, synchronous queries to a slow database, file reads of unknown size, any computation whose tail can be much longer than its median) stall every other caller.

The default `GenServer.call/2` timeout is 5000 ms. Raising the timeout or passing `:infinity` does not make the server faster. It makes failures louder and harder to bound. A stuck upstream becomes a stuck caller.

When this rule is violated at scale, the consequences cascade. The mailbox of a slow server grows with every queued call. Messages to that process default to living on the process heap, so per-process GC scans them and pauses scale with mailbox size. `process_info` calls against long mailboxes have known degradations (OTP issues #5481 and #6494), so observability slows exactly when an operator needs it most.

Before memory exhaustion, the choke point is the bloated process itself. Selective receive against a long mailbox is, per the Erlang Efficiency Guide, "very expensive for processes with long message queues." The process consumes its reductions by walking its own mailbox instead of doing useful work, and is scheduled out before it can make meaningful progress. Aggregate throughput across the node scales proportionally: the system stays nominally alive while latency rises and useful work per CPU-second drops. This is often a worse outcome than an outright crash, because supervisors cannot restart what is still running. The node holds its connections, refuses new work, and degrades silently until something external intervenes.

If growth continues, the BEAM eventually hits a memory ceiling (host OOM-kill or allocator failure), and the node dies. There is no graceful shutdown from a memory failure, no `terminate/2`, no supervisor restart of the dead process. A single slow callback in production is bounded only by the host's memory.

## Decision

### Rule 1: No blocking I/O or unbounded computation in callbacks

Callbacks return quickly. "Quickly" means bounded and predictable, not "fast in the happy case."

**Correct:**

```elixir
def handle_call({:reserve, sku, qty}, from, state) do
  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    result = external_reserve(sku, qty)
    GenServer.reply(from, result)
  end)
  {:noreply, state}
end
```

**Wrong:**

```elixir
def handle_call({:reserve, sku, qty}, _from, state) do
  {:ok, response} = HTTPoison.get("https://inventory.example.com/reserve/#{sku}/#{qty}")
  {:reply, parse_response(response), state}
end
```

**Why:** The wrong version stalls every message in the mailbox for the duration of the HTTP request. If the upstream service has a 30-second tail, every caller of the server sees a 30-second tail, and the 5000 ms call timeout starts raising exits across the codebase. The correct version removes the slow work from the callback (the mechanisms are covered in ADR-005), keeps the loop free, and still returns the answer to the original caller.

### Rule 2: Do not raise the call timeout to paper over slow callbacks

If callers are timing out on a GenServer, the fix is to speed up the callback, not to increase the caller's patience.

**Correct:**

```elixir
def fetch_price(sku), do: GenServer.call(MyApp.Pricing.Server, {:fetch, sku})
```

**Wrong:**

```elixir
def fetch_price(sku), do: GenServer.call(MyApp.Pricing.Server, {:fetch, sku}, 60_000)
```

**Why:** Raising the timeout hides the underlying problem (a slow callback) and extends the blast radius of a stall. `:infinity` is worse because a stuck upstream becomes a permanently stuck caller. If 5000 ms is routinely not enough, the callback is doing work it should not be doing inline.

## Consequences

- Callbacks stay bounded. Mailbox depth is driven by request rate, not by tail latency inside the server.
- Timeouts at call sites stay at the default. When they do fire, they point to a real problem rather than a config dial.
- Slow work moves to tasks, continues, or asynchronous reply patterns. See ADR-005.


***

---
type: adr
id: 5
title: Get Slow Work Off the Processing Loop
status: accepted
date: 2026-04-22
tags: [elixir, otp, genserver, handle_continue, task, async]
description: Three OTP mechanisms for moving slow work out of a GenServer callback. handle_continue for post-init deferred work, Task.Supervisor for fire-and-forget, GenServer.reply for async responses.
---

# ADR-005: Get Slow Work Off the Processing Loop

## Context

ADR-004 establishes that callbacks must not block the processing loop. This ADR covers the three mechanisms OTP provides for doing the slow work outside the callback body.

- `handle_continue/2` for deferred work that must run before the first client message.
- `Task.Supervisor` for fire-and-forget work whose result is not needed in line.
- `GenServer.reply/2` for work that must return to the original caller but cannot be done in-line.

Which to reach for depends on where the slow work sits relative to the callback lifecycle.

## Decision

### Rule 1: Use handle_continue for post-init work

If expensive setup work logically belongs in init/1, move it to handle_continue/2 so init/1 returns quickly.

**Correct:**

```elixir
def init(opts) do
  {:ok, Impl.initial_state(opts), {:continue, :load_catalog}}
end

def handle_continue(:load_catalog, state) do
  {:ok, catalog} = load_catalog_from_disk(state.config.catalog_path)
  {:noreply, %{state | catalog: catalog}}
end
```

**Wrong:**

```elixir
def init(opts) do
  state = Impl.initial_state(opts)
  {:ok, catalog} = load_catalog_from_disk(state.config.catalog_path)
  {:ok, %{state | catalog: catalog}}
end
```

**Why:** `init/1` blocks the supervisor's `start_link` call until it returns. Every dependent child waits. `handle_continue/2` lets `init/1` return immediately; the deferred work runs as part of entering the loop, before any other message is processed. The supervisor unblocks, and siblings start.

### Rule 2: Use Task.Supervisor for fire-and-forget work

For work the server kicks off but does not need to synchronize with, use `Task.Supervisor.start_child/2`. Use `async_nolink/3` when a result is needed later via `handle_info`.

**Correct:**

```elixir
def handle_cast({:emit_audit_event, event}, state) do
  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    AuditLog.send(event)
  end)
  {:noreply, state}
end
```

**Wrong:**

```elixir
def handle_cast({:emit_audit_event, event}, state) do
  spawn(fn -> AuditLog.send(event) end)
  {:noreply, state}
end
```

**Why:** `spawn/1` gives no supervision, no structured error reporting, and no way to bound concurrency. A crash in the child disappears silently. `spawn_link/1` is worse: a crash in the child takes the server down with it. `Task.Supervisor.start_child/2` supervises the task, reports crashes through the standard error logger, and does not link the failure to the server. `Task.Supervisor.async_nolink/3` is the variant to use when the caller needs the task's result: the task's return value arrives as a `handle_info({ref, result}, state)` message, and a separate `:DOWN` message follows when the task exits.

### Rule 3: Use GenServer.reply for async responses

If the caller needs the result but the work cannot run in-line, return `{:noreply, state}` from `handle_call`, kick the work to a task, and call `GenServer.reply/2` from the task when the result is ready.

**Correct:**

```elixir
def handle_call({:reconcile, account_id}, from, state) do
  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    result = do_reconciliation(account_id)
    GenServer.reply(from, result)
  end)
  {:noreply, state}
end
```

**Wrong:**

```elixir
def handle_call({:reconcile, account_id}, _from, state) do
  result = do_reconciliation(account_id)
  {:reply, result, state}
end
```

**Why:** `GenServer.reply/2` accepts the `from` tuple and can be called from any process. The original caller is still blocked on its `call` and does not care which process answers. Returning `{:noreply, state}` frees the server's loop to handle the next message while the work continues. If cancellation matters, stash the task reference in state and monitor it so the server can clean up when the caller exits.

## Consequences

- Callbacks stay bounded regardless of how slow the underlying work is.
- Expensive init runs without blocking the supervisor tree.
- Fire-and-forget work is supervised, not lost.
- The server owns sequencing; the task owns the slow thing. Neither leaks into the other.


***

---
type: adr
id: 6
title: Use GenStage for Producer-Consumer Pipelines
status: accepted
date: 2026-04-29
tags: [elixir, otp, genserver, backpressure, genstage, broadway, flow]
description: When one process produces work faster than another consumes it, use GenStage, Flow, or Broadway. Do not build pipelines on naked cast.
---

# ADR-006: Use GenStage for Producer-Consumer Pipelines

## Context

When one process generates work, and another handles it, and the producer can outpace the consumer, the consumer's mailbox grows unboundedly. The mailbox is a process resource: as it grows, GC pauses scale with it, observability calls like `process_info` degrade against it (see OTP issues #5481 and #6494), and the node eventually runs out of memory.

GenServer's `cast` provides no flow control. A producer firing a `cast` at a slower consumer has no way to know it should slow down. `GenStage` is the OTP primitive built specifically for this problem; `Flow` and `Broadway` are higher-level libraries built on top of it. They implement demand-driven flow control: the consumer asks for N events, and the producer sends exactly N events. The mailbox cannot grow beyond demand in flight.

## Decision

### Rule 1: Use GenStage / Flow / Broadway for producer-consumer pipelines

If the problem has the shape "process A produces work, process B handles it, and A can outpace B," do not build it with a `cast` between two GenServers. Reach for GenStage, or one of the libraries built on it.

**Correct:**

```elixir
defmodule MyApp.Ingest.Producer do
  use GenStage

  def start_link(opts),
    do: GenStage.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_), do: {:producer, %{}}

  def handle_demand(demand, state) do
    events = pull_events(demand)
    {:noreply, events, state}
  end
end

defmodule MyApp.Ingest.Consumer do
  use GenStage

  def start_link(opts),
    do: GenStage.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_) do
    {:consumer, %{}, subscribe_to: [{MyApp.Ingest.Producer, max_demand: 10}]}
  end

  def handle_events(events, _from, state) do
    Enum.each(events, &process_event/1)
    {:noreply, [], state}
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Ingest do
  def publish(event), do: GenServer.cast(MyApp.Ingest.Server, {:event, event})
end

defmodule MyApp.Ingest.Server do
  use GenServer

  def handle_cast({:event, event}, state) do
    # Producers fire cast; this server has no way to push back.
    # If publishers outpace processing, the mailbox grows unboundedly.
    {:noreply, Impl.ingest(state, event)}
  end
end
```

**Why:** In the wrong version, every call to `publish` succeeds immediately. The consumer has no mechanism to signal "slow down." Under sustained load, the consumer's mailbox grows without bound. GC pauses on that process scale with the mailbox, `process_info` calls degrade, and the node eventually runs out of memory.

In the correct version, the consumer subscribes with `max_demand: 10`, telling the producer, "I can handle up to ten events." The producer sends ten and waits. When the consumer finishes, it asks for more. The mailbox cannot grow beyond demand in flight, by construction. Broadway and Flow add concurrency, batching, partitioning, and acknowledgment on top of this primitive, but the underlying flow-control mechanism is the same.

## Consequences

- Producer-consumer pipelines use GenStage, Flow, or Broadway. They do not use naked `cast` between processes.
- Mailbox growth is treated as a system signal: the response is structural back-pressure, not faster processing.
- Servers with no producer-consumer shape do not need GenStage. The rule applies when its condition applies.


***

---
type: adr
id: 7
title: Design GenServers for Test Isolation
status: accepted
date: 2026-04-29
tags: [elixir, otp, genserver, testing, dependency-injection]
description: Every GenServer accepts a configurable :name and validates its opts at start. When the server has substitutable collaborators or owns storage, inject them via opts and use a library with a sandbox adapter.
---

# ADR-007: Design GenServers for Test Isolation

## Context

A GenServer that registers itself under a fixed global atom can only exist once per VM. Every test that touches it either serializes against every other test or shares state with it. Neither supports a healthy test suite.

Test isolation begins with one universal choice: every GenServer accepts a configurable name. Beyond that, additional choices apply when the server has substitutable collaborators or owns storage. Not every GenServer does. A pure-coordination server with no external dependencies needs only the configurable name; the situational rules in this ADR apply when their conditions are met.

## Decision

Two rules apply to every GenServer. Two more apply only when their condition is met.

### Universal rules

#### Rule 1: Every GenServer accepts a configurable :name

The server's registered name is set in opts, with a sensible default for production. This is non-negotiable. Without it, tests cannot spin up isolated instances.

**Correct:**

```elixir
defmodule MyApp.Inventory.Server do
  use GenServer

  def start_link(%{name: name} = opts) do
    GenServer.start_link(__MODULE__, opts, name: name)
  end
end

# in a test:
setup do
  name = :"inventory_#{System.unique_integer([:positive])}"
  start_supervised!({MyApp.Inventory.Server, %{name: name}})
  {:ok, server: name}
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

**Why:** In the wrong version, `__MODULE__` is registered globally, and two instances cannot coexist. Every test that starts the server either blocks other tests or shares state with them. In the correct version, the name is an option provided by the caller. Production code passes a default at the supervision tree; tests pass a unique atom per test. The suite runs `async: true`.

#### Rule 2: Pass opts as maps and validate with NimbleOptions

Accept opts as a map, not a keyword list. Validate them at the start using a declarative schema. `NimbleOptions` is the standard Elixir library for this, and it's what Phoenix, Broadway, ChromicPDF, and many parts of the ecosystem use. Declare the schema as a module attribute, validate at the boundary, and let the library handle type checking, defaults, required-key enforcement, and error messages.

**Correct:**

```elixir
defmodule MyApp.Inventory.Server do
  use GenServer

  @opts_schema NimbleOptions.new!(
    name: [
      type: :any,
      required: true,
      doc: "Registered name. An atom or `:via` tuple."
    ],
    threshold: [
      type: :pos_integer,
      default: 100,
      doc: "Mailbox length above which new work is shed."
    ],
    cache: [
      type: :atom,
      default: MyApp.Inventory.Cache,
      doc: "Cache module implementing the storage adapter."
    ]
  )

  def start_link(opts) when is_map(opts) do
    opts =
      opts
      |> Keyword.new()
      |> NimbleOptions.validate!(@opts_schema)
      |> Map.new()

    GenServer.start_link(__MODULE__, opts, name: opts.name)
  end

  def init(opts), do: {:ok, Impl.initial_state(opts)}
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

  def init(opts) do
    {:ok,
     %{
       threshold: Keyword.get(opts, :threshold, 100)
       # bad or missing opt silently becomes the default; the bug surfaces in production
     }}
  end
end
```

**Why:** Validation belongs at the process boundary. `NimbleOptions` declares the contract once, with required keys, types, defaults, and documentation. The library produces precise error messages when a caller passes the wrong shape, and the schema doubles as auto-generated documentation. A server started with bad opts fails immediately at `start_link` with a typed error before it is registered or accepts traffic. Hand-rolled `validate_opts!` functions accumulate special cases and skew over time; a declarative schema does not.

Internally, opts stay as maps so they are pattern-matchable in callbacks (`def init(%{name: name, cache: cache} = opts)`) and accessed by dot syntax (`opts.name`) rather than keyword-list helpers. The boundary conversion (map in, kw list to `NimbleOptions`, map out) is a single, localized cost incurred only during `start_link`.

The tradeoff: this deviates from the keyword-list convention common at Elixir call sites (`Mod.start_link(name: :foo)` becomes `Mod.start_link(%{name: :foo})`). The benefit is that the opts are validated at the boundary and pattern-matchable everywhere internally.

### Situational rules

These apply only when the condition in their statement is met. They are NOT defaults to apply to every GenServer.

#### Rule 3: Inject substitutable collaborators via opts (only when present)

If the server calls into a collaborator that tests need to substitute (a cache, an external API client, a clock, a mailer), accept the collaborator module via opts with a sensible production default.

This rule does NOT apply to GenServers with no substitutable collaborators. A pure-coordination server that holds its own state, dispatches its own messages, and calls only into pure functions or already-isolated context modules needs no DI. Adding it as a ceremony hurts readability.

**Correct:**

```elixir
def start_link(%{name: name} = opts) do
  opts = Map.put_new(opts, :cache, MyApp.Inventory.Cache)
  GenServer.start_link(__MODULE__, opts, name: name)
end

def init(opts), do: {:ok, Impl.initial_state(opts)}

# in a test:
setup do
  start_supervised!(
    {MyApp.Inventory.Server, %{name: :test_inv, cache: StubCache}}
  )
  :ok
end
```

**Wrong:**

```elixir
def init(_) do
  {:ok, Impl.initial_state(cache: MyApp.Inventory.Cache)}
end
```

**Why:** When the cache is hardcoded, tests cannot substitute a stub without `Application.put_env` hacks or a `Mox.defmock` against a behavior the module does not declare. With the cache injected via opts, production code is unchanged, and tests pass a stub directly. Both run `async: true` against per-test instances. The reverse failure mode is also worth naming: GenServers with no real collaborators that grow opt-injected dependencies "just in case" become noisier without becoming more testable.

#### Rule 4: Delegate storage to a cache library with a sandbox adapter (only when storage is present)

If the server owns storage with TTLs, eviction, or key-scoped operations, do not hand-roll it with `:ets.new(:named_table)` inside `init/1`. Use a library that provides an adapter pattern over storage backends and a sandbox adapter for test isolation.

This rule does NOT apply to GenServers with no storage of their own. State that lives in the process struct (within the bounds set by ADR-003) is fine without ceremony.

**Correct:**

```elixir
defmodule MyApp.Inventory.Cache do
  use Cache,
    adapter: Cache.ETS,
    name: :inventory_cache,
    sandbox?: Mix.env() === :test,
    opts: []
end
```

**Wrong:**

```elixir
defmodule MyApp.Inventory.Server do
  use GenServer

  def init(_) do
    :ets.new(:inventory_cache, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  def handle_call({:get, key}, _from, state) do
    {:reply, :ets.lookup(:inventory_cache, key), state}
  end
end
```

**Why:** In the wrong version, the ETS table name is a global atom. Two tests that touch the server race on the same table. Cleanup requires either `async: false` or a `setup` block that deletes and recreates the table, both of which erode the suite. There is also no way to swap the storage backend for Redis, `:persistent_term`, or another adapter without rewriting the server. In the correct version, `elixir_cache` (or a comparable adapter pattern library) exposes a single API across multiple backends, and its Sandbox adapter provides each test with an isolated namespace via `Cache.SandboxRegistry`. The suite stays `async: true` and no test sees another test's data.

Parameterizing the ETS table name via opts (e.g., deriving it from the server name) is sometimes proposed as a lighter alternative. It is not. It fixes the test-parallelism collision but leaves the Server welded to `:ets` calls, which is the larger problem. Code that owns storage uses an adapter-pattern cache library. Anything less is incomplete.

## Consequences

- Every GenServer takes a configurable name and is testable in isolation.
- Every GenServer fails fast on bad opts, before it accepts traffic.
- Opts are maps everywhere they appear: callers, `start_link`, `init`, `Impl`. Pattern matching is the default tool for accessing them.
- Dependency injection applies only where collaborators need to be substitutable. Pure-coordination GenServers stay simple.
- Storage-owning GenServers delegate to a cache abstraction. Pure-coordination GenServers do not.
- Tests run `async: true` by default. Per-test instances with stubbed collaborators are the norm.


***

---
type: adr
id: 8
title: Graceful Shutdown Requires trap_exit and a Realistic :shutdown
status: accepted
date: 2026-04-22
tags: [elixir, otp, genserver, shutdown, supervision]
description: terminate/2 only runs in three specific cases and never on brutal kills. Trap exits in init/1 if you need cleanup on supervisor :shutdown. Set a realistic :shutdown value. Do not treat terminate/2 as durable storage.
---

# ADR-008: Graceful Shutdown Requires trap_exit and a Realistic :shutdown

## Context

`terminate/2` runs in three specific cases:

1. A callback returns `{:stop, _, _}`.
2. A callback raises.
3. The process is trapping exits and receives an exit signal it handles.

`terminate/2` does NOT run on `Process.exit(pid, :kill)`, on a supervisor's `:brutal_kill` shutdown, on VM hard shutdown, or on OS SIGKILL.

If cleanup must run during a normal supervisor-initiated shutdown (where the supervisor sends :shutdown as the default exit signal), the server must trap exits in `init/1`. Without that, the signal kills the process, and `terminate/2` never fires. Separately, the supervisor child_spec has a `:shutdown` value defaulting to 5000 ms; a `terminate/2` callback that needs longer to drain will be cut off at that boundary.

`terminate/2` is a best-effort cooperative shutdown hook, not a persistence layer.

## Decision

### Rule 1: Trap exits in init/1 if you need terminate/2 to run on normal shutdown

If the server has cleanup work (flushing a buffer, closing a connection, draining in-flight requests), it must trap exits. Without trapping, supervisor `:shutdown` kills the process before `terminate/2` is called.

**Correct:**

```elixir
def init(opts) do
  Process.flag(:trap_exit, true)
  {:ok, Impl.initial_state(opts)}
end

def terminate(_reason, state) do
  Buffer.flush(state.buffer)
  :ok
end
```

**Wrong:**

```elixir
def init(opts) do
  {:ok, Impl.initial_state(opts)}
end

def terminate(_reason, state) do
  # never runs when the supervisor sends :shutdown
  Buffer.flush(state.buffer)
end
```

**Why:** A server that does not trap exits receives `:shutdown` as an unhandled exit signal and dies before `terminate/2` executes. Any cleanup code is dead code. Trapping is not the default because it changes how the server handles exit signals in general (exits from linked processes become messages rather than terminations), so it is an explicit opt-in for servers that actually need cleanup. Servers with no cleanup work should not trap; crashing cleanly is a feature.

### Rule 2: Don't pad the :shutdown timeout

The default `:shutdown` of 5000 ms is fine for almost every server. `terminate/2` returns as soon as its work is done; the timeout only matters as an upper bound for a stuck server. Padding it to 30 seconds, 60 seconds, or `:infinity` directly inflates deploy time and time-to-recovery: every millisecond above the actual drain is paid back during rolling deploys and incident-driven restarts.

If you genuinely need a long `:shutdown` value, the structural fix is usually upstream: buffered work should not have lived in the process (ADR-003), or writes should have been durable on arrival rather than batched at exit (Rule 3 below).

**Correct:**

```elixir
defmodule MyApp.Ingest.Server do
  use GenServer
  # Default :shutdown of 5000 ms. terminate/2 returns when it's done.
end
```

**Wrong:**

```elixir
defmodule MyApp.Ingest.Server do
  use GenServer

  # Padded to 30 seconds "to be safe." Across N nodes in a rolling deploy
  # this directly inflates deploy time. During an incident it inflates
  # time-to-recovery. ":infinity" is worse: a stuck server now stalls the
  # entire supervisor tree.
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 30_000
    }
  end
end
```

**Why:** `:shutdown` is an upper bound, not a target. `terminate/2` runs to completion as quickly as it can; the timeout only fires when the server is stuck. Padded timeouts do not make shutdown safer; they make it slower exactly when a restart cannot complete normally. `:infinity` removes the supervisor's ability to recover from a stuck server entirely and is almost never the right answer.

### Rule 3: Do not treat terminate/2 as durable storage

The critical state survives across process restarts only if it exists outside the process. `terminate/2` is not that place.

**Correct:**

```elixir
def handle_call({:append, entry}, _from, state) do
  # durable write happens synchronously, before the reply
  :ok = MyApp.EventLog.append(entry)
  {:reply, :ok, state}
end

def terminate(_reason, state) do
  :ok = MyApp.EventLog.flush_metadata(state.session_id)
end
```

**Wrong:**

```elixir
def handle_call({:append, entry}, _from, state) do
  # accumulated in memory; only written on shutdown
  {:reply, :ok, %{state | buffered_entries: [entry | state.buffered_entries]}}
end

def terminate(_reason, state) do
  # brutal kill, SIGKILL, VM crash: everything in buffered_entries is lost
  :ok = MyApp.EventLog.append_all(state.buffered_entries)
end
```

**Why:** `terminate/2` is skipped by `Process.exit(pid, :kill)`, `:brutal_kill`, VM crashes, and SIGKILL. Anything that depends on it running is unreliable by construction. Durable state must be written at the moment it matters, not held in memory and flushed on the way out. `terminate/2` is still useful for cooperative cleanup (e.g., releasing a TCP connection, logging a clean shutdown, flushing soft metadata), but it is a best-effort hook, not a persistence layer.

## Consequences

- Servers that need graceful cleanup explicitly trap exits and declare their `:shutdown` budget.
- Servers that do not need graceful cleanup continue to crash cleanly and do not trap.
- The default `:shutdown` is left alone unless there is a real reason to deviate. Long shutdown timeouts are treated as a structural problem, not a knob to tune.
- Critical data writes happen synchronously, not lazily at shutdown. `terminate/2` handles only the cooperative cleanup it can guarantee.
- This is compatible with "let it crash." Armstrong's philosophy addresses unexpected mid-operation errors (let the supervisor restart); `terminate/2` addresses expected, cooperative shutdown (drain what you can). Both belong in a mature system.

