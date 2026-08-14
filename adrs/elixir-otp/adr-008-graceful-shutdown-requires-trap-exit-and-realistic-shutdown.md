---
type: adr
id: 8
title: Graceful Shutdown Requires trap_exit and a Realistic :shutdown
status: accepted
date: '2026-04-22'
updated: '2026-08-09'
tags: [elixir, otp, genserver, shutdown, supervision]
description: "trap_exit gives a worker an opportunity for bounded, best-effort cleanup during ordinary supervisor shutdown; it does not guarantee cleanup starts or finishes. Give worker children realistic finite shutdown budgets, normally leave supervisor children at :infinity, and make critical writes durable before acknowledgment rather than at shutdown."
---

# ADR-008: Graceful Shutdown Requires trap_exit and a Realistic :shutdown

## Context

Common application paths that can invoke `terminate/2` include:

1. A callback other than `init/1` returns `{:stop, _, _}`.
2. Such a callback raises, or exits via `exit/1`.
3. Such a callback returns a value the behaviour does not accept, which stops the server with `{:bad_return_value, _}`.
4. The process is trapping exits and receives a trappable exit signal **from its parent**, the process that called `start_link`. This covers both an explicit `Process.exit(child, reason)` from the parent and the parent dying and propagating over the link.
5. `GenServer.stop/3` is called, which needs no `trap_exit` at all, because the request arrives as a system message rather than as an exit signal.
6. `:sys.terminate/2,3` asks the system process to terminate.

For trappable reasons, case 4 turns on who sent the signal. A trapped exit from another linked process is delivered to `handle_info/2` as `{:EXIT, pid, reason}`; whether the server stays alive then depends on what that callback returns or raises. Linking to a peer does not give that peer the parent shutdown path.

`terminate/2` does NOT run on `Process.exit(pid, :kill)`, on a supervisor's `:brutal_kill` shutdown, on VM hard shutdown, or on OS SIGKILL.

If cleanup should be attempted during normal supervisor-initiated shutdown, the server must trap exits in `init/1`. Without that, the signal kills the process and `terminate/2` does not run for that path. Trapping only creates an opportunity: cleanup may never start or finish. The worker child's shutdown budget begins when the supervisor sends the signal and includes completing the active callback, ordinary messages already ahead of the trapped exit, and `terminate/2`; exceeding the budget ends in an untrappable kill.

`terminate/2` is a best-effort cooperative shutdown hook, not a persistence layer.

## Decision

### Rule 1: Trap exits only for bounded, best-effort shutdown cleanup

If a worker should attempt bounded, noncritical cleanup during ordinary supervisor shutdown, trap exits in `init/1`. Later task results are not automatically drained; anything still in flight needs its own lifecycle policy.

**Correct:**

```elixir
def init(opts) do
  Process.flag(:trap_exit, true)
  {:ok, State.new(opts)}
end

def terminate(_reason, state) do
  # Both actions are bounded, noncritical, and safe to lose.
  send(state.peer, {:inventory_stopping, state.session_id})

  :telemetry.execute(
    [:my_app, :inventory, :stop],
    %{count: 1},
    %{session_id: state.session_id}
  )

  :ok
end
```

**Wrong:**

```elixir
def init(opts) do
  {:ok, State.new(opts)}
end

def terminate(_reason, state) do
  # This is not reached on ordinary supervisor :shutdown without trap_exit.
  send(state.peer, {:inventory_stopping, state.session_id})
end
```

**Why:** A server that does not trap exits receives an ordinary supervisor `:shutdown` as an exit signal and dies before `terminate/2` executes on that path, so the Wrong version's notification is dead code for that shutdown. Other termination paths may still invoke `terminate/2` without trapping. Trapping changes linked exit signals into messages and gives this worker an opportunity to notify a cooperative peer and emit final telemetry; it does not promise either action will run or complete. Telemetry handlers used here must themselves stay bounded. Servers with no best-effort cleanup should not trap exits.

### Rule 2: Give worker children a realistic finite `:shutdown`

The default worker `:shutdown` of 5000 ms is fine for almost every server. Set a worker's value to the bounded cleanup it actually expects, so that reaching it tells you something. Padding a worker to 30 seconds, 60 seconds, or `:infinity` costs nothing on a healthy shutdown, which is exactly what makes it dangerous: the number is invisible until the day the child wedges, and then it is the number you wait.

Supervisor children are different. Their default is `:infinity`, and they normally retain it so they can terminate their own descendants safely before exiting.

If a worker genuinely needs a long `:shutdown` value, the structural fix is usually upstream: buffered work should not have lived in the process (ADR-003), or writes should have been made durable before acknowledgment rather than batched at exit (Rule 3 below).

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

  # Padded to 30 seconds "to be safe," with no drain that takes 30 seconds.
  # Free every day the server shuts down cleanly, and 30 seconds of dead
  # stop the first day it wedges. ":infinity" is worse: the supervisor
  # loses its ability to recover from a stuck worker at all.
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 30_000
    }
  end
end
```

**Why:** A worker's `:shutdown` is a ceiling, not a wait. The supervisor returns as soon as the worker exits, so a healthy 10 ms cleanup costs 10 ms whether the ceiling is 5000 or 30,000. Padding is invisible until the worker stops responding, and then the padded value is the stall. Static supervisors terminate children in sequence, so three wedged workers at 30 seconds can hold the tree for 90 seconds. A realistic finite worker budget converts a hang into a bounded, attributable failure. This condemnation does not apply to supervisor children: their `:infinity` budget protects orderly descendant shutdown rather than unbounded worker cleanup.

### Rule 3: Make critical state durable on arrival, not at shutdown

The critical state survives across process restarts only if it exists outside the process. `terminate/2` is not that place.

**Correct:**

```elixir
def handle_call({:append, entry}, from, %State{} = state) do
  case Impl.start_append(state, from, entry) do
    {:ok, state} -> {:noreply, state}
    {{:error, %ErrorMessage{}} = error, state} -> {:reply, error, state}
  end
end

def handle_info({ref, result}, %State{} = state) when is_reference(ref) do
  case Impl.finish_append(state, ref, result) do
    {:reply, from, reply, state} ->
      GenServer.reply(from, reply)
      {:noreply, state}

    {:stale, state} ->
      {:noreply, state}
  end
end

def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{} = state)
    when is_reference(ref) do
  case Impl.fail_append(state, ref) do
    {:reply, from, error, state} ->
      GenServer.reply(from, error)
      {:noreply, state}

    {:stale, state} ->
      {:noreply, state}
  end
end

def terminate(_reason, %State{} = state) do
  :telemetry.execute(
    [:my_app, :event_log, :stop],
    %{count: 1},
    %{pending_count: map_size(state.pending_appends)}
  )

  :ok
end
```

`Impl.start_append/3` uses the supervised, bounded, owner-routed lifecycle from ADR-005 Rule 3. Its task calls the application `EventLog` adapter, whose `:ok` means the durable store accepted the entry. Failed admission returns a structured error before tracking anything. `finish_append/3` pops correlation and returns either `:ok` or the adapter's structured domain error; `fail_append/2` pops correlation and returns a structured error after abnormal task completion. Only the GenServer replies.

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

**Why:** `terminate/2` is skipped by `Process.exit(pid, :kill)`, `:brutal_kill`, VM crashes, and SIGKILL. Anything that depends on it running is unreliable by construction. Critical state is acknowledged only after the durable store confirms acceptance, but potentially slow persistence still runs outside the processing loop. `terminate/2` remains limited to bounded work for which best effort is acceptable, such as final telemetry, soft-metadata cleanup, or a nonblocking cooperative protocol notification.

## Consequences

- Servers that need graceful cleanup explicitly trap exits and declare their `:shutdown` budget.
- Servers that do not need graceful cleanup continue to crash cleanly and do not trap.
- The default `:shutdown` is left alone unless there is a real reason to deviate. Long shutdown timeouts are treated as a structural problem, not a knob to tune.
- Critical writes are acknowledged only after durability is confirmed, using the tracked off-loop lifecycle from ADR-005. `terminate/2` handles only bounded cleanup for which best effort is acceptable.
- This is compatible with "let it crash." Unexpected mid-operation errors still belong to supervision; `terminate/2` supplies a bounded best-effort hook for expected cooperative shutdown.
