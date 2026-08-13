---
type: adr
id: 7
title: Compensate Completed Effects in Fallible Chains
status: accepted
date: 2026-08-02
updated: 2026-08-09
tags: [elixir, error-handling, with, side-effects, compensation, resource-lifetime, otp]
description: "`with` propagates a returned failure and undoes nothing. Inline compensation handles returned failures while the coordinator remains alive; a live local owner may monitor a holder to reclaim process-scoped resources; external effects that must be repaired after coordinator or VM death need provider expiry or durable correlation state and reconciliation. Callers supply undos in reverse acquisition order, every supplied undo is attempted left-to-right, cleanup failures are appended to the original structured error, and idempotency replaces compensation only under durably owned retry-to-completion."
---

# ADR-007: Compensate Completed Effects in Fallible Chains

## Context

`with` is pattern-match-or-fall-through. A successful `<-` binds and continues; a returned non-match stops the chain and becomes the value of the `with`. That is propagation, not reversal, and nothing in the macro undoes an effect that already succeeded. A sequence that reserves stock in a warehouse, captures a payment, then fails to schedule a shipment returns the third step's error correctly and immediately, with the stock still reserved and the money still captured. The returned failure path retains neither handle, so it has no way to release either effect. The omission is structural, not a matter of remembering cleanup at the caller.

There is a second failure class the inline chain cannot repair. The coordinator can die between effects, so a compensation written for a returned `{:error, _}` never runs. `terminate/2` does not close that gap; `elixir-otp` ADR-008 defines it as bounded, best-effort cooperative cleanup rather than durable recovery. For a process-scoped local resource, a live local owner can monitor the holder and reclaim the resource when that holder terminates. That guarantee lasts only while the owner remains alive. A monitor and an in-memory undo closure disappear with their owner or VM, a supervised task is not durable recovery, and remote `:noconnection` proves lost connectivity rather than holder death. External effects that must be repaired after coordinator or VM death need provider expiry or durable correlation or workflow state plus reconciliation. Which durable system supplies that guarantee is an application decision.

Database rollback covers only statements participating in one active `Repo.transact` (`elixir-ecto` ADR-001). It does not include external effects and cannot reverse a transaction that already committed. When later work fails after commit, database state may need another state transition or durable forward completion. This ADR covers how the surrounding design treats completed effects: inline compensation for failures returned while the coordinator remains alive, process ownership for local resource lifetimes, and durable recovery when repair must survive coordinator or VM death.

## Decision

A sequence over two or more external effects names, for every effect that can outlive a later failure, an inline compensation, a process-scoped owner, or an application-chosen durable recovery path with the guarantee that effect requires. Inline sequences run in the calling process or in a supervised task, never inside a GenServer callback when their steps are network calls (`elixir-otp` ADR-004 Rule 1); neither location makes their in-memory undo state durable. The remaining `with` chain carries only steps whose failure handling is propagation.

### Rule 1: Name a compensation for every effect that outlives a later failure

When a function performs two or more external effects in sequence, each effect after the first inherits an obligation: on its returned failure, everything acquired before it is offered to compensation. The handle for each effect stays in a function parameter so it remains in scope on later failure paths. `Compensation.run/2` (Rule 2) executes the supplied undo list left-to-right and always returns the original error tuple, augmented if cleanup failed. Callers therefore supply undos in reverse acquisition order.

**Correct:**

```elixir
defmodule MyApp.Orders do
  alias MyApp.Compensation
  alias MyApp.Orders.{Capture, Order, Payments, Reservation, Shipment, Shipping, Warehouse}

  @spec submit(Order.t()) :: ErrorMessage.t_res(Shipment.t())
  def submit(%Order{} = order) do
    case Warehouse.reserve(order) do
      {:ok, %Reservation{} = reservation} -> capture_payment(order, reservation)
      {:error, %ErrorMessage{}} = error -> error
    end
  end

  defp capture_payment(%Order{} = order, %Reservation{} = reservation) do
    case Payments.capture(order) do
      {:ok, %Capture{} = capture} ->
        schedule_shipment(reservation, capture)

      {:error, %ErrorMessage{}} = error ->
        Compensation.run(error, [fn -> Warehouse.release(reservation) end])
    end
  end

  defp schedule_shipment(%Reservation{} = reservation, %Capture{} = capture) do
    case Shipping.schedule(reservation) do
      {:ok, %Shipment{} = shipment} ->
        {:ok, shipment}

      {:error, %ErrorMessage{}} = error ->
        Compensation.run(error, [
          fn -> Payments.refund(capture) end,
          fn -> Warehouse.release(reservation) end
        ])
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Orders do
  alias MyApp.Orders.{Order, Payments, Shipment, Shipping, Warehouse}

  @spec submit(Order.t()) :: ErrorMessage.t_res(Shipment.t())
  def submit(%Order{} = order) do
    with {:ok, reservation} <- Warehouse.reserve(order),
         {:ok, _capture} <- Payments.capture(order),
         {:ok, shipment} <- Shipping.schedule(reservation) do
      {:ok, shipment}
    end
  end
end
```

**Why:** The Wrong chain satisfies every rule in ADR-005: three fallible steps, all `<-`, no plain `=`, no `else`. It still leaves completed effects unresolved because the bindings made by earlier `<-` steps are scoped to the `with` and the returned `{:error, %ErrorMessage{}}` retains neither handle. Function parameters are the scope that survives a later step's failure, which is why the Correct version threads each handle into the function that performs the next effect. `schedule_shipment/2` holds exactly the two handles that outlive its own failure, so its undo list is checkable locally. `Compensation.run/2` executes that list left-to-right: refund the later capture first, then release the earlier reservation.

Provider-assigned resource identity does not prevent the caller from also sending an idempotency key. Use provider correlation and status lookup where supported, because a remote timeout is indeterminate: the capture or refund may have completed even though no reply arrived. Acquisition and compensation operations must be retry-safe under that uncertainty. Idempotency makes replay safe; it does not itself undo a completed effect when the workflow is permanently abandoned.

### Rule 2: Report a failed compensation on the original error; never hard-match it

An undo returns `:ok | {:error, %ErrorMessage{}}` (ADR-008 Rule 1). `Compensation.run/2` has no success result: it always returns the original `{:error, %ErrorMessage{}}`, augmented under a known `details` key when an undo failed or its result was indeterminate. The original error's `code` and `message` remain primary so the caller's existing match still fires.

**Correct:**

```elixir
defmodule MyApp.Compensation do
  require Logger

  @max_failure_details 10
  @cleanup_categories [:returned_error, :exception, :exit, :throw, :invalid_return]

  @type undo :: (-> ErrorMessage.t_ok_res())
  @type cleanup_category :: :returned_error | :exception | :exit | :throw | :invalid_return
  @type cleanup_detail :: %{cleanup_category: cleanup_category(), error_code: atom()}

  @spec run({:error, ErrorMessage.t()}, [undo()]) :: {:error, ErrorMessage.t()}
  def run({:error, %ErrorMessage{} = original}, undos) do
    case Enum.flat_map(undos, &run_undo/1) do
      [] -> {:error, original}
      failures -> {:error, attach_failures(original, failures)}
    end
  end

  defp run_undo(undo) do
    case attempt_undo(undo) do
      :ok ->
        []

      {:error, category, %ErrorMessage{} = failure} ->
        Logger.error("compensation did not complete",
          cleanup_category: category,
          error_code: failure.code
        )

        [%{cleanup_category: category, error_code: failure.code}]
    end
  end

  defp attempt_undo(undo) do
    try do
      normalize_return(undo.())
    rescue
      _exception -> cleanup_failure(:exception)
    catch
      :exit, _reason -> cleanup_failure(:exit)
      :throw, _value -> cleanup_failure(:throw)
    end
  end

  defp normalize_return(:ok), do: :ok

  defp normalize_return({:error, %ErrorMessage{} = failure}),
    do: {:error, :returned_error, failure}

  defp normalize_return(_invalid), do: cleanup_failure(:invalid_return)

  defp cleanup_failure(category) do
    {:error, category,
     ErrorMessage.internal_server_error(
       "Compensation did not complete",
       %{operation: :compensate, cleanup_category: category}
     )}
  end

  defp attach_failures(%ErrorMessage{} = error, failures) do
    details = if is_map(error.details), do: error.details, else: %{}

    existing =
      details
      |> Map.get(:compensation_failures, [])
      |> normalize_failure_details()

    previously_omitted =
      case Map.get(details, :compensation_failures_omitted, 0) do
        count when is_integer(count) and count >= 0 -> count
        _invalid -> 0
      end

    combined = existing ++ failures
    retained = Enum.take(combined, @max_failure_details)
    omitted = previously_omitted + max(length(combined) - length(retained), 0)

    %ErrorMessage{
      error
      | details:
          Map.merge(details, %{
            compensation_failures: retained,
            compensation_failures_omitted: omitted
          })
    }
  end

  defp normalize_failure_details(details) when is_list(details) do
    details
    |> Enum.flat_map(fn
      %{cleanup_category: category, error_code: code}
      when category in @cleanup_categories and is_atom(code) ->
        [%{cleanup_category: category, error_code: code}]

      _invalid ->
        []
    end)
    |> Enum.take(@max_failure_details)
  end

  defp normalize_failure_details(_invalid), do: []
end
```

**Wrong:**

```elixir
defmodule MyApp.Compensation do
  @spec run({:error, ErrorMessage.t()}, [(-> ErrorMessage.t_ok_res())]) ::
          {:error, ErrorMessage.t()}
  def run({:error, %ErrorMessage{}} = error, undos) do
    Enum.each(undos, fn undo -> :ok = undo.() end)
    error
  end
end
```

**Why:** `=` is the match operator, so the Wrong version raises `MatchError` on a structured cleanup error and skips every later undo. An undo may also raise, exit, throw, or return a value outside its declared contract; any of those outcomes would abort an unprotected enumeration. The Correct version isolates each invocation, normalizes every synchronous outcome, and continues left-to-right through the supplied list. It adds no timeout policy: a timeout would be an application-specific remote-operation decision, not a generic property of compensation.

The original error remains the return value with its code and message untouched. New cleanup failures are projected to only `cleanup_category` and `error_code`, appended after valid existing projections, and capped at ten records; `compensation_failures_omitted` reports how many additional records were not retained. No nested ErrorMessage or its details enters the original error. Logging selects the same two fields rather than stringifying an ErrorMessage or raw exception, exit, throw, or invalid return. A failed attempt establishes that cleanup failed or is indeterminate; it does not prove the external resource remains allocated.

This isolation covers outcomes the compensation process can catch. An untrappable process death or VM failure can still stop the enumeration before later undos are attempted; effects that must survive that boundary use the durable recovery model from the Context.

### Rule 3: Match process ownership and durable retry to the required lifetime

When a local resource is held by a BEAM process and a live local owner identifies the holder by pid (a pool lease, a registry entry, a checked-out connection), acquire it inside the holding process and have the owner monitor that pid. That aligns process-scoped release with the holder's lifetime while the owner remains alive; it is not durable recovery after owner or VM death.

For an external effect, idempotency makes replay safe but does not remove a completed effect when a workflow is permanently abandoned. It replaces compensation only when a durable owner is committed to retrying the workflow to completion. Provider-assigned identity can coexist with a caller-supplied idempotency key. Remote timeouts are indeterminate, so use correlation and status lookup where supported and make both acquisition and compensation retry-safe.

**Correct:**

```elixir
# lib/my_app/ingest/worker/server.ex
@impl true
def init(opts), do: {:ok, State.new(opts), {:continue, :acquire_lease}}

@impl true
def handle_continue(:acquire_lease, state) do
  case Impl.acquire_lease(state) do
    {:ok, leased_state} -> {:noreply, leased_state}
    {:error, %ErrorMessage{}} = error -> {:stop, error, state}
  end
end

# lib/my_app/ingest/worker/impl.ex
# Runs in the worker process, so the live local Pool owner monitors the worker
# and frees process-scoped capacity when that worker terminates.
@spec acquire_lease(State.t()) :: ErrorMessage.t_res(State.t())
def acquire_lease(%State{} = state) do
  case Pool.acquire(state.batch_id) do
    {:ok, lease} -> {:ok, %State{state | lease: lease}}
    {:error, %ErrorMessage{}} = error -> error
  end
end
```

**Wrong:**

```elixir
# lib/my_app/ingest.ex
# The caller acquires; the worker holds. The lease follows the wrong lifetime.
@spec start_batch(GenServer.name(), String.t()) :: ErrorMessage.t_res(pid())
def start_batch(name, batch_id) do
  case Pool.acquire(batch_id) do
    {:ok, lease} -> Worker.start(%{name: name, lease: lease, batch_id: batch_id})
    {:error, %ErrorMessage{}} = error -> error
  end
end

# lib/my_app/ingest/worker/server.ex
@impl true
def init(opts) do
  Process.flag(:trap_exit, true)
  {:ok, State.new(opts)}
end

# A cooperative cleanup attempt; not durable recovery.
@impl true
def terminate(_reason, %State{lease: lease}), do: Pool.release(lease)
```

**Why:** When the worker calls `Pool.acquire/1`, the local pool receives the worker pid in `handle_call/3`'s `from` tuple and monitors it. While that pool owner remains alive, local worker termination produces a `:DOWN` it can handle to reclaim capacity. The pool serializes the state updates it handles, but it does not promise ordering among messages sent by different processes. A monitor disappears if its owner or VM dies; for a remote pid, `:noconnection` establishes lost connectivity rather than proving that the holder terminated.

The Wrong version ties the lease to the caller. If that caller exits, the pool may release capacity while the worker still uses it; if the worker exits while the caller remains alive, the lease does not follow the worker's lifetime. Putting release in `terminate/2` adds only `elixir-otp` ADR-008's bounded best-effort opportunity and still misses untrappable or non-cooperative termination. The pool refuses rather than queues when saturated, returning a structured `:too_many_requests` error immediately, which keeps this local acquisition bounded enough for `handle_continue/2` (`elixir-otp` ADR-004 Rule 1).

A supervised task can be the holder of a process-scoped resource, so that acquisition belongs inside the task function rather than in the spawner. The task, its monitor, and its in-memory undo list still do not survive VM death. External repair that must survive that boundary needs provider expiry or durable correlation state and reconciliation; the application chooses the mechanism and any durably owned retry-to-completion policy.

### Rule 4: Put the compensation in the composing function, not in an `else` clause

A `with` chain carries no compensation history. Once a step needs an action on failure, that step leaves the chain and becomes a `case` inside a function that already holds the earlier handles. The steps whose only failure handling is propagation stay in the bare `with`. Never add an `else` clause to carry the compensation. `Compensation.run/2` is defined in Rule 2.

**Correct:**

```elixir
defmodule MyApp.Orders do
  alias MyApp.Compensation
  alias MyApp.Orders.{Capture, Credit, Order, Payments, Reservation, Warehouse}

  @spec submit(Order.t()) :: ErrorMessage.t_res(Capture.t())
  def submit(%Order{} = order) do
    with :ok <- Order.validate(order),
         :ok <- Credit.check(order),
         {:ok, %Reservation{} = reservation} <- Warehouse.reserve(order) do
      capture_payment(order, reservation)
    end
  end

  defp capture_payment(%Order{} = order, %Reservation{} = reservation) do
    case Payments.capture(order) do
      {:ok, %Capture{} = capture} ->
        {:ok, capture}

      {:error, %ErrorMessage{}} = error ->
        Compensation.run(error, [fn -> Warehouse.release(reservation) end])
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Orders do
  alias MyApp.Orders.{Order, Payments, Shipment, Shipping, Warehouse}

  @spec submit(Order.t()) :: ErrorMessage.t_res(Shipment.t())
  def submit(%Order{} = order) do
    {:ok, reservation} = Warehouse.reserve(order)

    with {:ok, _capture} <- Payments.capture(order),
         {:ok, shipment} <- Shipping.schedule(reservation) do
      {:ok, shipment}
    else
      {:error, %ErrorMessage{}} = error ->
        Warehouse.release(reservation)
        error
    end
  end
end
```

**Why:** An `else` clause receives one value: the non-matched value of whichever step aborted, and nothing else. It carries no record of how far the chain got, so it cannot distinguish a `Payments.capture/1` failure (a reservation to release, no capture yet) from a `Shipping.schedule/1` failure (a capture to refund as well). The Wrong version therefore releases the reservation on both failures and refunds the capture on neither, which is the only behavior an `else` can express without going back to the outside world to re-derive what it already did. Scope forces the rest of the damage. `reservation` would be bound by a `<-` inside the chain and is not in scope in `else`, so the acquisition gets hoisted out into `{:ok, reservation} = Warehouse.reserve(order)`, a hard match that raises `MatchError` the first time the item is out of stock, which is the warehouse's ordinary response and not an exception. `Warehouse.release/1`'s own failure is discarded on top of that, violating Rule 2. The flattening cost from ADR-005 Rule 2 (avoid `else`; normalize return shapes in the called functions) applies as well: both `<-` steps funnel into a single clause, so the error a reader sees has no step attached to it. In the Correct version the chain runs until a step needs more than propagation. `Warehouse.reserve/1` stays in it, because nothing was acquired before it and its failure handling is propagation. `Payments.capture/1` leaves it, because its failure has a reservation to release, and `capture_payment/2` handles that failure where `reservation` is a parameter: one `case` per effect, which is also ADR-005 Rule 3's shape for a single fallible step. Shipping is added the same way, as one more function holding the two handles that outlive it (Rule 1).

## Consequences

- A function that performs two or more external effects reads as a ladder of single-effect `case` clauses, each holding the handles of the effects before it. Multi-step `with` chains appear only where every step's failure handling is propagation.
- `Compensation.run/2` executes the supplied undo list left-to-right, so callers supply undos in reverse acquisition order. Each undo returns `:ok | {:error, %ErrorMessage{}}`; `run/2` itself always returns the original error tuple with any new cleanup failures appended after the existing `:compensation_failures` list.
- Every inline undo is attempted despite a structured error, exception, ordinary exit, throw, or invalid return from an earlier undo. Cleanup is reported as failed or indeterminate without replacing the original error or logging whole error values.
- A live local owner may monitor a local holder and reclaim process-scoped capacity on `:DOWN`. That monitor disappears with its owner or VM, remote `:noconnection` proves only lost connectivity, and `terminate/2` remains bounded best-effort cleanup per `elixir-otp` ADR-008.
- Idempotency makes replay safe and replaces compensation only when a durable owner will retry to completion. External repair that must survive coordinator or VM death uses application-chosen provider expiry or durable correlation or workflow state plus reconciliation.
- Statements participating in one active `Repo.transact` rely on database rollback. External effects and already committed transactions do not; a post-commit failure may require another database transition or durable forward completion.
