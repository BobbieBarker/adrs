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
