---
type: adr
id: 9
title: "Send Minimal Data Between Processes"
status: accepted
date: 2026-06-28
updated: '2026-08-12'
tags: [elixir, anti-pattern, processes, message-passing, performance, memory]
description: "Every term sent across a BEAM process boundary is deep-copied into the receiver's isolated heap, and a closure copies every variable it captures, not just the field it reads. Send only the fields a process needs, or let it fetch its own data."
---
# ADR-009: Send Minimal Data Between Processes

## Context

BEAM processes have isolated heaps (the "share nothing" architecture), which keeps per-process garbage collection independent and fast. The cost of that isolation is that every term sent across a process boundary is fully deep-copied into the receiver's heap. The copy is proportional to the size of the term: an atom, pid, or integer is cheap; a large struct with nested maps, binaries, and lists is CPU and memory intensive. The size of the message, not the number of fields the receiver actually reads, drives the cost.

This copy happens on every interprocess boundary: `send/2`, `GenServer.call/3`, `GenServer.cast/2`, and the initial argument to `GenServer.start_link/3`. It is most visible there. It is more subtle with `spawn/1`, `Task.async/1`, and `Task.async_stream/3`, because the anonymous function handed to them captures every variable it references in the enclosing scope, and all captured variables are copied into the spawned process, including the parts of a captured struct the function never touches.

The anti-pattern is shipping more than the receiver needs. The remedies are to send the minimum, or to not send at all: let the receiver fetch its own data, or share read-mostly data through a non-copying store.

## Decision

### Rule 1: Send only the fields the receiver needs

Extract the fields at the call site and send those. This applies wherever a term crosses a process boundary: `send/2`, `GenServer.call/3`, `GenServer.cast/2`, and the initial argument to `GenServer.start_link/3`.

**Correct:**

```elixir
GenServer.cast(pid, {:report_ip_address, conn.remote_ip})
```

**Wrong:**

```elixir
GenServer.cast(pid, {:report_ip_address, conn})
```

**Why:** `conn` is a large struct holding the request body, params, headers, and adapter state. Casting the whole struct deep-copies all of it into the server's heap even though the server reads one field. Extracting `conn.remote_ip` at the call site means only a small tuple crosses the boundary. The same applies to `send/2`, `GenServer.call/3`, and the initial data handed to `GenServer.start_link/3`.

### Rule 2: Bind the value a closure needs before you build the closure

A closure captures the variables it names, not the fields it reads from them. When the closure crosses a process boundary, bind the field to its own variable first, so the capture holds the small term instead of the structure it came from.

**Correct:**

```elixir
ip_address = conn.remote_ip
spawn(fn -> log_request_ip(ip_address) end)
```

**Wrong:**

```elixir
spawn(fn -> log_request_ip(conn.remote_ip) end)
```

**Why:** The anonymous function captures `conn` (the variable it names), not `conn.remote_ip`. When the closure is sent to the spawned process, the entire captured `conn` is deep-copied first; the `remote_ip` field is extracted afterward, inside the new process, from the copy. Binding `ip_address = conn.remote_ip` before the closure means the closure captures only the small IP term, so only that crosses the boundary. The same capture rule governs `Task.async/1` and `Task.async_stream/3`, including the `Task.Supervisor` patterns in ADR-001 and the off-loop work in ADR-005.

### Rule 3: Send an identifier and let the sole consumer load its own data

When one process is the only consumer of a large term, send the identifier and load inside the receiver. When many processes read the same term and it changes rarely, share it through `:persistent_term` rather than sending it to each of them.

**Correct:**

```elixir
# Send an identifier; the sole consumer loads what it needs on its own heap.
GenServer.cast(MyApp.Reporter, {:render, report_id})

def handle_cast({:render, report_id}, state) do
  report = MyApp.Reports.load(report_id)
  render(report)
  {:noreply, state}
end
```

**Wrong:**

```elixir
# Caller loads the full record only to ship it to the one process that uses it.
report = MyApp.Reports.load(report_id)
GenServer.cast(MyApp.Reporter, {:render, report})
```

**Why:** If the receiving process is the only consumer, loading the data inside the receiver keeps the large term on a single heap, so it never crosses a process boundary and is never copied. Passing the id moves a small term and defers the load to the one process that needs it. For data that many processes read and that changes infrequently, `:persistent_term` stores one shared copy that readers access without copying. The reason it suits read-mostly data only is the write side: replacing a complex term with `put/2` or removing one with `erase/1` initiates a global garbage collection, and all processes in the system are scheduled to scan their heaps for the replaced term. Each scan is light, but with many processes the system is less responsive until they finish. Terms that fit in one machine word, atoms included, are optimized to skip the global collection. Both strategies keep large terms out of process state (ADR-003).

## Consequences

- Messages carry identifiers and small scalar fields, not whole structs. Copy cost at each process boundary scales with what the receiver uses, not with what the sender happens to hold.
- Closures passed to `spawn`, `Task.async`, and `Task.async_stream` capture pre-bound minimal values, so background work does not silently drag a full struct into a new heap.
- The sole-consumer case fetches its own data; read-mostly shared data lives in `:persistent_term` instead of being copied on every message.
- Per-process garbage collection stays cheap because each heap holds only the data that process needs.
