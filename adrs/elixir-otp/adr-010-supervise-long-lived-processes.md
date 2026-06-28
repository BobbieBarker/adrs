---
type: adr
id: 10
title: "Supervise Every Long-Lived Process"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, otp, supervision, processes, fault-tolerance]
description: "A process started outside a supervision tree has no restart strategy, no deterministic start or shutdown ordering, and is invisible to observer-based introspection because supervisors are the BEAM's lifecycle owners. Start every long-lived process as a static supervisor child, and every runtime-created one under a DynamicSupervisor."
---
# ADR-010: Supervise Every Long-Lived Process

## Context

Spawning a process outside a supervision tree is legal, and for short-lived work it is fine. The problem is the long-lived process started with a bare `spawn`, `spawn_link`, or a hand-rolled `start_link` call buried in application code. Such a process has no lifecycle owner.

A supervisor is the BEAM's lifecycle owner. It starts its children in declared order, links to and monitors each one, applies a restart strategy (`:one_for_one` and friends) when a child exits, and terminates children in reverse start order on shutdown. A process outside the tree gets none of this. A transient crash becomes permanent absence because nothing restarts it. Startup ordering is undefined, so any process that depends on it needs ad-hoc initialization coordination. On application stop, the BEAM tears down the application's supervision tree and waits on each child's `:shutdown`; an orphaned process is not in that tree, so it is not awaited and receives no ordered shutdown signal (the graceful-shutdown contract is ADR-008). It is also invisible to introspection: `:observer` and Phoenix LiveDashboard render the supervision tree, and a PID hanging off nothing does not appear.

The fix is not to forbid spawning. It is to give every process whose lifetime outlives the call that created it a supervisor: a static child for fixed, always-on processes, and a `DynamicSupervisor` for processes created at runtime.

## Decision

### Rule 1: Start fixed processes as static supervisor children

Processes that exist for the life of the application belong in a supervisor's child list, not started from an ad-hoc init function.

**Correct:**

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Counter,
      Supervisor.child_spec(
        {MyApp.Counter, name: :other_counter, initial_value: 15},
        id: :other_counter
      )
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

**Wrong:**

```elixir
def boot_counters do
  {:ok, _pid} = MyApp.Counter.start_link()
  {:ok, _pid} = MyApp.Counter.start_link(name: :other_counter, initial_value: 15)
  :ok
end
```

**Why:** In the wrong version the two counters are linked only to whatever process called `boot_counters`. If that caller exits, the linked counters die with it; if it is unlinked, they leak. Either way nothing restarts them after a crash, their start order relative to dependents is undefined, and application shutdown does not wait on them. The child-list version makes the supervisor their owner: deterministic start order, a restart strategy on failure, reverse-order termination so cleanup runs in dependency order, and a node visible to `:observer` and LiveDashboard. Distinct child specs need distinct `:id` values, which is why the second counter is wrapped in `Supervisor.child_spec/2`.

### Rule 2: Start runtime-created processes under a DynamicSupervisor

When the set of processes is not known until runtime (one per session, connection, or job), a `DynamicSupervisor` is the owner. A bare `spawn` is not.

**Correct:**

```elixir
# In the supervision tree:
{DynamicSupervisor, name: MyApp.SessionSupervisor, strategy: :one_for_one}

def start_session(session_id, opts) do
  spec = {MyApp.Session, Keyword.put(opts, :session_id, session_id)}
  DynamicSupervisor.start_child(MyApp.SessionSupervisor, spec)
end
```

**Wrong:**

```elixir
def start_session(session_id, opts) do
  spawn(fn -> MyApp.Session.run(session_id, opts) end)
end
```

**Why:** The spawned function is owned by nothing. It is not linked into any tree, so the application cannot drain or terminate it on shutdown, a crash leaves no trace and no restart, and it never appears in supervision-tree introspection. `DynamicSupervisor.start_child/2` attaches the runtime process to the tree, so each session inherits the same shutdown ordering, restart strategy, and observability as a static child while still being created on demand. When the process lifetime instead matches a single unit of work, reach for `Task.Supervisor` rather than `DynamicSupervisor` (see ADR-001 and ADR-005).

## Consequences

- Every long-lived process has an owner that restarts it on failure per a declared strategy, rather than vanishing on the first crash.
- Startup order is deterministic and shutdown runs in reverse order, so dependent processes initialize and drain in a defined sequence.
- Application shutdown awaits every process and delivers an ordered `:shutdown` signal, making `terminate/2` cleanup reliable (ADR-008).
- The full process topology is introspectable through `:observer` and LiveDashboard, because everything hangs off the supervision tree.
- Fixed processes live in a child list; runtime-created ones live under a `DynamicSupervisor`. Bare `spawn`/`start_link` of a long-lived process becomes a code smell.
