---
type: adr
id: 5
title: Get Slow Work Off the Processing Loop
status: accepted
date: '2026-04-22'
updated: '2026-08-09'
tags: [elixir, otp, genserver, handle-continue, task, async, state-ownership]
description: "Slow I/O and unbounded computation belong in supervised concurrent work, not in a GenServer callback. handle_continue provides bounded post-init sequencing but still runs on the processing loop. For asynchronous calls, assign exactly one component to reply on every terminal path. Moving work off the loop does not move state ownership: the task computes and the owning process decides."
---

# ADR-005: Get Slow Work Off the Processing Loop

## Context

ADR-004 establishes that callbacks must not block the processing loop. This ADR covers bounded post-init sequencing and the supervised task lifecycles used to run slow work concurrently, plus the two things that do not change when work moves.

- `handle_continue/2` for bounded sequencing that must run before the first ordinary client message. It is still a callback on the GenServer loop.
- `Task.Supervisor` for concurrent work, with the lifecycle chosen according to whether a result is needed.
- `GenServer.reply/2` to answer a deferred call. The reply itself is a nonblocking message send; the slow computation is why a task exists.

Two things are fixed regardless of the lifecycle. The primitive the caller used to enter the loop determines its built-in response and failure semantics: `cast` and `send/2` provide none, though an application can build a separate message protocol. And the process that owned the state before the work moved still owns it afterward: a task computes, the owning process decides.

## Decision

### Rule 1: Use handle_continue only for bounded post-init sequencing

Use `handle_continue/2` when a bounded step belongs immediately after `init/1` and before ordinary client messages. It releases the process waiting on `start_link`, but it does not run concurrently with the GenServer.

**Correct:**

```elixir
# lib/my_app/inventory/server.ex
@impl true
def init(opts), do: {:ok, State.new(opts), {:continue, :arm_sweep}}

@impl true
def handle_continue(:arm_sweep, %State{} = state),
  do: {:noreply, Impl.arm_sweep(state)}
```

**Wrong:**

```elixir
# lib/my_app/inventory/server.ex
@impl true
def init(opts), do: {:ok, State.new(opts), {:continue, :load_stock}}

@impl true
def handle_continue(:load_stock, %State{} = state) do
  # This HTTP request still occupies the GenServer before it handles clients.
  case Warehouse.load_stock(state.config.warehouse_id) do
    {:ok, stock} -> {:noreply, Impl.install_stock(state, stock)}
    {:error, %ErrorMessage{}} = error -> {:stop, error, state}
  end
end
```

**Why:** `init/1` blocks the supervisor's `start_link` call until it returns. A continuation lets that call return, then runs as the next callback before ordinary client messages. Arming one timer is bounded sequencing. The Wrong version moves the HTTP request later in startup but not off the processing loop; the server accepts messages and makes all of them wait behind the continuation. Slow or unbounded setup needs concurrent work plus an explicit readiness policy for calls that arrive before it finishes.

### Rule 2: Use Task.Supervisor for fire-and-forget work

For work the server kicks off but does not need to synchronize with, use `Task.Supervisor.start_child/2` only when losing one execution is explicitly acceptable. Use `async_nolink/2,3` when a result and abnormal-completion signal must return through `handle_info/2`.

**Correct:**

```elixir
# lib/my_app/inventory/server.ex
@impl true
def handle_cast({:prefetch, sku}, %State{} = state) do
  # Speculative warming is useful but safe to lose on rejection, crash, or restart.
  cache = state.deps.cache

  Task.Supervisor.start_child(state.deps.task_supervisor, fn ->
    Cache.prefetch(cache, sku)
  end)

  {:noreply, state}
end
```

**Wrong:**

```elixir
# lib/my_app/inventory/server.ex
@impl true
def handle_cast({:prefetch, sku}, %State{} = state) do
  cache = state.deps.cache
  spawn(fn -> Cache.prefetch(cache, sku) end)

  {:noreply, state}
end
```

**Why:** `spawn/1` gives the subsystem no lifecycle owner or structured task context, and `spawn_link/1` lets a prefetch crash take the server down. `Task.Supervisor.start_child/2` gives the work lifecycle ownership and standard failure reporting without linking failure to this server; a supervisor configured with `:max_children` can also reject excess starts. It does not make the execution durable. A task may still be rejected, terminated during restart, or lost with the node, and no retry is implied. That is acceptable for speculative prefetching, not for audit records, billing, or any operation whose delivery matters. The supervisor arrives through `state.deps` per ADR-007, so tests do not share task infrastructure accidentally.

### Rule 3: Give asynchronous calls exactly one reply owner

If the caller needs a result but the work cannot run in-line, return `{:noreply, state}` after the task is admitted. The canonical owner-routed lifecycle below makes the GenServer responsible for correlation, cleanup, and exactly one reply on success, structured domain failure, failed admission, or abnormal task completion.

**Correct:**

```elixir
# lib/my_app/ledger/server.ex
@impl true
def handle_call({:reconcile, account_id}, from, %State{} = state) do
  case Impl.start_reconcile(state, from, account_id) do
    {:ok, state} -> {:noreply, state}
    {{:error, %ErrorMessage{}} = error, state} -> {:reply, error, state}
  end
end

@impl true
def handle_info({ref, result}, %State{} = state) when is_reference(ref) do
  case Impl.finish_reconcile(state, ref, result) do
    {:reply, from, reply, state} ->
      GenServer.reply(from, reply)
      {:noreply, state}

    {:stale, state} ->
      {:noreply, state}
  end
end

def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{} = state)
    when is_reference(ref) do
  case Impl.fail_reconcile(state, ref) do
    {:reply, from, error, state} ->
      GenServer.reply(from, error)
      {:noreply, state}

    {:stale, state} ->
      {:noreply, state}
  end
end

# lib/my_app/ledger/impl.ex
# State.pending_calls is bounded by config.max_pending_calls.
@spec start_reconcile(State.t(), GenServer.from(), String.t()) ::
        {:ok, State.t()} | {{:error, ErrorMessage.t()}, State.t()}
def start_reconcile(%State{} = state, from, account_id) do
  if map_size(state.pending_calls) >= state.config.max_pending_calls do
    error =
      ErrorMessage.service_unavailable("Reconciliation capacity reached", %{
        operation: :reconcile
      })

    {{:error, error}, state}
  else
    case start_reconcile_task(state.deps.task_supervisor, account_id) do
      {:ok, %Task{} = task} ->
        pending_calls = Map.put(state.pending_calls, task.ref, from)
        {:ok, %State{state | pending_calls: pending_calls}}

      {:error, %ErrorMessage{}} = error ->
        {error, state}
    end
  end
end

@spec finish_reconcile(State.t(), reference(), ErrorMessage.t_res(term())) ::
        {:reply, GenServer.from(), ErrorMessage.t_res(term()), State.t()}
        | {:stale, State.t()}
def finish_reconcile(%State{} = state, ref, result) do
  Process.demonitor(ref, [:flush])

  case Map.pop(state.pending_calls, ref) do
    {nil, _pending_calls} ->
      {:stale, state}

    {from, pending_calls} ->
      {:reply, from, result, %State{state | pending_calls: pending_calls}}
  end
end

@spec fail_reconcile(State.t(), reference()) ::
        {:reply, GenServer.from(), {:error, ErrorMessage.t()}, State.t()}
        | {:stale, State.t()}
def fail_reconcile(%State{} = state, ref) do
  case Map.pop(state.pending_calls, ref) do
    {nil, _pending_calls} ->
      {:stale, state}

    {from, pending_calls} ->
      error =
        {:error,
         ErrorMessage.service_unavailable("Reconciliation did not complete", %{
           operation: :reconcile
         })}

      {:reply, from, error, %State{state | pending_calls: pending_calls}}
  end
end

defp start_reconcile_task(task_supervisor, account_id) do
  {:ok,
   Task.Supervisor.async_nolink(task_supervisor, fn ->
     Ledger.reconcile(account_id)
   end)}
rescue
  RuntimeError ->
    {:error,
     ErrorMessage.service_unavailable("Reconciliation could not be started", %{
       operation: :reconcile
     })}
catch
  :exit, _reason ->
    {:error,
     ErrorMessage.service_unavailable("Reconciliation could not be started", %{
       operation: :reconcile
     })}
end
```

**Wrong:**

```elixir
# lib/my_app/ledger/server.ex
@impl true
def handle_call({:reconcile, account_id}, _from, %State{} = state) do
  {:reply, Ledger.reconcile(account_id), state}
end
```

**Why:** The Wrong version keeps dependency latency on the loop. In the Correct version, `async_nolink/2` sends `{ref, result}` to the owner and monitors the task with the same reference. Reaching a Task.Supervisor's `:max_children` limit raises `RuntimeError`, while an unavailable supervisor exits the caller; the admission helper normalizes both before anything is tracked, and `handle_call/3` replies with that structured error. An accepted task is removed and replied exactly once when its structured result arrives; `Process.demonitor/2` flushes the following normal `:DOWN`. If the task exits abnormally before returning a result, `:DOWN` removes the entry and produces the one structured failure reply. Unknown or already-cleared references are stale and never reply.

`GenServer.reply/2` is itself only a nonblocking message send; no task is justified merely to call it. A complete alternative may let a task-side coordinator reply directly after the slow computation, but that coordinator must own every terminal reply path: success, structured domain failure, and abnormal completion. The server may clean up correlation but must not race to reply. If the task-side design cannot cover abnormal completion without a double-reply race, use the owner-routed form above.

The task reference monitors the task, not the caller. If caller cancellation matters, separately monitor `elem(from, 0)` and define whether a caller exit merely abandons the result or also terminates the work. That policy is independent of task correlation.

### Rule 4: Choose call, cast, or a bare message by what the caller needs back

Use `call` when the caller needs the built-in result, rejection, admission decision, or acknowledgment. Use `cast` when no confirmation or built-in failure propagation is required. Reserve bare messages for internal events whose protocol stays private to the subsystem.

**Correct:**

```elixir
# lib/my_app/inventory.ex
# call: the caller needs the reservation id, or the rejection that replaces it.
@spec reserve(GenServer.server(), Stock.sku(), pos_integer()) ::
        ErrorMessage.t_res(Reservations.id())
def reserve(server, sku, qty), do: GenServer.call(server, {:reserve, sku, qty})

# cast: a counter bump with nothing to confirm and no rejection to report.
@spec record_lookup(GenServer.server(), Stock.sku()) :: :ok
def record_lookup(server, sku), do: GenServer.cast(server, {:record_lookup, sku})

# lib/my_app/inventory/server.ex
# bare message: {:expire, id} is the subsystem's private protocol, and the only
# sender is this process's own Process.send_after/3 call.
@impl true
def handle_info({:expire, id}, state), do: {:noreply, Impl.expire(state, id)}
```

**Wrong:**

```elixir
# lib/my_app/inventory.ex
# cast where the caller needs the answer: the :ok is invented at the call site
# and says nothing about whether the units were reserved.
@spec reserve(GenServer.server(), Stock.sku(), pos_integer()) :: :ok
def reserve(server, sku, qty), do: GenServer.cast(server, {:reserve, sku, qty})

# send/2 as a public entry point: the private message protocol becomes API, and
# once this server defines handle_info/2 without a catch-all, a typo can crash it.
@spec record_lookup(GenServer.server(), Stock.sku()) :: :ok
def record_lookup(server, sku) do
  send(server, {:record_lookup, sku})
  :ok
end
```

**Why:** The three primitives differ in their built-in response and failure semantics, and the choice is a claim about what the caller requires. `GenServer.call/3` monitors the server, blocks until a reply or timeout, and exits the caller if the server is down, so a value, rejection, or admission decision reaches the caller through the call protocol. `GenServer.cast/2` returns `:ok` immediately regardless of whether the destination server exists. Neither cast nor `send/2` provides a reply, rejection, acknowledgment, or failure propagation; an application can encode a separate response message, but public callers needing those semantics should use `call` instead of rebuilding it. Once a module defines a specific `handle_info/2` without a catch-all, an unmatched message normally raises `FunctionClauseError`; it does not fall through to a generated default. Keeping bare messages inside the subsystem limits both that crash surface and the protocol that callers can depend on.

### Rule 5: Moving work off the loop does not move state ownership

When slow work runs in a task (Rule 2), the task performs the work and returns its result to the owning process. The owning process validates the result against its current state and then applies it. The task does not write state, and it does not decide that its result is still wanted.

**Correct:**

```elixir
# lib/my_app/inventory/server.ex
@impl true
def handle_call({:recount, sku}, _from, %State{} = state) do
  {reply, state} = Impl.start_recount(state, sku)
  {:reply, reply, state}
end

@impl true
def handle_info({ref, result}, %State{} = state) when is_reference(ref),
  do: {:noreply, Impl.apply_recount(state, ref, result)}

def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{} = state)
    when is_reference(ref),
    do: {:noreply, Impl.drop_recount(state, ref)}

# lib/my_app/inventory/impl.ex
@spec start_recount(State.t(), Stock.sku()) ::
        {ErrorMessage.t_ok_res(), State.t()}
def start_recount(%State{} = state, sku) do
  case Recounts.ensure_admission(state.recounts, sku) do
    :ok ->
      start_admitted_recount(state, sku)

    {:error, %ErrorMessage{}} = error ->
      {error, state}
  end
end

defp start_admitted_recount(%State{} = state, sku) do
  case start_recount_task(state.deps.task_supervisor, sku) do
    {:ok, %Task{} = task} ->
      track_recount_task(state, sku, task)

    {:error, %ErrorMessage{}} = error ->
      {error, state}
  end
end

defp track_recount_task(%State{} = state, sku, %Task{} = task) do
  case Recounts.track(state.recounts, sku, task.ref) do
    {:ok, superseded_ref, recounts} ->
      if superseded_ref, do: Process.demonitor(superseded_ref, [:flush])
      # The monitor reference stays inside the process. It is a live alias for
      # this server, not an inert correlation token.
      {:ok, %State{state | recounts: recounts}}

    {:error, %ErrorMessage{}} = error ->
      # State cannot change during this callback, but keep defensive cleanup if
      # admission and insertion ever diverge.
      Process.exit(task.pid, :kill)
      Process.demonitor(task.ref, [:flush])
      {error, state}
  end
end

defp start_recount_task(task_supervisor, sku) do
  {:ok, Task.Supervisor.async_nolink(task_supervisor, fn -> Warehouse.count(sku) end)}
rescue
  RuntimeError ->
    {:error,
     ErrorMessage.service_unavailable("Recount could not be started", %{
       operation: :recount
     })}
catch
  :exit, _reason ->
    {:error,
     ErrorMessage.service_unavailable("Recount could not be started", %{
       operation: :recount
     })}
end

@spec apply_recount(State.t(), reference(), ErrorMessage.t_res(non_neg_integer())) :: State.t()
def apply_recount(%State{} = state, ref, result) do
  Process.demonitor(ref, [:flush])

  case {Recounts.pop(state.recounts, ref), result} do
    {{nil, _recounts}, _result} ->
      state

    {{{_sku, ^ref}, recounts}, {:error, %ErrorMessage{}}} ->
      %State{state | recounts: recounts}

    {{{sku, ^ref}, recounts}, {:ok, counted}} ->
      %State{state | recounts: recounts}
      |> MyApp.Inventory.Consistency.apply_recount(sku, counted)
  end
end

@spec drop_recount(State.t(), reference()) :: State.t()
def drop_recount(%State{} = state, ref) do
  Process.demonitor(ref, [:flush])
  %State{state | recounts: Recounts.delete(state.recounts, ref)}
end
```

**Wrong:**

```elixir
# lib/my_app/inventory/server.ex - the task writes the table and the process state
@impl true
def handle_call({:recount, sku}, _from, %State{} = state) do
  Task.Supervisor.start_child(state.deps.task_supervisor, fn ->
    case Warehouse.count(sku) do
      {:ok, counted} ->
        Stock.set(state.deps.stock_table, sku, counted)

        MyApp.Inventory.update_state(state.name, fn %State{} = current ->
          %State{current | recounts: Map.delete(current.recounts, sku)}
        end)

      {:error, %ErrorMessage{}} ->
        :ok
    end
  end)

  {:reply, :ok, %State{state | recounts: Map.put(state.recounts, sku, :running)}}
end
```

**Why:** `async_nolink/2` returns a `%Task{}` whose `ref` both monitors the task and correlates its result. That reference never leaves the process, and the reason is stronger than encapsulation. `Task` builds it with `:erlang.monitor(:process, pid, alias: :demonitor)`, so it is a live alias for this server rather than an inert token: any process holding it can `send(ref, term)` straight into this mailbox, past the API module ADR-002 Rule 6 makes the boundary. Hand it to a caller and that caller can forge `{ref, {:ok, 999}}`, which arrives ahead of the real result, is correlated as genuine, pops the entry, and leaves the warehouse's actual count to be discarded as stale. Any other term through the same alias reaches `handle_info/2` and raises `FunctionClauseError`, which is the crash surface Rule 4 exists to keep closed. `start_recount/2` therefore replies `:ok`, because the caller has nothing to correlate: the recount's effect lands in the shared table, not in a reply. `Recounts` is the bounded concern defined in ADR-003: admission fails with a structured error before a task starts, insertion can supersede the old reference for the same SKU, and `pop/2` or `delete/2` clears every terminal path. A superseded task may finish, but its forgotten reference authorizes no write. Success and domain failure pop the entry; abnormal `:DOWN`, timeout, and cancellation use `drop_recount/2`; failed task admission creates no entry. If defensive insertion fails after a task starts, the task is killed and demonitored rather than stranded.

The reference proves correlation, not freshness. After correlation succeeds, `MyApp.Inventory.Consistency.apply_recount/3` applies the policy required by this application against current state. Depending on the domain, that may fence a version, exclude mutations, reconcile with an authoritative store, apply deltas, or tolerate temporary divergence. When the required guarantee spans writers, processes, nodes, crashes, or partitions, enforce it in a datastore designed for those tradeoffs rather than reconstructing a weaker database in GenServer and ETS state.

A task result is addressed to the PID that started the task. If that owner dies, the result does not migrate to the replacement process after restart. Recovery that must survive process or node failure requires durable work and correlation state. In the Wrong version the task is a second authority: it writes shared storage and process bookkeeping independently, cannot validate against current owner state, and leaves stale bookkeeping on failure.

## Consequences

- Callbacks stay bounded regardless of how slow the underlying work is.
- Bounded post-init sequencing can run after `start_link` returns. Slow setup uses concurrent work and an explicit readiness policy instead of hiding I/O in `handle_continue/2`.
- Best-effort work has supervised lifecycle ownership and failure reporting, but no false promise of durable execution or retry.
- Casts and bare messages provide no built-in answer or failure propagation. Public operations needing a result, rejection, admission decision, or acknowledgment remain calls.
- Accepted asynchronous calls have one reply owner and terminal cleanup. Task references correlate results; they do not establish domain freshness or survive an owner restart.
- The server owns sequencing; the task owns the slow thing. Neither leaks into the other.
