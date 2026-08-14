# Elixir OTP / GenServer - ADRs

ADRs covering OTP, GenServer, supervision, BEAM scheduling, and stateful-process testing.

Source: https://github.com/BobbieBarker/adrs

---
type: adr
id: 1
title: Reach for Simpler Primitives Before GenServer
status: accepted
date: 2026-04-17
updated: 2026-08-09
tags: [elixir, otp, genserver, concurrency, architecture]
description: A GenServer is a long-lived OTP process that serializes its own message handling. Use it when that serialization, exclusive ownership, or long-lived coordination is required; otherwise default to a plain module, Agent, Task, Registry, or ETS.
---

# ADR-001: Reach for Simpler Primitives Before GenServer

## Context

GenServer is frequently reached for as a default for any stateful or service-shaped behavior. A GenServer is a long-lived OTP-managed process whose receive loop handles one callback at a time; it serializes its own message handling, not the caller processes. Many uses do not require that serialization, exclusive ownership, or long-lived timer, monitor, admission, rate, or protocol coordination. Reaching for it when a simpler primitive fits creates a single-point bottleneck, introduces a process lifecycle to reason about, and makes the code harder to test.

Simpler building blocks (plain modules, `Agent`, `Task`, `Registry`, and ETS) cover most cases where engineers write GenServers.

## Decision

Work the ladder. Use the first primitive that fits. The blocks below are reduced to the primitive under discussion: file-path comments carry the three-file layout ADR-002 requires of a GenServer rather than repeating it in full, and every registered name arrives in opts, per ADR-007 Rule 1.

### Rule 1: Plain module for pure functions

If the behavior holds no state and coordinates nothing, write a module.

**Correct:**

```elixir
defmodule MyApp.Pricing do
  alias MyApp.Catalog.Item

  @spec calculate_total([Item.t()], String.t() | nil) :: non_neg_integer()
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

  def start_link(%{name: name}), do: GenServer.start_link(__MODULE__, nil, name: name)
  def calculate_total(server, items, code), do: GenServer.call(server, {:calc, items, code})

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
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
  @spec start_link(map()) :: Agent.on_start()
  def start_link(%{name: name, flags: flags}), do: Agent.start_link(fn -> flags end, name: name)

  @spec enabled?(Agent.agent(), atom()) :: boolean()
  def enabled?(agent, flag), do: Agent.get(agent, &Map.get(&1, flag, false))

  @spec set(Agent.agent(), atom(), boolean()) :: :ok
  def set(agent, flag, value), do: Agent.update(agent, &Map.put(&1, flag, value))
end
```

**Wrong:**

```elixir
defmodule MyApp.FeatureFlags do
  use GenServer

  def start_link(%{name: name, flags: flags}),
    do: GenServer.start_link(__MODULE__, flags, name: name)

  def enabled?(server, flag), do: GenServer.call(server, {:enabled?, flag})
  def set(server, flag, value), do: GenServer.call(server, {:set, flag, value})

  @impl true
  def init(flags), do: {:ok, flags}

  @impl true
  def handle_call({:enabled?, flag}, _from, state),
    do: {:reply, Map.get(state, flag, false), state}

  @impl true
  def handle_call({:set, flag, value}, _from, state),
    do: {:reply, :ok, Map.put(state, flag, value)}
end
```

**Why:** `Agent` is a GenServer with a narrower API for the get/update case. It communicates that no message-handling complexity exists. The closure passed to `Agent.get/2` and `Agent.update/2` is sent to the agent and runs inside it, so a read and a read-modify-write are each one message handled by one callback. Both Correct `Agent.update/2` and Wrong `GenServer.call/2` wait for the update, so the comparison preserves the caller-visible completion contract. `enabled?/2` and `set/3` are transitions the module publishes rather than the state accessor ADR-002 Rule 1 removes. Upgrade to GenServer when timers, `handle_info`, or custom dispatch are needed.

### Rule 3: Task or Task.Supervisor for concurrent work

If the process lifetime matches the lifetime of a unit of work, use `Task`. For supervised concurrency and cancellation, use `Task.Supervisor`.

**Correct:**

```elixir
@spec send_welcome_emails(Supervisor.supervisor(), [User.t()], pos_integer()) ::
        ErrorMessage.t_res([term()])
def send_welcome_emails(task_supervisor, users, timeout_ms) do
  task_supervisor
  |> Task.Supervisor.async_stream_nolink(users, &MyApp.Mailer.send_welcome/1,
    max_concurrency: 10,
    timeout: timeout_ms,
    on_timeout: :kill_task
  )
  |> MyApp.EmailBatch.collect()
end

defmodule MyApp.EmailBatch do
  @moduledoc false

  @spec capture((-> ErrorMessage.t_res(term()))) ::
          {:ok, ErrorMessage.t_res(term())} | {:exit, term()}
  def capture(operation) do
    try do
      {:ok, operation.()}
    catch
      kind, reason -> {:exit, {kind, reason}}
    end
  end

  @spec collect(Enumerable.t()) :: ErrorMessage.t_res([term()])
  def collect(results) do
    results
    |> Enum.reduce_while({:ok, []}, &collect_one/2)
    |> reverse_receipts()
  end

  defp collect_one({:ok, {:ok, receipt}}, {:ok, receipts}),
    do: {:cont, {:ok, [receipt | receipts]}}

  defp collect_one({:ok, {:error, %ErrorMessage{}} = error}, _acc),
    do: {:halt, error}

  defp collect_one({:exit, _reason}, _acc) do
    error =
      ErrorMessage.service_unavailable(
        "Welcome email worker stopped",
        %{operation: :send_welcome_email}
      )

    {:halt, {:error, error}}
  end

  defp reverse_receipts({:ok, receipts}), do: {:ok, Enum.reverse(receipts)}
  defp reverse_receipts({:error, %ErrorMessage{}} = error), do: error
end
```

**Wrong:**

```elixir
defmodule MyApp.EmailSender do
  use GenServer

  def start_link(%{name: name}), do: GenServer.start_link(__MODULE__, [], name: name)

  @spec send_welcome_emails(GenServer.server(), [User.t()]) ::
          ErrorMessage.t_res([term()])
  def send_welcome_emails(server, users), do: GenServer.call(server, {:send_all, users})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:send_all, users}, _from, state) do
    result =
      users
      |> Enum.map(fn user ->
        MyApp.EmailBatch.capture(fn -> MyApp.Mailer.send_welcome(user) end)
      end)
      |> MyApp.EmailBatch.collect()

    {:reply, result, state}
  end
end
```

**Why:** Both versions wait for the batch and expose the same application-owned result contract. This example's local aggregate policy returns receipts when every delivery succeeds and otherwise returns the first observed structured error; another application may choose a different partial-success policy at this boundary. `on_timeout: :kill_task` turns the application-chosen task timeout into a stream exit value, `EmailBatch.collect/1` normalizes that and other raw task exits, and `EmailBatch.capture/1` gives the sequential comparison the same item-result envelope when an invocation raises, exits, or throws. The Correct version uses `max_concurrency` to bound this stream's in-flight tasks. The Wrong version performs each network call sequentially inside one callback, so every other message in that mailbox waits behind the entire batch, which is what ADR-004 rules out.

### Rule 4: Registry for named process lookup

If the purpose of the server is to map keys to processes, use `Registry`.

**Correct:**

```elixir
# In the supervision tree, which supplies the production names:
{Registry, keys: :unique, name: MyApp.SessionRegistry}
{DynamicSupervisor, strategy: :one_for_one, name: MyApp.SessionSupervisor}

# Registration happens at start time, through the :via tuple in the child's own opts:
@spec start_session(
        Supervisor.supervisor(),
        Registry.registry(),
        String.t(),
        map()
      ) :: DynamicSupervisor.on_start_child()
def start_session(supervisor, registry, session_id, opts) do
  child_opts = Map.put(opts, :name, {:via, Registry, {registry, session_id}})
  DynamicSupervisor.start_child(supervisor, {MyApp.Session, child_opts})
end

@spec lookup(Registry.registry(), String.t()) :: ErrorMessage.t_res(pid())
def lookup(registry, session_id) do
  case Registry.lookup(registry, session_id) do
    [{pid, _meta}] -> {:ok, pid}
    [] -> {:error, ErrorMessage.not_found("No session registered", %{id: session_id})}
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.SessionManager do
  use GenServer

  def start_link(%{name: name}), do: GenServer.start_link(__MODULE__, %{}, name: name)
  def lookup(server, id), do: GenServer.call(server, {:lookup, id})
  def register(server, id, pid), do: GenServer.call(server, {:register, id, pid})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:lookup, id}, _from, state),
    do: {:reply, Map.get(state, id), state}

  def handle_call({:register, id, pid}, _from, state),
    do: {:reply, :ok, Map.put(state, id, pid)}
end
```

**Why:** `Registry` keeps its entries in ETS and reads them from the calling process, so node-local lookups do not queue behind a mailbox. It supports `:via` tuples so the DynamicSupervisor starts each child with its registration identity, and Registry removes registrations automatically when processes exit. The GenServer version serializes every lookup through one mailbox and must implement process monitoring itself. Its `register/3` is also a second message a caller has to remember after starting a process: before that message, a live child is missing from the directory; after it, a directory that does not monitor the child can retain a stale PID when the child exits. Making the `:via` name part of child startup removes that split protocol.

### Rule 5: ETS when readers must bypass a mailbox

If multiple processes must read the same state directly and concurrently, use ETS with an owning process for lifecycle and mutation ownership. Each mutation is one atomic ETS operation or passes through one owner; requirements spanning objects, resources, writers, or failures belong in a datastore with the guarantees the application needs. Storage whose contract is a cache goes to a cache library with a sandbox adapter instead, per ADR-007 Rule 4.

**Correct:**

```elixir
# lib/my_app/flags.ex - startup injects this handle into direct readers
defmodule MyApp.Flags do
  alias MyApp.Flags.Server

  @enforce_keys [:table, :writer]
  defstruct [:table, :writer]

  @type t :: %__MODULE__{table: :ets.table(), writer: GenServer.server()}

  @spec connect(GenServer.server()) :: t()
  def connect(server), do: Server.handle(server)

  @spec enabled?(t(), atom()) :: boolean()
  def enabled?(%__MODULE__{table: table}, flag),
    do: :ets.lookup_element(table, flag, 2, false)

  @spec set(t(), atom(), boolean()) :: :ok
  def set(%__MODULE__{writer: writer}, flag, value),
    do: GenServer.call(writer, {:set, flag, value})
end

# lib/my_app/flags/server.ex - this process owns the unnamed table and all writes
@impl true
def init(%{flags: flags} = opts) do
  table = :ets.new(:flags, [:set, :protected, read_concurrency: true])
  :ets.insert(table, Map.to_list(flags))
  {:ok, State.new(Map.put(opts, :table, table))}
end

@spec handle(GenServer.server()) :: MyApp.Flags.t()
def handle(server), do: GenServer.call(server, :handle)

@impl true
def handle_call(:handle, _from, %State{table: table} = state) do
  {:reply, %MyApp.Flags{table: table, writer: self()}, state}
end

@impl true
def handle_call({:set, flag, value}, _from, state) do
  {result, new_state} = Impl.set(state, flag, value)
  {:reply, result, new_state}
end

# lib/my_app/flags/impl.ex - the write, as a function of the state it was handed
@spec set(State.t(), atom(), boolean()) :: {:ok, State.t()}
def set(%State{table: table} = state, flag, value) do
  :ets.insert(table, {flag, value})
  {:ok, state}
end
```

**Wrong:**

```elixir
# lib/my_app/flags.ex - the read is a message like every other message
def enabled?(server, flag), do: GenServer.call(server, {:enabled?, flag})

# lib/my_app/flags/server.ex - the flags live in the process state, so both paths queue
@impl true
def handle_call({:enabled?, flag}, _from, state),
  do: {:reply, Map.get(state, flag, false), state}

def handle_call({:set, flag, value}, _from, state),
  do: {:reply, :ok, Map.put(state, flag, value)}
```

**Why:** The unnamed table reference is an explicit capability tied to the owning server's lifetime. Subsystem startup obtains the handle once and injects it into readers; each read then runs in its caller and bypasses the mailbox. In the map-in-state version, every read queues behind every write and unrelated message. `:protected` permits direct reads while reserving writes for the owner, and the shown mutation is one atomic `:ets.insert/2`. The owner manages lifetime and mutation order; it is not on the read path. The owner's restart is where this arrangement is won or lost, so the supervision strategy is part of the rule rather than an afterthought. An unnamed table dies with the process that created it, and the replacement is a different reference, so every handle injected before the restart now names a table that does not exist and each read against it raises `ArgumentError` from then on. Put the owner and its direct readers in one subtree under `:rest_for_one`, with the owner started first, or under `:one_for_all`, so a reader restarts alongside the owner and obtains the new handle during its own startup. `:one_for_one` over that pair is the configuration that fails quietly: the owner comes back healthy, the readers were never restarted, and they keep reading through a dead reference. A table that genuinely must outlive its owner is a different decision and needs an `:heir` and a recovery path to go with it.

### When a GenServer IS the right answer

Use GenServer when one or more of the following applies:

- Serialized access to mutable state with multi-field invariants that ETS atomic operations cannot preserve.
- Exclusive ownership of a resource or protocol plus the admission, rate, timer, or monitor state governing it.
- Long-lived coordination behavior combining calls, casts, `handle_info` messages, timers, monitor events, and readiness in a non-trivial way.

Ownership does not make slow TCP, file, or HTTP work safe inside a callback. Keep dependency latency off the processing loop even when the GenServer owns the resource handle or the protocol state; ADR-004 and ADR-005 carry the task and reply lifecycle.

If the reason does not fall into one of the above, use a simpler primitive.

## Consequences

- Most code previously written as GenServers becomes modules, Agents, Tasks, Registries, or ETS-backed code.
- Pure logic is testable in isolation without process setup.
- Operational surface area shrinks: fewer bespoke servers, fewer unnecessary mailbox-serialization points, and fewer supervision decisions.
- The GenServers that remain are load-bearing, and their presence signals genuine need.
- Engineers must be fluent in the full primitive ladder (module, Agent, Task, Registry, ETS, GenServer) rather than GenServer alone.


***

---
type: adr
id: 2
title: Own State in the Process; Separate Transitions From Server Mechanics
status: accepted
date: 2026-04-17
updated: 2026-08-09
tags: [elixir, otp, genserver, architecture, state-ownership, testing]
description: "The process owns its state and the non-interleaving application of transitions against it. A process API publishes transitions and queries, never `get_state`, `replace_state`, or `update_state`, which turn one process-owned transition into a caller-side read-modify-write. Every GenServer splits into three modules across three files (API, Server, Impl), where Impl holds the subsystem's state transitions and policy, vendor translation, persistence, and lifecycle-and-correlation live in named sibling modules that each take the slice of state they own."
---

# ADR-002: Own State in the Process; Separate Transitions From Server Mechanics

## Context

A GenServer exists to own a process-local lifecycle and serialize its own message handling. Each callback runs to completion before that process handles the next message, so state transitions applied inside one callback do not interleave with other callbacks in the same process. It does not create a transaction with ETS or another resource, and messages from different senders do not acquire a universal total order before they arrive. This process-local non-interleaving is the property relevant to this decision; ADR-001 carries the other reasons to choose a process, including exclusive ownership and long-lived coordination.

It gets given away in two places. The first is the API. A server that exposes `get_state`, `replace_state`, or `update_state` has published its state instead of its transitions: the caller reads, decides, and writes back, three steps spread across two messages, with every other message in the mailbox eligible to run in between. The second is the layout. A GenServer written as one module combines the public API, the server mechanics, and the state transitions, so transitions can only be exercised by starting a process, and callers are coupled to the decision to use a process at all.

The fix for the second is a three-module split across three files: an API module that is the boundary of the domain, a Server module that holds callbacks and nothing else, and an Impl module that takes explicit state and returns a new one. `Impl` is not "where the business logic goes." A destination with no admission criteria collects everything, because nothing in the design named a better home: the eligibility rule, the HTTP call to the vendor, the write to the durable store, the timer arming, all in one file. `Impl` holds the subsystem's state transitions. Policy, vendor translation, persistence, and lifecycle-and-correlation each get a named sibling module under the subsystem namespace, so "not Impl" has an answer.

## Decision

The process owns its state and the order of transitions against it. The API publishes transitions, never state. Every GenServer splits into three modules across three files, and `Impl` holds the transitions rather than everything else. The blocks below are reduced to the layout under discussion: opts reach `start_link/1` already validated against a declarative schema per ADR-007 Rule 2, and the registered name arrives in them per ADR-007 Rule 1.

### Rule 1: The process owns its state, the order of transitions, and their lifecycle

A process API exposes transitions and queries. `get_state`, `replace_state`, and `update_state` are not part of any process's API, in production code or in test support. A caller that needs a state change asks for the change by name and receives its result.

**Correct:**

```elixir
# lib/my_app/inventory.ex - the API publishes the transition, not the state
@spec reserve(GenServer.server(), Stock.sku(), pos_integer()) ::
        ErrorMessage.t_res(Reservations.id())
def reserve(server, sku, qty), do: GenServer.call(server, {:reserve, sku, qty})

# lib/my_app/inventory/server.ex - the deduction and the ledger write land in one callback
@impl true
def handle_call({:reserve, sku, qty}, _from, state) do
  {result, new_state} = Impl.reserve(state, sku, qty)
  {:reply, result, new_state}
end
```

**Wrong:**

```elixir
# lib/my_app/inventory.ex - state published instead of transitions
def get_state(server), do: GenServer.call(server, :get_state)

def update_state(server, fun), do: GenServer.call(server, {:update_state, fun})

# lib/my_app/checkout.ex - the transition is now assembled at the call site, out
# of two messages, with the whole mailbox eligible to run between them
def reserve(server, sku, qty) do
  state = Inventory.get_state(server)

  case Stock.reserve(state.deps.stock_table, sku, qty) do
    :ok ->
      {id, reservations} = Reservations.open(state.reservations, sku, qty)
      Inventory.update_state(server, &%State{&1 | reservations: reservations})

      {:ok, id}

    {:error, %ErrorMessage{}} = error ->
      error
  end
end
```

**Why:** A GenServer completes one callback before handling its next message, so the ledger transition in Correct cannot interleave with another Inventory callback. `get_state/1` and `update_state/2` split that transition across two messages. Two callers can each derive a ledger from stale state, then install those derived values after the process has moved on, causing one hold to disappear from the ledger. Lifecycle follows execution context too: if caller-side code invokes a transition that arms a timer with `self()`, the timer targets that caller rather than the owning server.

`Stock.reserve/3` supplies a separate guarantee: it performs one conditional mutation of one ETS object atomically for writers using that protocol. Combining it with a serialized callback does not create rollback, durability, or one atomic commit across ETS and process state. A process crash after the ETS mutation but before the new state becomes current can still leave the two resources inconsistent. When a fact must survive crashes, make retries unambiguous, coordinate multiple writers, or become visible through one committed boundary, perform it in a datastore operation whose isolation and durability guarantees fit the application rather than reconstructing that datastore from GenServer state and ETS.

`replace_state` carries another defect on top of the stale-ledger race: it installs a state value that no transition produced, so every caller must preserve process invariants by hand.

### Rule 2: Three modules per GenServer, each in its own file

The file layout mirrors the module path. The domain lives in a directory; the API module sits next to that directory as the boundary callers depend on. The Rule 3 siblings live in the same directory and are an architectural dependency boundary: production callers outside the subsystem do not depend on them, even though Elixir does not enforce module privacy.

```
lib/my_app/
├── inventory.ex     # MyApp.Inventory        (API, the boundary callers depend on)
└── inventory/
    ├── server.ex    # MyApp.Inventory.Server (GenServer callbacks)
    ├── impl.ex      # MyApp.Inventory.Impl   (state transitions, no GenServer awareness)
    ├── state.ex     # MyApp.Inventory.State  (the process state struct)
    ├── config.ex, deps.ex   # derived configuration, injected collaborators (ADR-012 Rule 2)
    └── stock.ex, policy.ex, warehouse.ex, journal.ex, reservations.ex   (Rule 3)
```

**Correct:**

```elixir
# lib/my_app/inventory.ex - the boundary callers depend on
defmodule MyApp.Inventory do
  alias MyApp.Inventory.{Reservations, Server, Stock}

  defdelegate start_link(opts), to: Server

  @spec reserve(GenServer.server(), Stock.sku(), pos_integer()) ::
          ErrorMessage.t_res(Reservations.id())
  def reserve(server, sku, qty), do: GenServer.call(server, {:reserve, sku, qty})
end

# lib/my_app/inventory/server.ex - callbacks and nothing else
defmodule MyApp.Inventory.Server do
  use GenServer

  alias MyApp.Inventory.{Impl, State}

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{name: _name} = opts), do: start(opts)

  defp start(%{name: nil} = opts),
    do: GenServer.start_link(__MODULE__, opts)

  defp start(%{name: name} = opts),
    do: GenServer.start_link(__MODULE__, opts, name: name)

  @impl true
  def init(opts), do: {:ok, State.new(opts)}

  @impl true
  def handle_call({:reserve, sku, qty}, _from, state) do
    {result, new_state} = Impl.reserve(state, sku, qty)
    {:reply, result, new_state}
  end
end

# lib/my_app/inventory/impl.ex - a value in, a value out, no process required
defmodule MyApp.Inventory.Impl do
  alias MyApp.Inventory.{Reservations, State, Stock}

  @spec reserve(State.t(), Stock.sku(), pos_integer()) ::
          {ErrorMessage.t_res(Reservations.id()), State.t()}
  def reserve(%State{} = state, sku, qty) do
    case Reservations.ensure_admission(state.reservations) do
      :ok -> reserve_stock(state, sku, qty)
      {:error, %ErrorMessage{}} = error -> {error, state}
    end
  end

  defp reserve_stock(%State{} = state, sku, qty) do
    case Stock.reserve(state.deps.stock_table, sku, qty) do
      :ok ->
        {id, reservations} = Reservations.open(state.reservations, sku, qty)

        {{:ok, id}, %State{state | reservations: reservations}}

      {:error, %ErrorMessage{}} = error ->
        {error, state}
    end
  end
end
```

**Wrong:**

```elixir
# lib/my_app/inventory.ex - API, callbacks, and the transition in one module
defmodule MyApp.Inventory do
  use GenServer

  alias MyApp.Inventory.{Reservations, State, Stock}

  def start_link(%{name: name} = opts), do: GenServer.start_link(__MODULE__, opts, name: name)

  def reserve(server, sku, qty), do: GenServer.call(server, {:reserve, sku, qty})

  @impl true
  def init(opts), do: {:ok, State.new(opts)}

  @impl true
  def handle_call({:reserve, sku, qty}, _from, state) do
    case Stock.reserve(state.deps.stock_table, sku, qty) do
      :ok ->
        {id, reservations} = Reservations.open(state.reservations, sku, qty)

        {:reply, {:ok, id}, %State{state | reservations: reservations}}

      {:error, %ErrorMessage{}} = error ->
        {:reply, error, state}
    end
  end
end
```

**Why:** `use GenServer` injects `child_spec/1` plus public default implementations of `handle_call/3`, `handle_cast/2`, `handle_info/2`, `terminate/2`, and `code_change/3` into the module that invokes it. In the Wrong version that module is `MyApp.Inventory`, so the one module callers alias exports the domain functions and OTP callback set from a single namespace. Putting `use GenServer` in `Server` makes the intended dependency boundary visible. The other half of the split is reachability: a callback body runs only through a live process, while `Impl.reserve/3` accepts and returns values, so genuine transitions can be tested directly over a State and injected table. Lifecycle behavior still belongs in tests against the real process. The API localizes caller dependencies when the concurrency primitive changes; such a change may still require coordinated internal edits or an intentional semantic change, but callers do not depend on callback modules or message tags.

### Rule 3: An Impl function orchestrates; it does not implement what it calls

An `Impl` function takes the state, sequences the collaborators a use case needs, and returns the new state with a result. It is a controller. It owns the order of the steps, the success and failure conditions, and the point at which a proposed transition becomes the current state. Sequencing several collaborators in one function is what `Impl` is for.

Two questions decide whether code belongs in `Impl`:

1. **Does it take the state and return the state?** A function that never touches the state is not an `Impl` function.
2. **Does it call the behavior, or contain it?** `Impl` calls the eligibility rule; it does not encode the rule. It calls the port; it does not know the vendor's field names. It calls the store; it does not know the key format. It asks for a timer; it does not carry the correlation bookkeeping.

Each collaborator lives in its own module under the subsystem namespace and receives the slice of state it owns rather than the whole `State`. Collaborators an `Impl` function sequences include policy (business decisions, calculations, eligibility, validation), vendor translation ((de)serialization between internal and external models), persistence (durable-store mechanics, keys, serialization, recovery), and lifecycle and correlation (timers, monitors, task references, generation fencing, stale-result rejection, restart resumption).

Module placement assigns responsibility; the invocation protocol determines where code executes. A synchronous call from `Impl` to a sibling still runs in the GenServer callback and must be bounded. Anything that reaches the network or disk is dispatched through ADR-005's mechanisms, whose results return to the process as messages. Moving the function into `Warehouse` or `Journal` without changing how it is invoked does not move work off the loop. Dispatching it does not erase outcome ownership: idempotency, recovery, reconciliation, or compensation still follows from the effect and the application's guarantees.

**Correct:**

```elixir
# lib/my_app/inventory/impl.ex - the transition, and only the transition
@spec reserve(State.t(), Stock.sku(), pos_integer()) ::
        {ErrorMessage.t_res(Reservations.id()), State.t()}
def reserve(%State{} = state, sku, qty) do
  case Reservations.ensure_admission(state.reservations) do
    :ok -> reserve_sellable(state, sku, qty)
    {:error, %ErrorMessage{}} = error -> {error, state}
  end
end

defp reserve_sellable(%State{} = state, sku, qty) do
  case place(state.config, state.deps.stock_table, sku, qty) do
    :ok ->
      {id, reservations} = Reservations.open(state.reservations, sku, qty)

      {{:ok, id}, %State{state | reservations: reservations}}

    {:error, %ErrorMessage{}} = error ->
      {error, state}
  end
end

# Policy judges the slice it is handed; Stock owns the one row it changes.
# Warehouse and Journal are absent: they reach the network and the disk.
defp place(%Config{} = config, table, sku, qty) do
  case Policy.sellable(config, sku, qty) do
    :ok -> Stock.reserve(table, sku, qty)
    {:error, %ErrorMessage{}} = error -> error
  end
end
```

**Wrong:**

```elixir
# lib/my_app/inventory/impl.ex - one function holding a domain decision, a vendor
# call, a durable write, a timer, and the transition
@sellable_fraction 0.9
@ttl_ms 60_000
@endpoint "https://wms.example.com/reservations"

def reserve(%State{} = state, sku, qty) do
  [{^sku, available}] = :ets.lookup(state.deps.stock_table, sku)

  if qty > trunc(available * @sellable_fraction) do
    {{:error, ErrorMessage.conflict("Above the sellable ceiling", %{sku: sku})}, state}
  else
    case Req.post(@endpoint, json: %{"sku" => sku, "units" => qty}) do
      {:ok, %Req.Response{status: 201, body: %{"reservation_id" => id}}} ->
        :ets.insert(state.deps.stock_table, {sku, available - qty})
        :dets.insert(:inventory_journal, {id, sku, qty, DateTime.utc_now()})
        Process.send_after(self(), {:expire, id}, @ttl_ms)
        entries = Map.put(state.reservations.entries, id, {sku, qty})
        held = %Reservations{state.reservations | entries: entries}

        {{:ok, id}, %State{state | reservations: held}}

      {:ok, %Req.Response{status: status}} ->
        {{:error, ErrorMessage.conflict("Warehouse rejected", %{status: status})}, state}

      {:error, _reason} ->
        {{:error,
          ErrorMessage.service_unavailable(
            "Warehouse unavailable",
            %{operation: :reserve_stock}
          )}, state}
    end
  end
end
```

**Why:** `Process.send_after/3` sends to the process named by its first argument, and `Reservations` names `self()`, so the expiry timers it arms are invocable only from the owning process, and a test that calls `Reservations.open/3` directly gets `{:expire, id}` in its own mailbox. That single mechanism sorts the subsystem, because no other collaborator carries that constraint and each has a different reason to change. `Policy` is a pure function of values, so its tests are input and output over `Config` and scalars, with no whole State, process, or stub. `Stock` is the only module that knows the table's key format and the single atomic operation that changes a row, so a deduction against a shared store stays one operation instead of becoming a read and a later write (ADR-003 Rule 1). `Warehouse` is the port where the vendor's external model stops, so it is the only module that changes when the vendor renames `"reservation_id"`, and because it speaks HTTP it is driven from a task whose result returns to the process as a message (ADR-004 Rule 1, ADR-005 Rules 2 and 5) rather than from inside a transition. `Journal` owns keys, serialization, and recovery, so swapping the durable store is one file. The Wrong version welds all five fates together: the ceiling rule cannot be exercised without stubbing an HTTP call, the vendor's wire keys are read inside the transition, the callback blocks the loop on a network round trip and a disk write (ADR-004 Rule 1), and `:dets.insert/2`'s return value is discarded, so a failed journal write after `Req.post/2` returned 201 permits the callback to return success with no durable record and no defined compensation or reconciliation path (`elixir-conventions` ADR-007 Rule 1). It also reaches the table twice, with a `lookup` that decides and an `insert` that writes, and the table is shared, so a writer outside this process lands between them and its decrement is overwritten: the oversell that ADR-003 Rule 1's single `select_replace/2` exists to prevent. The slice is the same rule stated at the signature: `Policy.sellable(Config.t(), ...)` cannot read `reservations`, cannot reach the table, cannot arm a timer, and cannot be broken by a field added to `State`, because it never receives one, and its test passes a `Config` carrying a ceiling rather than a whole process state. `Impl` is the exception because it coordinates and recombines the concern sub-structs touched by one transition under the whole State.

### Rule 4: Impl speaks in values, not GenServer callback tuples

`Impl` takes explicit state and returns a result paired with a new state. It does not call `GenServer.reply/2`, does not return GenServer callback tuples (`{:reply, _, _}`, `{:noreply, _}`), and does not pattern match on `from`. The constraint is on callback vocabulary, not on effects.

**Correct:**

```elixir
# lib/my_app/inventory/impl.ex
alias MyApp.Inventory.Reservation

@spec expire(State.t(), Reservations.id()) :: State.t()
def expire(%State{} = state, id) do
  case Reservations.take(state.reservations, id) do
    {nil, _reservations} ->
      state

    {%Reservation{sku: sku, quantity: quantity}, reservations} ->
      Stock.restock(state.deps.stock_table, sku, quantity)

      %State{state | reservations: reservations}
  end
end
```

**Wrong:**

```elixir
# lib/my_app/inventory/impl.ex - callback tuples and a `from`, which weld Impl to
# the callback it happens to be invoked from
alias MyApp.Inventory.Reservation

def expire(%State{} = state, id, from) do
  case Reservations.take(state.reservations, id) do
    {nil, _reservations} ->
      {:reply, {:error, ErrorMessage.not_found("Unknown reservation", %{id: id})}, state}

    {%Reservation{sku: sku, quantity: quantity}, reservations} ->
      GenServer.reply(from, :ok)
      Stock.restock(state.deps.stock_table, sku, quantity)

      {:noreply, %State{state | reservations: reservations}}
  end
end
```

**Why:** `from` is the OTP request token normally supplied to `handle_call/3`, so accepting it welds `Impl` to that callback protocol and removes the direct function-level test. Returning callback tuples has a second effect: the Wrong version answers the caller two different ways depending on the branch, once through `GenServer.reply/2` and once through `{:reply, _, _}`, so the Server can no longer tell from the return value whether a reply was already sent. Effects are a separate question and are not what this rule restricts. A synchronously invoked `Impl` and its siblings run inside the owning process, so `self()` is the server; reading or writing the table, emitting telemetry, or arming a timer may be legitimate there when bounded. Rule 3 decides which module owns those responsibilities; this rule decides only that the transition does not speak GenServer.

### Rule 5: Domain-transition callbacks are thin dispatchers

Each callback applying a domain transition calls one `Impl` function and wraps the result in the appropriate GenServer return tuple. No domain transition or business decision belongs in the callback body. `Server` still owns bounded OTP mechanics that are not value-level transitions: initialization, task admission, monitoring, correlation, readiness, and replies.

**Correct:**

```elixir
# lib/my_app/inventory/server.ex
@impl true
def handle_call({:reserve, sku, qty}, _from, state) do
  {result, new_state} = Impl.reserve(state, sku, qty)
  {:reply, result, new_state}
end

@impl true
def handle_info({:expire, id}, state), do: {:noreply, Impl.expire(state, id)}
```

**Wrong:**

```elixir
# lib/my_app/inventory/server.ex
@impl true
def handle_call({:reserve, sku, qty}, _from, %State{} = state) do
  case :ets.lookup(state.deps.stock_table, sku) do
    [{^sku, available}] when available >= qty ->
      :ets.insert(state.deps.stock_table, {sku, available - qty})
      {id, held} = Reservations.open(state.reservations, sku, qty)

      {:reply, {:ok, id}, %State{state | reservations: held}}

    _rows ->
      {:reply, {:error, ErrorMessage.conflict("Insufficient stock", %{sku: sku})}, state}
  end
end
```

**Why:** A callback body is reachable only by sending the process a message, so every direct assertion about the transition in Wrong needs process setup and a round trip, then tempts the test toward a private getter or `:sys.get_state/2`. Correct makes the actual transition callable with values. Lifecycle behavior (admission, task failure, timer correlation, reply ownership, restart) remains tested through the real process rather than being forced into a fake value-level transition. The Wrong body also decides against the table in two operations, a `lookup` and an `insert`, which ADR-003 rejects independently of layout: moving it into `Impl` unchanged would fix the file boundary and preserve the oversell.

### Rule 6: Callers depend on the API module, not the Server

The API module is the boundary of the domain. Production callers alias it and call it. `MyApp.Inventory.Server` and `MyApp.Inventory.Impl` are implementation details by architectural convention, not inaccessible Elixir modules; production code outside the subsystem does not depend on them.

**Correct:**

```elixir
# anywhere in lib/my_app/...
alias MyApp.Inventory

Inventory.reserve(server, "sku-1", 3)
```

**Wrong:**

```elixir
# call site reaching past the boundary into the Server
GenServer.call(MyApp.Inventory.Server, {:reserve, "sku-1", 3})
```

**Why:** `GenServer.call/3` resolves its first argument to a process: an atom through the local name registry or a `{:via, module, term}` tuple through the named registry module. `MyApp.Inventory.Server` is a module atom, while ADR-007 requires production identity to arrive in opts and ordinary tests to use unregistered PIDs, so the Wrong call commonly names no process and exits with `:noproc`. Where it does resolve, it publishes both the existence of the process and the wire format of its messages. `{:reserve, sku, qty}` becomes a caller contract, and replacing the process or changing that protocol becomes a call-site migration. It also bypasses the API module's declared result contract.

## Consequences

- No process API has a generic state accessor. Every public function names a transition or a query, and no caller can assemble a transition out of two calls.
- What the process owns is the ledger of work it is currently coordinating, and its callbacks apply ledger transitions without interleaving. Data sized by the catalogue lives in a shared store reached through `deps` (ADR-003 Rule 1). A conditional store mutation and a process-state transition remain separate guarantees, not one transaction.
- Genuine transition tests run directly against `Impl` and sub-state modules with explicit values. Process-level tests cover dispatch, startup, admission, replies, `handle_info`, correlation, timers, monitors, and restart: the behavior that actually needs a process.
- Policy, vendor translation, persistence, and lifecycle work have named destinations under the subsystem namespace, so "where does this go" has an answer that is not `Impl`. Each takes the slice it owns, so its test fixtures are small and a new field on the state struct does not widen what it can touch.
- Transitions perform no network calls and no disk writes, because siblings that do those are invoked off the loop per ADR-005. Off-loop execution preserves responsiveness; it does not remove idempotency, recovery, reconciliation, or compensation responsibilities for accepted external effects.
- Moving a domain between a GenServer and a simpler primitive keeps caller dependencies localized at the API layer. Internal wiring and semantics may still require coordinated changes, but message tags and callback modules do not leak across the codebase.


***

---
type: adr
id: 3
title: Keep GenServer State Small; Push Storage Out of Process
status: accepted
date: 2026-04-18
updated: 2026-08-09
tags: [elixir, otp, genserver, performance, state, gc]
description: "Garbage collection on the BEAM is proportional to the live data on the heap being collected, and the callers of a GenServer wait through that collection. Keep a value in process state only when an invariant the mailbox serializes requires the process to own it and its size is independent of usage. A per-aggregate collection inside a singleton is storage even when every entry is individually capped."
---

# ADR-003: Keep GenServer State Small; Push Storage Out of Process

## Context

Each Erlang process has its own stack and heap, allocated in the same memory block and growing toward each other. The collector is a copying semi-space collector: terms are copied from the *from space* to a clean *to space*, and "the garbage collection algorithm used is proportional to the amount of live data on the heap" (erlang.org, `erts` Garbage Collection). It is generational, so a term that survives collections is copied to the old heap and subsequent minor collections ignore pointers into it, while a fullsweep includes both generations and traverses and copies all live on-heap terms and references. Large reference-counted binary payloads stay off heap; the process still carries the references to them. A GenServer holding bulk data pays that cost on its own process: the scheduler running the process runs the collection, and no message in the mailbox is served while it does. The blame surfaces as tail latency on whichever endpoint happened to be waiting, not as a whole-system slowdown, which is what makes it hard to attribute.

Coordination and storage are not mutually exclusive. A process that exists to serialize a state transition owns the state that transition covers: when two callers must not interleave a read and a write, the mailbox is the mechanism that stops them, and moving that state to a store with concurrent writers deletes the guarantee. The question is never whether a GenServer stores anything. It is whether a specific value is covered by an invariant the mailbox enforces, and whether the size of that value is independent of how much the system is used. Bounded does not mean small. A singleton sits on the path of every caller, so its collection pause is added to the latency of every request that touches it, and a collection whose size scales with the number of aggregates the process coordinates is external storage even when each entry is individually capped, because the bound that matters is on the heap, not on one entry.

## Decision

Keep a value in process state only when an invariant the mailbox serializes requires the process to own it and its size is independent of usage. Three shapes qualify: state covered by an invariant the mailbox serializes, derived state that is read on every message and whose shape does not change as the store grows, and fixed-shape values (flags, counters, timer references, the identity the process was started with). Everything else is storage and lives outside the process.

### Rule 1: Keep data whose size grows with usage out of the process

If the state contains data that grows with usage (entries accumulated over time, caches, batches, event history, a full catalog loaded at boot), that data lives in a store. What stays in the process is bounded coordination state: admission has a fixed limit, every admitted entry is removed on success, domain failure, task crash, timeout, or cancellation, and failed admission creates no entry. A TTL can clean up abandoned entries, but it is not a cardinality bound.

**Correct:**

```elixir
# lib/my_app/inventory/recounts.ex
defmodule MyApp.Inventory.Recounts do
  alias MyApp.Inventory.Stock

  @enforce_keys [:limit]
  defstruct [:limit, by_ref: %{}, by_sku: %{}]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          by_ref: %{optional(reference()) => Stock.sku()},
          by_sku: %{optional(Stock.sku()) => reference()}
        }

  @spec new(pos_integer()) :: t()
  def new(limit) when is_integer(limit) and limit > 0, do: %__MODULE__{limit: limit}

  @spec ensure_admission(t(), Stock.sku()) :: ErrorMessage.t_ok_res()
  def ensure_admission(%__MODULE__{} = recounts, sku) do
    if Map.has_key?(recounts.by_sku, sku) or map_size(recounts.by_ref) < recounts.limit do
      :ok
    else
      {:error,
       ErrorMessage.service_unavailable("Recount capacity reached", %{operation: :recount})}
    end
  end

  @spec track(t(), Stock.sku(), reference()) ::
          {:ok, reference() | nil, t()} | {:error, ErrorMessage.t()}
  def track(%__MODULE__{} = recounts, sku, ref) when is_reference(ref) do
    case ensure_admission(recounts, sku) do
      :ok ->
        superseded_ref = ref_for(recounts, sku)
        recounts = if superseded_ref, do: delete(recounts, superseded_ref), else: recounts

        {:ok, superseded_ref,
         %__MODULE__{
           recounts
           | by_ref: Map.put(recounts.by_ref, ref, sku),
             by_sku: Map.put(recounts.by_sku, sku, ref)
         }}

      {:error, %ErrorMessage{}} = error ->
        error
    end
  end

  @spec ref_for(t(), Stock.sku()) :: reference() | nil
  def ref_for(%__MODULE__{} = recounts, sku), do: Map.get(recounts.by_sku, sku)

  @spec sku_for(t(), reference()) :: Stock.sku() | nil
  def sku_for(%__MODULE__{} = recounts, ref), do: Map.get(recounts.by_ref, ref)

  @spec pop(t(), reference()) :: {{Stock.sku(), reference()} | nil, t()}
  def pop(%__MODULE__{} = recounts, ref) do
    case Map.pop(recounts.by_ref, ref) do
      {nil, _by_ref} ->
        {nil, recounts}

      {sku, by_ref} ->
        {{sku, ref},
         %__MODULE__{recounts | by_ref: by_ref, by_sku: Map.delete(recounts.by_sku, sku)}}
    end
  end

  @spec delete(t(), reference()) :: t()
  def delete(%__MODULE__{} = recounts, ref) do
    {_entry, recounts} = pop(recounts, ref)
    recounts
  end
end

# Focused Rule-1 excerpt of lib/my_app/inventory/state.ex, showing only the
# bounded ledger concerns. ADR-012 Rule 3 owns the complete canonical State and
# constructor, including the unarmed Sweeper concern. Here Config and Deps come
# from the same validated opts (Deps: defstruct [:stock_table, :task_supervisor];
# Config includes :max_reservations and :max_recounts).
defmodule MyApp.Inventory.State do
  alias MyApp.Inventory.{Config, Deps, Recounts, Reservations}

  @enforce_keys [:name, :config, :deps, :reservations, :recounts]
  defstruct [:name, :config, :deps, :reservations, :recounts]

  @type t :: %__MODULE__{
          name: GenServer.name() | nil,
          config: Config.t(),
          deps: Deps.t(),
          reservations: Reservations.t(),
          recounts: Recounts.t()
        }

  @spec new(map()) :: t()
  def new(%{name: name} = opts) do
    config = Config.from(opts)

    %__MODULE__{
      name: name,
      config: config,
      deps: Deps.from(opts),
      reservations: Reservations.new(config.max_reservations),
      recounts: Recounts.new(config.max_recounts)
    }
  end
end

# lib/my_app/inventory/stock.ex
defmodule MyApp.Inventory.Stock do
  @type sku :: String.t()

  @spec reserve(:ets.table(), sku(), pos_integer()) :: ErrorMessage.t_ok_res()
  def reserve(table, sku, qty) do
    # Match {sku, count} where count >= qty, replace with {sku, count - qty}.
    match_spec = [{{sku, :"$1"}, [{:>=, :"$1", qty}], [{{sku, {:-, :"$1", qty}}}]}]

    case :ets.select_replace(table, match_spec) do
      1 -> :ok
      0 -> {:error, ErrorMessage.conflict("Stock unavailable", %{sku: sku, requested: qty})}
    end
  end
end
```

```elixir
# lib/my_app/inventory/impl.ex
@spec reserve(State.t(), Stock.sku(), pos_integer()) ::
        {ErrorMessage.t_res(Reservations.id()), State.t()}
def reserve(%State{} = state, sku, qty) do
  case Reservations.ensure_admission(state.reservations) do
    :ok -> reserve_stock(state, sku, qty)
    {:error, %ErrorMessage{}} = error -> {error, state}
  end
end

defp reserve_stock(%State{} = state, sku, qty) do
  case Stock.reserve(state.deps.stock_table, sku, qty) do
    :ok ->
      {id, reservations} = Reservations.open(state.reservations, sku, qty)

      {{:ok, id}, %State{state | reservations: reservations}}

    {:error, %ErrorMessage{}} = error ->
      {error, state}
  end
end

@spec confirm(State.t(), Reservations.id()) :: {ErrorMessage.t_ok_res(), State.t()}
def confirm(%State{} = state, id) do
  case Reservations.take(state.reservations, id) do
    {nil, _reservations} ->
      {{:error, ErrorMessage.not_found("Unknown reservation", %{reservation_id: id})}, state}

    {_entry, reservations} ->
      {:ok, %State{state | reservations: reservations}}
  end
end
```

**Wrong:**

```elixir
# lib/my_app/inventory/state.ex
defmodule MyApp.Inventory.State do
  alias MyApp.Inventory.Reservations

  @enforce_keys [:name, :stock, :reservations]
  defstruct [:name, :stock, :reservations, history: []]

  @type t :: %__MODULE__{
          name: GenServer.name(),
          stock: %{optional(String.t()) => non_neg_integer()},
          reservations: Reservations.t(),
          history: [{Reservations.id(), String.t(), pos_integer(), DateTime.t()}]
        }
end
```

```elixir
# lib/my_app/inventory/impl.ex
@spec record(State.t(), String.t(), pos_integer()) :: {Reservations.id(), State.t()}
def record(%State{} = state, sku, qty) do
  {id, reservations} = Reservations.open(state.reservations, sku, qty)

  {id,
   %State{
     state
     | stock: Map.update!(state.stock, sku, &(&1 - qty)),
       reservations: reservations,
       history: [{id, sku, qty, DateTime.utc_now()} | state.history]
   }}
end
```

**Why:** In the wrong version, the catalog and every reservation ever made are live on the server's heap for the process's lifetime. Collection cost is proportional to live data, so growing history raises full-sweep cost, and `history` is never reclaimed at all: it survives into the old heap and every full sweep traverses and copies its live on-heap terms and references. The process is scheduled out while that runs and serves nothing from its mailbox, so the pause lands on whichever caller is waiting. In the correct version, the counters live in a table; an ETS insert copies the object out of the writer's heap into table memory and a lookup copies it back into the reader's, so neither lands on the server's heap, and callers reading stock never enter the server's mailbox at all. `reservations` and `recounts` have application-defined admission limits and terminal cleanup, so their cardinality is bounded independently of total usage. The single `select_replace/2` makes the conditional decrement atomic and isolated for one ETS object among writers that use this protocol. It is not a transaction with `reservations`, `recounts`, or any other process state. ETS guarantees that "all updates to single objects are guaranteed to be both atomic and isolated" (erlang.org, `stdlib` ets), and `select_replace/2` requires the replacement to carry the same key as the matched object. A `lookup` followed by an `insert` is two operations, and the calling process can be scheduled out between them, so two concurrent reservers can read the same count and both write it: the stock is oversold, and neither call failed. If one invariant spans several objects or stores, it needs a layout, owner, conditional write, lock, transaction, or datastore that supplies that wider guarantee.

### Rule 2: Separate working state from configuration state

Configuration is what the server was booted with. Working state is what changes as the server runs. Derive every configuration value in a `Config` struct built once where the state is constructed, and hold it on a named field, so no callback ever re-derives it. ADR-012 Rule 2 (group configuration, injected collaborators, and working state separately) covers the grouping itself; this rule is about when the derivation happens and what skipping it costs.

**Correct:**

```elixir
# lib/my_app/rate_limiter/config.ex
defmodule MyApp.RateLimiter.Config do
  @enforce_keys [:window_ms, :max_requests]
  defstruct [:window_ms, :max_requests]

  @type t :: %__MODULE__{window_ms: pos_integer(), max_requests: pos_integer()}

  @spec from(map()) :: t()
  def from(%{window: window, max_requests: max_requests}) do
    {seconds, "s"} = Integer.parse(window)
    %__MODULE__{window_ms: :timer.seconds(seconds), max_requests: max_requests}
  end
end

# lib/my_app/rate_limiter/state.ex, over a Deps built from the same validated opts:
# defstruct [:counter_table]
defmodule MyApp.RateLimiter.State do
  alias MyApp.RateLimiter.{Config, Deps}

  @enforce_keys [:config, :deps]
  defstruct [:config, :deps, in_flight: %{}]

  @type t :: %__MODULE__{
          config: Config.t(),
          deps: Deps.t(),
          in_flight: %{optional(reference()) => pos_integer()}
        }

  @spec new(map()) :: t()
  def new(opts), do: %__MODULE__{config: Config.from(opts), deps: Deps.from(opts)}
end
```

**Wrong:**

```elixir
# lib/my_app/rate_limiter/state.ex
defmodule MyApp.RateLimiter.State do
  @enforce_keys [:window, :max_requests, :counter_table]
  defstruct [:window, :max_requests, :counter_table, in_flight: %{}]

  @type t :: %__MODULE__{
          window: String.t(),
          max_requests: pos_integer(),
          counter_table: atom(),
          in_flight: %{optional(reference()) => pos_integer()}
        }
end
```

```elixir
# lib/my_app/rate_limiter/impl.ex
@spec allow?(State.t(), String.t()) :: boolean()
def allow?(%State{} = state, key) do
  {seconds, "s"} = Integer.parse(state.window)
  Counter.within?(state.counter_table, key, :timer.seconds(seconds), state.max_requests)
end
```

**Why:** The correct version converts `"10s"` into an integer once, at construction. Because `config` survives the first collections, it is promoted to the old heap, which minor collections do not rescan, so a stable configuration stops being copied on the common path. A full sweep still copies it, so this is a reduction in how often the cost is paid, not an exemption from it. The wrong version keeps the duration as a string, so every message that needs a window calls `Integer.parse/1` again and allocates a fresh tuple on the young heap to recover a number that was fixed at boot. That does not increase useful live data; it increases the rate at which the young heap fills, so the process collects more often for nothing. The derivation site matters as much as the allocation: `Config.from/1` is the one place a duration becomes milliseconds, so two callbacks cannot disagree about what `"10s"` meant, and a field whose value is a function of opts is visibly one that `init/1` rebuilds after a restart rather than one a message wrote.

### Rule 3: Treat a singleton's per-aggregate collection as storage

A map or list keyed by aggregate (user, tenant, connection, device, job) inside a single named process is storage, not coordination state, even when each entry is a fixed handful of words. It moves to a table keyed by the same aggregate. The process keeps the lifecycle it actually owns: timers, generations, in-flight references.

**Correct:**

```elixir
# lib/my_app/presence.ex
@spec touch(:ets.table(), String.t()) :: :ok
def touch(table, user_id) do
  touch_max(table, user_id, System.monotonic_time(:millisecond))
end

defp touch_max(table, user_id, now_ms) do
  if :ets.insert_new(table, {user_id, now_ms}) do
    :ok
  else
    replace_older = [{{user_id, :"$1"}, [{:<, :"$1", now_ms}], [{{user_id, now_ms}}]}]

    case :ets.select_replace(table, replace_older) do
      1 ->
        :ok

      0 ->
        case :ets.lookup(table, user_id) do
          [{^user_id, stored_ms}] when stored_ms >= now_ms -> :ok
          _deleted_or_older -> touch_max(table, user_id, now_ms)
        end
    end
  end
end

# lib/my_app/presence/state.ex, over a Config and a Deps built from the same validated opts:
# Config: defstruct [:sweep_interval_ms]. Deps: defstruct [:table, :sweeper].
defmodule MyApp.Presence.State do
  alias MyApp.Presence.{Config, Deps}

  @enforce_keys [:config, :deps]
  defstruct [:config, :deps, sweep_timer: nil, sweep_task: nil, sweep_pending?: false]

  @type t :: %__MODULE__{
          config: Config.t(),
          deps: Deps.t(),
          sweep_timer: reference() | nil,
          sweep_task: Task.t() | nil,
          sweep_pending?: boolean()
        }

  @spec new(map()) :: t()
  def new(opts), do: %__MODULE__{config: Config.from(opts), deps: Deps.from(opts)}
end
```

```elixir
# lib/my_app/presence/server.ex
@impl true
def handle_info({:timeout, timer_ref, :sweep}, %State{} = state),
  do: {:noreply, Impl.sweep_tick(state, timer_ref)}

def handle_info({ref, result}, %State{} = state) when is_reference(ref),
  do: {:noreply, Impl.finish_sweep(state, ref, result)}

def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state)
    when is_reference(ref),
    do: {:noreply, Impl.sweep_down(state, ref, reason)}

# lib/my_app/presence/impl.ex
@spec arm_sweep(State.t()) :: State.t()
def arm_sweep(%State{} = state) do
  timer_ref = :erlang.start_timer(state.config.sweep_interval_ms, self(), :sweep)
  %State{state | sweep_timer: timer_ref}
end

@spec sweep_tick(State.t(), reference()) :: State.t()
def sweep_tick(%State{sweep_timer: timer_ref} = state, timer_ref) do
  state = arm_sweep(%State{state | sweep_timer: nil})

  case state.sweep_task do
    nil -> start_sweep(state)
    %Task{} -> %State{state | sweep_pending?: true}
  end
end

def sweep_tick(%State{} = state, _stale_timer_ref), do: state

@spec finish_sweep(State.t(), reference(), ErrorMessage.t_res(non_neg_integer())) :: State.t()
def finish_sweep(%State{sweep_task: %Task{ref: ref}} = state, ref, result) do
  Process.demonitor(ref, [:flush])

  case result do
    {:ok, _deleted_count} -> finish_sweep_cycle(state)
    {:error, %ErrorMessage{}} -> finish_sweep_cycle(state)
  end
end

def finish_sweep(%State{} = state, _stale_ref, _result), do: state

@spec sweep_down(State.t(), reference(), term()) :: State.t()
def sweep_down(%State{sweep_task: %Task{ref: ref}} = state, ref, _reason),
  do: finish_sweep_cycle(state)

def sweep_down(%State{} = state, _stale_ref, _reason), do: state

defp finish_sweep_cycle(%State{sweep_pending?: true} = state),
  do: start_sweep(%State{state | sweep_task: nil, sweep_pending?: false})

defp finish_sweep_cycle(%State{} = state),
  do: %State{state | sweep_task: nil, sweep_pending?: false}

defp start_sweep(%State{} = state) do
  cutoff_ms = System.monotonic_time(:millisecond) - state.config.sweep_interval_ms
  table = state.deps.table

  try do
    task =
      Task.Supervisor.async_nolink(state.deps.sweeper, fn ->
        MyApp.Presence.Sweeper.delete_before(table, cutoff_ms)
      end)

    %State{state | sweep_task: task, sweep_pending?: false}
  rescue
    RuntimeError -> %State{state | sweep_task: nil, sweep_pending?: false}
  catch
    :exit, _reason -> %State{state | sweep_task: nil, sweep_pending?: false}
  end
end
```

**Wrong:**

```elixir
# lib/my_app/presence/state.ex
defmodule MyApp.Presence.State do
  @enforce_keys [:sweep_interval_ms]
  defstruct [:sweep_interval_ms, sweep_timer: nil, last_seen: %{}]

  @type t :: %__MODULE__{
          sweep_interval_ms: pos_integer(),
          sweep_timer: reference() | nil,
          last_seen: %{optional(String.t()) => integer()}
        }
end
```

```elixir
# lib/my_app/presence/impl.ex
@spec touch(State.t(), String.t(), integer()) :: State.t()
def touch(%State{} = state, user_id, now_ms) do
  %State{state | last_seen: Map.put(state.last_seen, user_id, now_ms)}
end

@spec sweep(State.t(), integer()) :: State.t()
def sweep(%State{} = state, cutoff_ms) do
  %State{
    state
    | last_seen: Map.filter(state.last_seen, fn {_id, ts} -> ts >= cutoff_ms end),
      sweep_timer: Process.send_after(self(), :sweep, state.sweep_interval_ms)
  }
end
```

**Why:** Every entry in `last_seen` is a binary key and an integer, so the per-entry bound is satisfied, and the field still fails the rule. Collection cost tracks live data on the heap, and `last_seen` is live for as long as the process runs, so its size is the size of the online population and every fullsweep traverses and copies all of its live terms. `Map.filter/2` compounds it: the sweep allocates a replacement map of nearly the same size on the young heap on every interval, so the collection rate is set by a number the process does not control. In the correct version, the entries are in a `:public` table and callers never enter the mailbox to record a heartbeat. Among writers using this protocol, the guarded max-upsert prevents an older concurrent touch from moving `last_seen` backward, and both touches and cutoffs use monotonic milliseconds. The sweep remains off the loop and is single-flight: correlated timer messages fence stale ticks, overlapping ticks coalesce, and task state clears after success, domain failure, failed admission, or abnormal `:DOWN`. A timeout or cancellation follows the same rule: demonitor and clear the accepted task before any replacement is admitted. One available alternative is a process per aggregate behind a `Registry`. More generally, an invariant spanning several fields or writers needs a layout, serialized owner, conditional write, lock, transaction, or datastore whose guarantees fit the application; a table plus compensation is not a substitute for concurrency control.

### Decision test

Ask these of each field before it goes into a state struct. One failing answer decides it.

1. **What invariant requires the process to own this value?** Name it. If the answer is that two callers must not interleave a read and a write on it, the mailbox is doing real work and the value stays. If the answer is that it was convenient to have on hand, it is storage.
2. **Does its size grow with total usage, or with the number of aggregates the process coordinates?** Either one is storage, and the second is storage even when every entry is individually capped. Work currently being coordinated stays only behind bounded admission and terminal cleanup; “in flight” alone is not a bound.
3. **Must another process read this value without sending a message to this one?** Reads that must not queue behind the mailbox belong in a table or a database, not in the state.
4. **What must be true about this value after the process restarts?** A value that must survive the restart belongs in a durable store, and the process rebuilds its working set from that store at init.
5. **Does moving it out split one transition into two?** If the transition becomes a read followed by a write, the store supplies the required concurrency guarantee through its layout, conditional writes, locking, transactions, or serialized ownership. If the guarantee spans processes, writers, nodes, crashes, or partitions, choose a datastore whose consistency and durability tradeoffs fit the application instead of rebuilding a weaker database protocol in GenServer and ETS state. Compensation applies only after one effect was accepted and a later effect failed; it is not concurrency control. A read-modify-write split across two calls to a shared store is a race, not a refactor.

## Consequences

- Most GenServer state shrinks to identity, configuration, and lifecycle references. The process stops dominating its own collection cost, and its callers stop absorbing a pause proportional to data they never asked for. Bulk reads are served in the calling process against a shared store, so they neither queue behind the mailbox nor contribute to the server's live heap.
- A singleton's tail latency stops scaling with the number of aggregates it coordinates. Growth shows up as store size, which is measurable directly, instead of as a collection pause attributed to whichever endpoint was unlucky. Sweeps and other whole-store traversals run off the loop, because moving the data out of the process does not by itself move the scan out of the callback.
- Configuration is derived once at init and settles into the old heap, so hot-path callbacks allocate only what the request itself needs and the young heap fills at the rate of real work.
- Every read-modify-write against a shared store uses a concurrency mechanism with the scope the invariant requires. Compensation is reserved for accepted partial effects followed by later failure; it does not repair concurrent writers racing through a split transition.


***

---
type: adr
id: 4
title: Never Block the GenServer Processing Loop
status: accepted
date: 2026-04-22
updated: 2026-08-09
tags: [elixir, otp, genserver, performance, callbacks]
description: GenServer callbacks handle one message at a time. Blocking I/O or unbounded computation in a callback stalls every other caller. Raising the call timeout papers over the problem instead of fixing it.
---

# ADR-004: Never Block the GenServer Processing Loop

## Context

A GenServer handles one message at a time. Every callback body runs to completion before the next message is pulled from the mailbox. Blocking operations inside a callback (HTTP calls, synchronous queries to a slow database, file reads of unknown size, any computation whose tail can be much longer than its median) stall every other caller.

The default `GenServer.call/2` timeout is 5000 ms. Raising the timeout or passing `:infinity` does not make the server faster. It makes failures louder and harder to bound. A stuck upstream becomes a stuck caller.

When this rule is violated at scale, the consequences cascade. The mailbox of a slow server grows with every queued call. Messages to that process default to living on the process heap, so per-process GC scans them and pauses scale with mailbox size. `process_info` calls against long mailboxes have known degradations (OTP issues #5481 and #6494), so observability slows exactly when an operator needs it most.

Before memory exhaustion, the damage is latency rather than dispatch cost. `gen_server`'s loop is an unselective `receive Msg ->` that takes messages in delivery order, so the cost of reaching the callback is constant at any depth: the process never walks its queue looking for a message it prefers. That is narrower than "a deep mailbox is free", and the paragraph above is the reason: queued messages are on the heap by default, so collection scans them and the process does pay for depth. What depth does not change is the rate at which the callback retires work, and that rate is what decides the wait in front of each message. The queue drains at the rate the callback services it, so a server whose callback takes 30 seconds serves two calls a minute no matter how many are waiting, and the caller at position N waits for N-1 callbacks before its own runs. Throughput is capped by the callback, and latency rises without bound behind it. This is often a worse outcome than an outright crash, because supervisors cannot restart what is still running. The node holds its connections, accepts work it cannot drain, and degrades silently until something external intervenes.

If growth continues, the BEAM eventually hits a memory ceiling (host OOM-kill or allocator failure), and the node dies. There is no graceful shutdown from a memory failure, no `terminate/2`, no supervisor restart of the dead process. A single slow callback in production is bounded only by the host's memory.

## Decision

### Rule 1: Return from every callback in bounded time

Callbacks return quickly. "Quickly" means bounded and predictable, not "fast in the happy case."

**Correct:**

```elixir
# lib/my_app/inventory/server.ex
@impl true
def handle_call({:fetch_availability, sku}, from, %State{} = state) do
  case Impl.start_availability_fetch(state, from, sku) do
    {:ok, state} -> {:noreply, state}
    {{:error, %ErrorMessage{}} = error, state} -> {:reply, error, state}
  end
end

@impl true
def handle_info({ref, result}, %State{} = state) when is_reference(ref) do
  case Impl.finish_availability_fetch(state, ref, result) do
    {:reply, from, reply, state} ->
      GenServer.reply(from, reply)
      {:noreply, state}

    {:stale, state} ->
      {:noreply, state}
  end
end

def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{} = state)
    when is_reference(ref) do
  case Impl.fail_availability_fetch(state, ref) do
    {:reply, from, error, state} ->
      GenServer.reply(from, error)
      {:noreply, state}

    {:stale, state} ->
      {:noreply, state}
  end
end
```

**Wrong:**

```elixir
# lib/my_app/inventory/server.ex
# Warehouse.fetch_availability/1 is an HTTP read, run here on the loop.
@impl true
def handle_call({:fetch_availability, sku}, _from, %State{} = state) do
  {:reply, Warehouse.fetch_availability(sku), state}
end
```

**Why:** A GenServer pulls one message at a time and runs its callback to completion before pulling the next, so the Wrong version's mailbox is stalled for the full duration of the HTTP request. If the vendor has a 30-second tail, every caller behind it waits through that tail, and the 5000 ms call timeout starts raising exits across the codebase. The Correct version admits an independent read to a supervised task and immediately returns to the mailbox. Its abbreviated `Impl` lifecycle tracks the accepted task, replies with a structured error if task admission fails or the task exits abnormally, and clears correlation on every terminal path. ADR-005 Rule 3 contains the complete owner-routed implementation.

`GenServer.reply/2` is a nonblocking message send. A complete lifecycle may let the task call it directly; the task exists for `Warehouse.fetch_availability/1`, never merely to send the reply. Whichever design is chosen must have exactly one reply owner. The task supervisor arrives through `state.deps` per ADR-007 so concurrent tests do not accidentally share task infrastructure.

### Rule 2: Fix the slow operation rather than raising the caller's timeout

If callers are timing out on a GenServer, the fix is in the operation they are waiting on, not in the caller's patience.

**Correct:**

```elixir
# lib/my_app/pricing.ex
@spec fetch_price(GenServer.server(), String.t()) :: ErrorMessage.t_res(Decimal.t())
def fetch_price(server, sku), do: GenServer.call(server, {:fetch_price, sku})
```

**Wrong:**

```elixir
# lib/my_app/pricing.ex
@spec fetch_price(GenServer.server(), String.t()) :: ErrorMessage.t_res(Decimal.t())
def fetch_price(server, sku), do: GenServer.call(server, {:fetch_price, sku}, 60_000)
```

**Why:** The timeout is the caller's, not the server's, and it buys the caller nothing but a longer wait. `GenServer.call/3` monitors the server, blocks the calling process, and exits it with `{:timeout, {GenServer, :call, [server, request, timeout]}}` when the deadline passes. The timed-out caller's `$gen_call` message is already in the server's mailbox and stays there: the server will handle it in turn and reply to a caller that has stopped listening. Mailbox depth is therefore set by arrival rate against service rate, and the timeout value does not appear in that equation. Raising it changes one thing only, which is how long each caller waits before it learns something is wrong. `:infinity` removes the deadline entirely, so a stuck upstream becomes a permanently stuck caller and the failure never surfaces as a timeout at all.

Rule 1 does not rescue this caller either, and it is worth being exact about why. Moving the warehouse read into a task frees the loop for everyone behind this caller, but the caller still waits for the warehouse because the reply is sent only when the work finishes. If 5000 ms is routinely not enough for one operation, the honest reading is that the operation is not a synchronous request: it wants a cast plus a notification, a job with a status the caller can poll, or a smaller unit of work. Raising the timeout dresses that decision up as a configuration value.

## Consequences

- Short callbacks prevent dependency latency from stalling the mailbox.
- Timeouts at call sites stay at the default. When they do fire, they point to a real problem rather than a config dial.
- Slow work moves to supervised tasks with an explicit asynchronous reply lifecycle. See ADR-005.
- An operation that cannot fit inside the default timeout is redesigned rather than reconfigured: it stops being a `call` and becomes a cast plus a notification, or a job whose status the caller can query.


***

---
type: adr
id: 5
title: Get Slow Work Off the Processing Loop
status: accepted
date: 2026-04-22
updated: 2026-08-09
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


***

---
type: adr
id: 6
title: Use GenStage for Producer-Consumer Pipelines
status: accepted
date: 2026-04-29
updated: 2026-08-09
tags: [elixir, otp, genserver, backpressure, genstage, broadway, flow]
description: When one process produces work faster than another consumes it, use GenStage, Flow, or Broadway. Do not build pipelines on naked cast.
---

# ADR-006: Use GenStage for Producer-Consumer Pipelines

## Context

When one process generates work, and another handles it, and the producer can outpace the consumer, the consumer's mailbox grows unboundedly. The mailbox is a process resource: as it grows, GC pauses scale with it, observability calls like `process_info` degrade against it (see OTP issues #5481 and #6494), and the node eventually runs out of memory.

GenServer's `cast` provides no flow control. A producer firing a `cast` at a slower consumer has no way to know it should slow down. `GenStage` is the library built specifically for this problem, and `Flow` and `Broadway` are higher-level libraries built on top of it. All three are Hex packages rather than part of Erlang/OTP or Elixir's standard library, so reaching for them is a dependency decision, and it is the right one when the shape below appears.

They invert who initiates. Instead of the producer pushing whenever it has something, the consumer states how much work it is willing to have outstanding and the producer emits only against that. The queue between the two stops being an unbounded mailbox and becomes a bounded buffer with a declared size and a declared overflow policy.

## Decision

### Rule 1: Use GenStage / Flow / Broadway for producer-consumer pipelines

If the problem has the shape "process A produces work, process B handles it, and A can outpace B," do not build it with a `cast` between two GenServers. Reach for GenStage, or one of the libraries built on it.

**Correct:**

```elixir
# lib/my_app/ingest/producer.ex - reads only what has been asked for
defmodule MyApp.Ingest.Producer do
  use GenStage

  def start_link(%{name: name} = opts), do: GenStage.start_link(__MODULE__, opts, name: name)

  # State is a struct with one constructor, per ADR-012 Rule 1. A GenStage stage
  # is a GenServer, so the same state rules apply to it.
  @impl true
  def init(%{buffer_size: buffer_size, buffer_keep: buffer_keep} = opts) do
    {:producer, State.new(opts), buffer_size: buffer_size, buffer_keep: buffer_keep}
  end

  @impl true
  def handle_demand(incoming, %State{} = state) do
    dispatch(%State{state | outstanding_demand: state.outstanding_demand + incoming})
  end

  @impl true
  def handle_info(:work_available, %State{} = state), do: dispatch(state)

  defp dispatch(%State{outstanding_demand: 0} = state), do: {:noreply, [], state}

  defp dispatch(%State{deps: %Deps{queue: queue}, outstanding_demand: demand} = state) do
    events = Queue.pull(queue, demand)
    remaining = demand - length(events)

    {:noreply, events, %State{state | outstanding_demand: remaining}}
  end
end

# lib/my_app/ingest/consumer.ex - declares how much work it will have outstanding
defmodule MyApp.Ingest.Consumer do
  use GenStage

  def start_link(%{name: name} = opts), do: GenStage.start_link(__MODULE__, opts, name: name)

  @impl true
  def init(%{producer: producer} = opts) do
    {:consumer, State.new(opts), subscribe_to: [{producer, max_demand: 50, min_demand: 25}]}
  end

  @impl true
  def handle_events(events, _from, %State{} = state) do
    Enum.each(events, &process_event/1)
    {:noreply, [], state}
  end
end
```

**Wrong:**

```elixir
# lib/my_app/ingest/poller.ex - reads on a timer, regardless of what the worker can absorb
defmodule MyApp.Ingest.Poller do
  use GenServer

  @impl true
  def handle_info(:poll, %State{deps: %Deps{queue: queue, worker: worker}} = state) do
    queue
    |> Queue.pull(500)
    |> Enum.each(&GenServer.cast(worker, {:event, &1}))

    Process.send_after(self(), :poll, 1_000)
    {:noreply, state}
  end
end

# lib/my_app/ingest/worker.ex
defmodule MyApp.Ingest.Worker do
  use GenServer

  @impl true
  def handle_cast({:event, event}, %State{} = state) do
    {:noreply, Impl.ingest(state, event)}
  end
end
```

**Why:** Both versions read from the same queue and hand each event to the same processing step. The difference is who decides how many are in flight. In the Wrong version the poller decides, and it decides on a timer: 500 events every second whether the worker absorbed the last batch or not. `GenServer.cast/2` returns `:ok` regardless of whether the destination exists or ever handles the message, so the poller gets no admission or completion signal at any load. The worker's mailbox absorbs the difference between 500 per second and whatever it can actually process. That mailbox is unbounded and has no overflow policy, so the first evidence of a problem is memory.

In the Correct version the consumer declares delivery demand. `:max_demand` bounds what the subscription asks for in one demand cycle, and `:min_demand` determines when it asks for more. Demand is an upper bound, not a quota. If the queue currently yields fewer events than requested, the producer retains the unfilled remainder in its own state and emits against it when `:work_available` arrives; GenStage does not promise to invoke `handle_demand/2` again for that remainder.

Outstanding consumer demand and the producer buffer are different quantities. Outstanding demand records events the consumer is still willing to receive. The buffer holds surplus events a producer emits when there is not enough demand; `:buffer_size` bounds that buffer and `:buffer_keep` chooses whether the earliest or latest events survive overflow. The values in Correct arrive through validated configuration and express this pipeline's policy rather than universal numbers. Flow builds parallel transformations, partitioning, windows, and triggers over demand-driven stages. Broadway builds concurrent message processing, batching, and acknowledgement lifecycle. Neither distinction belongs in a naked mailbox protocol.

## Consequences

- Producer-consumer pipelines use GenStage, Flow, or Broadway. They do not use naked `cast` between processes.
- Mailbox growth is treated as a system signal: the response is structural back-pressure, not faster processing.
- Every subscription has reviewed `:max_demand` and `:min_demand` settings. Separately, every producer that can buffer surplus events has a reviewed `:buffer_size` bound and `:buffer_keep` retention policy. Demand and buffering are not combined into one in-flight bound.
- The dependency is accepted deliberately. GenStage is not in the standard library, so a project takes it on when it has a pipeline, not by default.


***

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


***

---
type: adr
id: 8
title: Graceful Shutdown Requires trap_exit and a Realistic :shutdown
status: accepted
date: 2026-04-22
updated: 2026-08-09
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


***

---
type: adr
id: 9
title: "Send Minimal Data Between Processes"
status: accepted
date: 2026-06-28
updated: '2026-08-14'
tags: [elixir, anti-pattern, processes, message-passing, performance, memory]
description: "Same-node BEAM messages copy ordinary term structure into receiver-owned storage, although reference-counted binaries and literals are shared and queued data may remain off-heap. A closure carries the variables it captures, not only the field it later reads. Send only the fields a process needs, or let it fetch its own data."
---
# ADR-009: Send Minimal Data Between Processes

## Context

BEAM processes have isolated heaps, which keeps per-process garbage collection independent. The cost of that isolation falls on every term that crosses a process boundary. On the same node, sending a message reproduces the term's ordinary structure in storage owned by the receiver: its maps, tuples, lists, and small heap binaries. Reference-counted binaries and literals are shared rather than reproduced, and immediates such as atoms and small integers travel as words. The copy also flattens sharing: a subterm appearing in several positions is reproduced at each one, so the receiver's copy can be larger than the original. A tuple holding the same fifty-element list three times occupies 104 words before the send and 304 after it.

Where that copy lives is the receiver's setting. A process configured with `message_queue_data: :off_heap` keeps queued messages outside its heap; with `:on_heap` they reach the heap eventually and may sit off it until then. The copy itself happens at send time either way, so its size is decided by what the sender puts in the message. Sending to another node takes a different route: the term is encoded in the Erlang External Term Format, transported, and decoded on the far side.

The boundary is explicit at `send/2`, `GenServer.call/3`, `GenServer.cast/2`, and the initial argument to `GenServer.start_link/3`. It is quieter at `spawn/1`, `Task.async/1`, and `Task.async_stream/3`, where a function carries the variables its body names rather than the fields it eventually reads. `fn -> log_request_ip(conn.remote_ip) end` names `conn`, so `conn` is what travels, and the field access runs later inside the new process.

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

**Why:** `conn` is a large struct holding params, headers, adapter state, and references to request data. Casting it copies the struct's maps, tuples, lists, and other ordinary structure into storage owned by the server even though the server reads one field. The struct's large binary payloads stay shared on the same node; the structure holding them is what gets reproduced. Extracting `conn.remote_ip` at the call site means only the small message tuple and IP tuple cross the boundary. The same mechanism applies to `send/2`, `GenServer.call/3`, and the initial data handed to `GenServer.start_link/3`.

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

**Why:** The anonymous function captures `conn`, because that is the variable its body references; `remote_ip` is a field access evaluated when the function runs. When the closure crosses into the spawned process, the captured `conn` crosses with it: the ordinary structure is copied, subject to the same reference-counted-binary and literal exceptions as any other same-node message. Binding `ip_address = conn.remote_ip` before constructing the closure changes the closure environment itself, so it contains only the small IP term. The same capture mechanism governs `Task.async/1` and `Task.async_stream/3`, including the `Task.Supervisor` patterns in ADR-001 and the off-loop work in ADR-005.

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

**Why:** If the receiving process is the only consumer, loading the data there avoids transporting the fetched representation across a process boundary at all. Passing the id copies only a small message term and defers the load to the process that needs the record. For data that many processes read and that changes infrequently, `:persistent_term` stores one shared value that readers access without a per-reader message copy. The reason it suits read-mostly data only is the write side: replacing a complex term with `put/2` or removing one with `erase/1` initiates a global garbage collection, and all processes in the system are scheduled to scan their heaps for the replaced term. Each scan is light, but with many processes the system is less responsive until they finish. Terms that fit in one machine word, atoms included, are optimized to skip the global collection. Both strategies keep large ordinary message structure from being reproduced across process heaps (ADR-003).

## Consequences

- Messages carry identifiers and small scalar fields, not whole structs. Copy cost scales with the ordinary structure transported for the receiver, not with the fields the receiver eventually reads; shared reference-counted binary payloads are the explicit exception.
- Closures passed to `spawn`, `Task.async`, and `Task.async_stream` capture pre-bound minimal values, so background work does not silently carry a full struct's ordinary structure into a new process.
- The sole-consumer case fetches its own data; read-mostly shared data lives in `:persistent_term` instead of being copied on every message.
- Process heaps and off-heap message queues hold less receiver-owned structure because each boundary carries only what the receiving process needs.


***

---
type: adr
id: 10
title: "Supervise Every Long-Lived Process"
status: accepted
date: 2026-06-28
updated: '2026-08-12'
tags: [elixir, anti-pattern, otp, supervision, processes, fault-tolerance]
description: "A process started outside a supervision tree has no restart strategy, no deterministic start or shutdown ordering, and is invisible to observer-based introspection because supervisors are the BEAM's lifecycle owners. Start every long-lived process as a static supervisor child, and every runtime-created one under a DynamicSupervisor."
---
# ADR-010: Supervise Every Long-Lived Process

## Context

Spawning a process outside a supervision tree is legal, and for short-lived work it is fine. The problem is the long-lived process started with a bare `spawn`, `spawn_link`, or a hand-rolled `start_link` call buried in application code. Such a process has no lifecycle owner.

A supervisor is the BEAM's lifecycle owner. It starts its children in declared order, links to and monitors each one, applies a restart strategy (`:one_for_one` and friends) when a child exits, and terminates children in reverse start order on shutdown. A process outside the tree gets none of this. A transient crash becomes permanent absence because nothing restarts it. Startup ordering is undefined, so any process that depends on it needs ad-hoc initialization coordination. On application stop, the BEAM tears down the application's supervision tree, terminating children in reverse start order and giving each one up to its `:shutdown` budget to exit. An orphaned process is not in that tree, so it gets no shutdown signal, no position in the ordering, and no budget at all. What supervision buys here is the ordered signal and the bounded window, not a guarantee that cleanup runs: the budget is a ceiling rather than a wait, and `terminate/2` is skipped entirely on `:brutal_kill`, `Process.exit(pid, :kill)`, VM crash, and SIGKILL. ADR-008 owns that contract. It is also invisible to introspection: `:observer` and Phoenix LiveDashboard render the supervision tree, and a PID hanging off nothing does not appear.

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

**Why:** In the wrong version the two counters are linked only to whatever process called `boot_counters`, and a link propagates exits by reason rather than unconditionally. A caller that crashes takes both counters down with it. A caller that returns and exits normally leaves them running with no owner, because a `:normal` exit signal to a process that is not trapping exits is discarded. The failure mode is therefore not one thing to reason about but two, selected by how the caller happened to finish. Neither branch restarts a counter that crashes on its own, their start order relative to dependents is undefined, and application shutdown never signals them. The child-list version makes the supervisor their owner: deterministic start order, a restart strategy on failure, reverse-order termination so cleanup runs in dependency order, and a node visible to `:observer` and LiveDashboard. Distinct child specs need distinct `:id` values, which is why the second counter is wrapped in `Supervisor.child_spec/2`.

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
- Application shutdown reaches every process with an ordered signal and a bounded budget, which is the precondition for best-effort cleanup rather than a guarantee that it runs (ADR-008).
- The full process topology is introspectable through `:observer` and LiveDashboard, because everything hangs off the supervision tree.
- Fixed processes live in a child list; runtime-created ones live under a `DynamicSupervisor`. Bare `spawn`/`start_link` of a long-lived process becomes a code smell.


***

---
type: adr
id: 11
title: Test OTP Code Through Real Processes
status: accepted
date: 2026-05-08
updated: 2026-08-09
tags: [elixir, otp, testing, sys, sql-sandbox, callers]
description: "Start every test-scoped fixture or service with start_supervised!/1. Test a state transition directly as a function; use a real supervised process when the behavior's meaning depends on ordering, serialized state transitions, timers, monitors, task correlation, registration, supervision, or shutdown, and never create an Impl module just to make a test process-free. :sys.replace_state/2 is prohibited on every process, including the ones your application owns, and :sys.get_state/2 is permitted only as a discarded-value mailbox barrier for prior messages the same test process sent to the same live PID. application.ex starts the same supervision tree in every environment. Reach a sandboxed data store from a spawned process through a $callers-propagating Task primitive, or grant a dedicated process access with Sandbox.allow/3."
---

# ADR-011: Test OTP Code Through Real Processes

## Context

OTP tests fail in three characteristic ways. The first is non-isolation: a test starts a globally-named GenServer that outlives it and shares state with every other test that touches the same name. The suite then runs serially, or it runs concurrently and lies.

The second is testing a behavior somewhere other than where its meaning lives. A direct state transition that takes state and an event gets driven through a live process, which buys startup cost, a message round trip, and a state-extraction problem, and buys no coverage. The mirror mistake is worse, because it is silent: a behavior whose meaning is ordering, serialized state transitions, or lifecycle gets tested against a process-free function, and the test stays green on a property the running system does not have. A serialized read-modify-write, a `handle_continue` that must run before the first client message, a monitor that must fire when a collaborator crashes, or cooperative best-effort shutdown cleanup: none of those exist outside a process.

The third is state surgery. `:sys.replace_state/2` and `:sys.get_state/1` come from the `sys` module, which documents both as intended only to help with debugging, and documents `replace_state` additionally as not to be called from normal code. Tests reach for them anyway, because they are the shortest path to a state assertion. `replace_state` installs a state term without running any of the callbacks whose job is to keep that term consistent. `get_state` returns the callback module's private representation, which a test then hard-codes into an assertion. `get_state` has exactly one sound use, and it is synchronization rather than assertion; Rule 3 states the precondition and the mechanism it rests on.

Elixir's Task and ExUnit caller-tracking machinery uses a per-process dictionary key called `$callers`, holding a chain of pids leading back to the test process. `Ecto.Adapters.SQL.Sandbox` can use that chain to resolve which test owns the database connection a spawned process is trying to use; besides calling `allow/3`, allowance can also be provided to processes via caller tracking. When the chain breaks, ownership lookup fails and the spawned process cannot read or write.

This ADR covers test-author discipline: how to spin up processes for a test, where to point each assertion, what not to touch, and what to know about `$callers`. ADR-007 covers the complementary side, GenServer design for testability.

## Decision

Tests exercise the real OTP machinery the running system uses. Each behavior is tested at the boundary where its meaning lives, and no test writes to or asserts on a process's private state.

### Rule 1: Use start_supervised!/1 for test-scoped fixtures and services

When a test needs a process to live as a fixture or service for part or all of the test (a GenServer, a `Task.Supervisor`, a `Registry`, an `Agent`), start it with `start_supervised!/1` rather than calling its `start_link/1` directly. A short-lived task whose handle is explicitly awaited is work, not a fixture; supervise the owner it runs under and await its terminal result.

**Correct:**

```elixir
defmodule MyApp.InventoryTest do
  use ExUnit.Case, async: true

  alias MyApp.Inventory

  setup do
    table = :ets.new(:stock, [:set, :public])
    :ets.insert(table, {"sku-1", 5})
    server = start_supervised!({Inventory.Server, %{name: nil, stock_table: table}})

    {:ok, server: server, table: table}
  end

  test "reserves stock that is on hand", %{server: server} do
    assert {:ok, _reservation_id} = Inventory.reserve(server, "sku-1", 3)
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.InventoryTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _pid} = MyApp.Inventory.Server.start_link(%{name: __MODULE__, stock_table: :stock})
    :ok
  end
end
```

**Why:** `start_supervised!/1` places the fixture under ExUnit's per-test supervisor, and ExUnit terminates that supervisor during teardown however the test ends: success, assertion failure, raise, or timeout. A bare `start_link/1` from `setup` leaves lifecycle tied only to a link and can race the next setup while a registered process is still shutting down. `name: __MODULE__` makes that collision certain because the node-local name registry is one namespace per VM. The Correct fixture needs no registration: the test owns an unnamed ETS table, injects its reference, captures the supervised server PID, and lets test teardown end both lifetimes. `async: false` prevents this case module from running concurrently with any other case module; it neither isolates a global name nor repairs shared mutable state, and it needlessly excludes concurrency when resources could have been per-test.

### Rule 2: Test each behavior at the boundary where its meaning lives

Test a state transition directly as a function when the design contains one: build a state value, apply the transition, assert on the returned state. Use a real supervised process when the behavior's meaning depends on mailbox ordering, serialized non-interleaving application of a transition, `call` / `cast` / `send` dispatch, timers, monitors, `handle_continue`, task result correlation, registration, supervision, restart, or shutdown. Do not create an `Impl` merely to make a test process-free. ADR-002 Rule 2 already puts an `Impl` next to every Server; its existence is not what decides the test boundary.

**Correct:**

```elixir
# test/my_app/inventory/impl_test.exs
# The transition is a function of state and event, so test it as one. setup
# creates a per-test stock table holding {"sku-1", 5}.
test "reserve/3 records the hold and deducts the units", %{table: table} do
  state = State.new(%{name: nil, stock_table: table})

  assert {{:ok, id}, %State{} = new_state} = Impl.reserve(state, "sku-1", 3)
  assert Reservations.pending?(new_state.reservations, id)
  assert [{"sku-1", 2}] === :ets.lookup(table, "sku-1")
end

# test/my_app/inventory_test.exs
# Taking a hold out of the ledger exactly once is a property of the receive
# loop, so test it through one. setup starts an unregistered Inventory.Server
# supervised over the injected table holding {"sku-1", 5}.
test "concurrent releases of one reservation return its units once",
     %{server: server, table: table} do
  {:ok, id} = Inventory.reserve(server, "sku-1", 3)

  results =
    1..5
    |> Task.async_stream(fn _ -> Inventory.release(server, id) end, max_concurrency: 5)
    |> Enum.map(fn {:ok, result} -> result end)

  assert Enum.count(results, &(&1 === :ok)) === 1
  assert Enum.count(results, &match?({:error, %ErrorMessage{}}, &1)) === 4
  assert [{"sku-1", 5}] === :ets.lookup(table, "sku-1")
end
```

**Wrong:**

```elixir
# test/my_app/inventory/impl_test.exs
# Names a concurrency property and exercises none. Impl.release/2 threads state
# by hand in one process, so this passes whether the Server takes the entry and
# restocks inside a single callback or splits them across a handle_call that
# reports the entry and a later handle_cast that removes it.
test "concurrent releases of one reservation return its units once", %{table: table} do
  state = State.new(%{name: nil, stock_table: table})

  assert {{:ok, id}, one} = Impl.reserve(state, "sku-1", 3)
  assert {:ok, two} = Impl.release(one, id)
  assert {{:error, %ErrorMessage{code: :not_found}}, ^two} = Impl.release(two, id)
  assert [{"sku-1", 5}] === :ets.lookup(table, "sku-1")
end
```

**Why:** The `gen_server` receive loop is the serialization mechanism. It pulls one message from the mailbox and runs the callback to completion before decoding the next, so a transition that reads and writes state inside one callback does not interleave with another callback in that process. The levels live in a shared table whose single-object operations are atomic on their own, which leaves the ledger as the thing the loop protects: `Reservations.take/2` hands an entry to exactly one release because the calls run through the same mailbox, and the restock that follows belongs to that entry. That non-interleaving belongs to the loop, not to the function it calls: `Impl.release/2` returns the same value in a codebase where the Server applies it in one callback and in one where the Server splits the take and restock across messages, so a process-free test cannot distinguish them. `Process.send_after/3` delivery, `handle_continue` running before the first client message, a `:DOWN` signal, task-result correlation, and restart under a supervisor are likewise mailbox and lifecycle properties. The concurrent-call example asserts the invariant under the execution it observes; an uncontrolled `Task.async_stream/3` schedule does not prove that every possible split-phase interleaving occurred. When a particular interleaving is the regression, coordinate that interleaving explicitly or exercise it repeatedly rather than treating one scheduler run as a proof. The relationship is symmetric: direct transitions gain nothing from a process round trip, while lifecycle behavior cannot be established without the real process.

### Rule 3: Drive state through the process's own commands, and use `:sys.get_state/2` only as a barrier for messages the test sent

`:sys.replace_state/2` is prohibited. Not only on library-owned processes: on every process, including the ones your application owns. Do not use the value returned by `:sys.get_state/1` or `:sys.get_state/2` to assert on a process's private representation. A bounded `:sys.get_state(pid, timeout)` is permitted for exactly one purpose, as a mailbox synchronization barrier, and it is sound only for prior messages the same test process sent to that same live PID while it is executing its normal GenServer receive loop. It is not a barrier while the target is suspended, blocked indefinitely in a callback, or replaced after a restart. Discard its return value and assert through a surface the process publishes. When a barrier precedes the assertion, that surface is something other than a reply from the same process: a shared table it writes, a file it wrote, or a collaborator's recorded interaction. A synchronous reply needs no extra barrier only when the effect under test occurred before that reply was sent.

**Correct:**

```elixir
setup do
  table = :ets.new(:stock, [:set, :public])
  :ets.insert(table, {"sku-1", 5})
  server = start_supervised!({Inventory.Server, %{name: nil, stock_table: table}})

  {:ok, server: server, table: table}
end

test "a restock reaches the shared stock table", %{server: server, table: table} do
  # restock/3 is a cast: it returns before the units land in the table.
  assert :ok === Inventory.restock(server, "sku-1", 10)

  # Barrier. This process sent the cast, so the system message it sends next is
  # handled after it. The value is discarded; only the ordering is used.
  _ = :sys.get_state(server, 1_000)

  assert [{"sku-1", 15}] === :ets.lookup(table, "sku-1")
end
```

**Wrong:**

```elixir
# Same setup as the Correct example: a supervised server over its stock table.

# State surgery. The write invents a hold that no reserve produced, so the units
# it names were never deducted, and the release restocks them onto a table that
# still carries them: a pairing no command can produce.
test "releasing a reservation returns its units", %{server: server, table: table} do
  :sys.replace_state(server, fn state ->
    entry = %MyApp.Inventory.Reservation{
      sku: "sku-1",
      quantity: 3,
      expires_at: DateTime.add(DateTime.utc_now(), 60)
    }

    reservations =
      %Reservations{state.reservations | entries: %{1 => entry}, next_id: 2}

    %{state | reservations: reservations}
  end)

  assert :ok === Inventory.release(server, 1)
  assert [{"sku-1", 8}] === :ets.lookup(table, "sku-1")
end

# Dead barrier, private assertion. Inventory.reserve/3 is a GenServer.call from
# this process, so it is already an ordered request and the barrier adds
# nothing. The assertion then hard-codes the state struct's shape.
test "reserve records the hold", %{server: server} do
  assert {:ok, id} = Inventory.reserve(server, "sku-1", 3)

  state = :sys.get_state(server, 1_000)
  assert Map.has_key?(state.reservations.entries, id)
end

# Unsound barrier. recount/2 dispatches a task to the warehouse, and the count
# reaches the server later as handle_info({ref, result}, state), sent by the
# task process. This test never enqueued that message.
test "a recount reaches the shared stock table", %{server: server, table: table} do
  assert {:ok, _ref} = Inventory.recount(server, "sku-1")

  _ = :sys.get_state(server, 1_000)

  assert [{"sku-1", 12}] === :ets.lookup(table, "sku-1")
end
```

**Why:** `sys` requests are messages, and that is the whole mechanism. Erlang's signal ordering guarantee is pairwise between one sender and one receiver: if `A` sends `S1` to `B`, and later sends `S2` to `B`, `S1` is not delivered after `S2`. Ordering alone is not yet the barrier, because delivery order says nothing about completion. The second half is `gen_server`'s loop: it is an unselective receive that takes messages in delivery order and runs each callback to completion before taking the next, and a `sys` request is an ordinary message in that queue with no priority over client work. Put the two together and a returned `:sys.get_state/2` proves that this same live PID finished handling the messages this test process had already sent it. It proves nothing about a timer, a task result, or a third-party message because those have different senders, and it is not global quiescence. The returned term is a separate problem: it is the callback module's internal representation with no compatibility contract, so assertions against it couple tests to private shape. `:sys.replace_state/2` is worse because it installs a term without running the commands that preserve relationships between fields. This does not become safe on an application-owned process; its invariants are enforced by those commands, and the write goes around all of them.

### Rule 4: Start the same supervision tree in every environment

`application.ex` builds one child list and uses it everywhere. Environment-owned application configuration still belongs in runtime or compile-time configuration as appropriate. Per-test process identity and substitutable collaborators come from instance opts (ADR-007 Rule 3), and datastore isolation comes from the test sandbox; neither requires an environment-conditional child list.

**Correct:**

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      MyAppWeb.Endpoint,
      {Task.Supervisor, name: MyApp.TaskSupervisor},
      {MyApp.Inventory.Server, %{name: MyApp.Inventory.Server}},
      {MyApp.PollLoop, %{name: MyApp.PollLoop}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

**Wrong:**

```elixir
# in MyApp.Application.start/2
children =
  if Mix.env() === :test do
    [MyApp.Repo, MyAppWeb.Endpoint]
  else
    [
      MyApp.Repo,
      MyAppWeb.Endpoint,
      {MyApp.Inventory.Server, %{name: MyApp.Inventory.Server}},
      {MyApp.PollLoop, %{name: MyApp.PollLoop}}
    ]
  end

Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
```

**Why:** The child list is the specification the supervisor executes. Static children start in list order; under `:one_for_one`, a terminated child restarts without restarting its siblings. Supervisor shutdown terminates children in reverse start order and applies each child spec's shutdown policy: workers default to a finite timeout, while supervisor children normally use `:infinity` so they can stop their own descendants. A different list is a different specification, so omitted children and environment-only ordering or restart behavior first execute in production. `MyApp.PollLoop` is absent from the Wrong test tree, so an `init/1` failure can wait until deploy. The Wrong version also calls `Mix.env()` at runtime even though `Mix` is a build tool and need not exist in a release. Keep the child topology constant. Application configuration may vary through the proper config boundary; per-test instance opts vary identity and injected collaborators without rewriting the tree. `MyApp.Repo` is the model: it starts everywhere and gets test isolation from `Ecto.Adapters.SQL.Sandbox` rather than omission.

### Rule 5: Propagate `$callers` with Task or grant one dedicated process explicitly

After the test owns a sandbox connection, `Ecto.Adapters.SQL.Sandbox` can resolve that owner through the `$callers` chain. A process spawned by a `Task` function called from the test carries that chain and can reach the same owner without an explicit grant. When the receiver already exists or is not spawned through that caller-propagating path, grant one dedicated process access with `Ecto.Adapters.SQL.Sandbox.allow/3` and assert that the grant succeeds. Never attach one singleton process to multiple concurrent sandbox owners.

**Correct:**

```elixir
test "records a scan from a supervised task" do
  supervisor = start_supervised!({Task.Supervisor, []})
  scan = %{code: "abc-123", scanned_at: DateTime.utc_now()}

  supervisor
  |> Task.Supervisor.async(fn -> MyApp.Scans.record(scan) end)
  |> Task.await()

  assert [%MyApp.Scans.Scan{code: "abc-123"}] = MyApp.Scans.list()
end

test "records a scan from a dedicated worker" do
  worker = start_supervised!({MyApp.ScanWorker, %{name: nil}})
  scan = %{code: "abc-123", scanned_at: DateTime.utc_now()}

  assert :ok = Ecto.Adapters.SQL.Sandbox.allow(MyApp.Repo, self(), worker)
  assert :ok = MyApp.ScanWorker.record(worker, scan)

  assert [%MyApp.Scans.Scan{code: "abc-123"}] = MyApp.Scans.list()
end
```

**Wrong:**

```elixir
test "records a scan from the worker" do
  send(MyApp.ScanWorker, {:record, %{code: "abc-123", scanned_at: DateTime.utc_now()}})

  assert [%MyApp.Scans.Scan{code: "abc-123"}] = MyApp.Scans.list()
end
```

**Why:** The process dictionary is per-process and ordinary spawning does not inherit it. Task primitives explicitly propagate `$callers` from the calling process into the task, which is why a task created from the test can resolve the test's existing sandbox owner. `$ancestors` is separate OTP/proc-lib ancestry metadata; it neither substitutes for `$callers` nor grants database ownership. A process already started by an application or test supervisor keeps the dictionary it started with, and later `call`, `cast`, or `send` operations do not rewrite it. `Sandbox.allow/3` supplies that missing ownership edge explicitly. Its result must be checked: reusing one singleton worker across concurrent owners is a conflict, not isolation. Prefer one unregistered worker PID per test; if the behavior truly requires a singleton, serialize that test intentionally and own the tradeoff. The Wrong version has neither caller propagation nor an explicit grant, and its bare send also races the assertion.

## Consequences

- Test-scoped process fixtures and services use `start_supervised!/1`, not bare `start_link/1`. Unregistered PIDs and unnamed resource handles keep them isolated under `async: true`.
- Test files split by boundary rather than by ratio. `_impl_test.exs` holds direct state transitions; the API-level test file holds ordering, serialized state application, timers, monitors, task correlation, registration, supervision, restart, and shutdown. No `Impl` module is created to move a test across the line.
- `:sys.replace_state/2` appears nowhere in the suite, on library-owned and application-owned processes alike.
- Every `:sys.get_state/2` in the suite is a discarded-value barrier, immediately preceded by a message this test process sent and immediately followed by an assertion against something other than that process's own reply. A test that needs to wait on a timer, a task result, or a third process uses a mechanism that observes those, not this one.
- Assertions name published surfaces: API return values, shared tables the process writes, files, a collaborator's recorded interaction. No test hard-codes a process's internal state term, so state refactors do not cascade into the suite.
- `application.ex` has the same child topology in every environment. Application configuration uses its configuration boundary; per-test identity and collaborators use instance opts.
- Tests that need database access from a process they spawn use a `$callers`-propagating Task function. Existing or independently supervised receivers get an asserted `Sandbox.allow/3` grant to a dedicated PID, never one singleton shared by concurrent owners.


***

---
type: adr
id: 12
title: The Shape of GenServer State
status: accepted
date: 2026-08-02
updated: 2026-08-09
tags: [elixir, otp, genserver, state, structs, types, composition]
description: "A GenServer's state is a struct in its own module with a fully enumerated @type t, @enforce_keys, and one construction function, never a bare map and never a @typep map type. Configuration, injected collaborators, and changing concerns have distinct homes, and each concern's module owns its transitions. The state struct is an architectural boundary; no accessor exists so a caller or test can read live fields."
---

# ADR-012: The Shape of GenServer State

## Context

Three ADRs already govern parts of a GenServer's state, but none governs its shape. ADR-003 sets how much state a process carries and where bulk data goes instead. ADR-007 sets how opts arrive and how they are validated. `elixir-conventions` ADR-004 sets the discipline for domain entities: a fully enumerated `@type t`, exact `@enforce_keys` semantics, and opt-in JSON encoding. Process state falls through the gap between them. It is not a domain entity that callers hand around; it is the private accumulation a process coordinates through, so an agent applying `elixir-conventions` ADR-004 to a schema module reasonably leaves `init/1`'s map literal alone.

What lands in that gap is a map. `init/1` returns `%{name: name, cache: cache, pending: %{}}`, one callback adds a task reference with `Map.put/3`, another adds a generation counter, and the shape of the state is whatever the union of the callbacks happens to produce. Nothing rejects the growth, because nothing declares what the state is.

The reason nothing rejects it is mechanical rather than cultural. The state value crosses the OTP callback boundary on every message: `init/1` returns it, `gen_server` holds it, and a callback receives it back as an ordinary argument. `defstruct` declares the allowed fields. A `%State{} = state` callback or transition head gives the compiler a known closed struct shape at that entry point, and `%{state | field: value}` refuses to introduce a field the struct does not declare. A fully enumerated `@type` and the corresponding `@spec` document field-value types for tools and Dialyzer; they do not create those compiler checks. A bare map and `Map.put/3` establish no such boundary: `Map.put(state, :sweep_ref, ref)` can add the misspelled key, the later read of `state.sweep_timer` still finds `nil`, and the timer is never canceled.

## Decision

A GenServer's state is a declared struct, grouped by write path, partitioned by concern, and an architectural dependency boundary owned by its subsystem.

### Rule 1: Declare process state as a struct with `@enforce_keys` and one construction function

The state a GenServer carries lives in its own module under the subsystem namespace, with a fully enumerated `@type t`, `@enforce_keys` listing values callers must supply, and one named function that builds it. `State.new/1` is the only code that directly constructs `%State{}`. `init/1` and direct transition tests call that constructor, and every whole-state transition matches `%State{} = state` and writes with `%{state | field: value}`. A bare map is not the state type, and neither is a `@typep` map type declared inside `Impl`.

This first Correct snippet is a staged excerpt that isolates the construction and shape rule. Rule 3 supplies the complete State and concern composition.

**Correct (staged excerpt):**

```elixir
# lib/my_app/inventory/state.ex
defmodule MyApp.Inventory.State do
  alias MyApp.Inventory.Config

  @enforce_keys [:name, :config]

  defstruct [:name, :config, pending: %{}]

  @type t :: %__MODULE__{
          name: GenServer.name() | nil,
          config: Config.t(),
          pending: %{optional(pos_integer()) => pos_integer()}
        }

  @spec new(map()) :: t()
  def new(%{name: name} = opts) do
    config = Config.from(opts)
    :ok = validate_config(config)

    %__MODULE__{name: name, config: config}
  end

  defp validate_config(%Config{sweep_interval_ms: interval_ms})
       when is_integer(interval_ms) and interval_ms > 0,
       do: :ok

  defp validate_config(config),
    do: raise(ArgumentError, "invalid inventory configuration: #{inspect(config)}")
end
```

```elixir
# lib/my_app/inventory/impl.ex
@spec track(State.t(), pos_integer(), pos_integer()) :: State.t()
def track(%State{} = state, operation_id, quantity) do
  %{state | pending: Map.put(state.pending, operation_id, quantity)}
end
```

**Wrong:**

```elixir
# lib/my_app/inventory/impl.ex
defmodule MyApp.Inventory.Impl do
  @typep server_state :: %{name: GenServer.name(), pending: map(), sweep_timer: reference() | nil}

  @spec initial_state(map()) :: server_state()
  def initial_state(opts) do
    %{name: opts.name, sweep_interval_ms: opts.sweep_interval_ms, pending: %{}, sweep_timer: nil}
  end

  def arm_sweep(state) do
    Map.put(state, :sweep_ref, Process.send_after(self(), :sweep, state.sweep_interval_ms))
  end

  def cancel_sweep(%{sweep_timer: nil} = state), do: state

  def cancel_sweep(state) do
    Process.cancel_timer(state.sweep_timer)
    Map.put(state, :sweep_timer, nil)
  end
end
```

**Why:** The mechanisms fire at different places and must not be conflated. `defstruct` declares the allowed fields. `@enforce_keys` requires key presence when code builds a literal or calls `struct!/2`, but it permits an explicitly supplied `nil`, validates no field type or invariant, does not govern updates, and is bypassed by `struct/2`. `State.new/1` therefore validates values and composite invariants before it constructs the state. A `%State{} = state` transition head gives the compiler the known struct shape, and `%{state | sweep_ref: ref}` cannot introduce an undeclared key: it reports `expected a map with key :sweep_ref in map update syntax`. The head is what buys that. Where a value's type is not established by the head, the struct-tagged form `%State{state | field: value}` asserts it at the update site instead, reporting `a struct for MyApp.Inventory.State is expected on struct update`. Transitions here take the head, so they use the shorter form. The Wrong version establishes no struct boundary, and `Map.put/3` inserts the misspelled key rather than rejecting it.

The fully enumerated `@type` and `@spec` document field types and give Dialyzer information it can use to find provable inconsistencies; they neither enforce values at runtime nor guarantee every misuse is reported. A private map alias is additionally the wrong ownership boundary: sibling modules cannot name another module's `@typep` in their specs. Dialyzer may still infer information across module calls, but a private alias does not give the subsystem one declared State type that every callback and transition can name.

### Rule 2: Group configuration, injected collaborators, and working state separately

The state's values have different write paths. Configuration is derived once from the opts validated at `start_link`. Injected collaborators are the modules and pids the process calls out to, supplied per ADR-007 Rule 3. Changing state is partitioned by the concern that owns each transition. Configuration gets one `config` field, injected collaborators get one `deps` field, and changing state gets one field per concern. Stable process identity such as `name` may remain explicit top-level metadata. `Config` and `Deps` are structs with fully enumerated `@type t` declarations and constructors that read validated opts. ADR-003 Rule 2 makes the argument for separating working state from configuration; this rule extends that separation to collaborators and concern ownership.

**Correct (staged grouping excerpt):**

```elixir
# lib/my_app/inventory/state.ex
alias MyApp.Inventory.{Config, Deps, Recounts, Reservations, Sweeper}

@enforce_keys [:name, :config, :deps, :reservations, :recounts, :sweeper]

defstruct [:name, :config, :deps, :reservations, :recounts, :sweeper]

@type t :: %__MODULE__{
        name: GenServer.name() | nil,
        config: Config.t(),
        deps: Deps.t(),
        reservations: Reservations.t(),
        recounts: Recounts.t(),
        sweeper: Sweeper.t()
      }
```

`State.new/1`, including initialization of these concerns, appears in the complete Rule 3 example. No caller fills this staged declaration with a State literal.

**Wrong:**

```elixir
# lib/my_app/inventory/impl.ex, over a State whose fields all sit at the top level:
# defstruct [:name, :cache, :clock, :window_ms, pending: %{}, sweep_timer: nil]
@spec back_off(State.t()) :: State.t()
def back_off(%State{} = state) do
  %{state | window_ms: state.window_ms * 2}
end
```

**Why:** A GenServer's state is the accumulator its receive loop threads from one callback to the next. Flat, `%{state | window_ms: state.window_ms * 2}` and `%{state | pending: pending}` are both updates against the same top-level struct, so the declared field list alone cannot express their different ownership. The doubled configuration then applies to every later message and disappears on a crash when `init/1` rebuilds the original opts. Grouping makes those write paths explicit: `Config` owns construction-time settings, `Deps` owns injected collaborators, and each changing concern owns its own transitions. `State.new/1` rebuilds configuration and dependencies from opts and creates fresh concern values, making the restart boundary readable from the constructor rather than recoverable only by tracing callback assignments.

### Rule 3: Compose per-concern sub-structs and let each concern's module own its transitions

When a process coordinates more than one concern (a set of reservations, a sweep timer, a table of monitored tasks, a rate-limit window), each concern gets its own struct module with a fully enumerated `@type t`, its own constructor, and its own transition functions. The state holds one field per concern. Every concern transition matches `%__MODULE__{} = concern`; it receives that concern rather than the whole State. An Impl function matches `%State{} = state`, calls the concerns touched by one message, and recombines their results. ADR-003 defines the bounded `Recounts` concern used here; this rule does not duplicate its API.

**Correct:**

```elixir
# lib/my_app/inventory/reservations.ex
defmodule MyApp.Inventory.Reservations do
  alias MyApp.Inventory.Reservation

  @enforce_keys [:limit]
  defstruct [:limit, entries: %{}, next_id: 1]

  @type id :: pos_integer()
  @type t :: %__MODULE__{
          limit: pos_integer(),
          entries: %{optional(id()) => Reservation.t()},
          next_id: id()
        }

  @spec new(pos_integer()) :: t()
  def new(limit) when is_integer(limit) and limit > 0, do: %__MODULE__{limit: limit}

  @spec ensure_admission(t()) :: ErrorMessage.t_ok_res()
  def ensure_admission(%__MODULE__{} = reservations) do
    if map_size(reservations.entries) < reservations.limit do
      :ok
    else
      {:error,
       ErrorMessage.service_unavailable("Reservation capacity reached", %{
         operation: :reserve
       })}
    end
  end

  @spec pending?(t(), id()) :: boolean()
  def pending?(%__MODULE__{} = reservations, id), do: Map.has_key?(reservations.entries, id)

  @spec take_expired(t(), DateTime.t()) :: {[{id(), Reservation.t()}], t()}
  def take_expired(%__MODULE__{} = reservations, now) do
    {expired, live} =
      Map.split_with(reservations.entries, fn {_id, entry} ->
        DateTime.before?(entry.expires_at, now)
      end)

    {Map.to_list(expired), %{reservations | entries: live}}
  end
end
```

```elixir
# lib/my_app/inventory/sweeper.ex
defmodule MyApp.Inventory.Sweeper do
  defstruct timer: nil

  @type t :: %__MODULE__{timer: reference() | nil}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec rearm(t(), pos_integer()) :: t()
  def rearm(%__MODULE__{timer: nil} = sweeper, interval_ms) do
    arm(sweeper, interval_ms)
  end

  def rearm(%__MODULE__{timer: timer} = sweeper, interval_ms) do
    _ = Process.cancel_timer(timer)
    arm(%{sweeper | timer: nil}, interval_ms)
  end

  defp arm(%__MODULE__{} = sweeper, interval_ms)
       when is_integer(interval_ms) and interval_ms > 0 do
    timer = :erlang.start_timer(interval_ms, self(), :sweep)
    %{sweeper | timer: timer}
  end
end
```

```elixir
# lib/my_app/inventory/state.ex -- complete definition
defmodule MyApp.Inventory.State do
  alias MyApp.Inventory.{Config, Deps, Recounts, Reservations, Sweeper}

  @enforce_keys [:name, :config, :deps, :reservations, :recounts, :sweeper]

  defstruct [:name, :config, :deps, :reservations, :recounts, :sweeper]

  @type t :: %__MODULE__{
          name: GenServer.name() | nil,
          config: Config.t(),
          deps: Deps.t(),
          reservations: Reservations.t(),
          recounts: Recounts.t(),
          sweeper: Sweeper.t()
        }

  @spec new(map()) :: t()
  def new(%{name: name} = opts) do
    config = Config.from(opts)
    deps = Deps.from(opts)
    :ok = validate_components(config, deps)

    %__MODULE__{
      name: name,
      config: config,
      deps: deps,
      reservations: Reservations.new(config.max_reservations),
      recounts: Recounts.new(config.max_recounts),
      sweeper: Sweeper.new()
    }
  end

  defp validate_components(
         %Config{
           sweep_interval_ms: interval_ms,
           max_reservations: max_reservations,
           max_recounts: max_recounts
         },
         %Deps{}
       )
       when is_integer(interval_ms) and interval_ms > 0 and
              is_integer(max_reservations) and max_reservations > 0 and
              is_integer(max_recounts) and max_recounts > 0,
       do: :ok

  defp validate_components(_config, _deps),
    do: raise(ArgumentError, "invalid inventory state configuration or dependencies")
end
```

```elixir
# lib/my_app/inventory/impl.ex
alias MyApp.Inventory.{Reservation, Reservations, State, Stock, Sweeper}

@spec arm_sweep(State.t()) :: State.t()
def arm_sweep(%State{} = state) do
  sweeper = Sweeper.rearm(state.sweeper, state.config.sweep_interval_ms)
  %{state | sweeper: sweeper}
end

@spec sweep(State.t(), reference(), DateTime.t()) :: {[Reservations.id()], State.t()}
def sweep(
      %State{sweeper: %Sweeper{timer: timer_ref}} = state,
      timer_ref,
      now
    ) do
  {expired, reservations} = Reservations.take_expired(state.reservations, now)

  Enum.each(expired, fn {_id, %Reservation{sku: sku, quantity: quantity}} ->
    Stock.restock(state.deps.stock_table, sku, quantity)
  end)

  sweeper = Sweeper.rearm(state.sweeper, state.config.sweep_interval_ms)
  expired_ids = Enum.map(expired, &elem(&1, 0))

  {expired_ids, %{state | reservations: reservations, sweeper: sweeper}}
end

def sweep(%State{} = state, _stale_timer_ref, _now), do: {[], state}
```

**Wrong:**

```elixir
# lib/my_app/inventory/impl.ex, over a State that holds every concern flat:
# defstruct [:name, :config, :deps, entries: %{}, next_id: 1, sweep_timer: nil]
@spec sweep(State.t(), DateTime.t()) :: {[pos_integer()], State.t()}
def sweep(%State{} = state, now) do
  {expired, live} =
    Map.split_with(state.entries, fn {_id, entry} ->
      DateTime.before?(entry.expires_at, now)
    end)

  Process.cancel_timer(state.sweep_timer)
  timer = Process.send_after(self(), :sweep, state.config.sweep_interval_ms)

  {Map.keys(expired), %{state | entries: live, sweep_timer: timer}}
end
```

**Why:** Partitioning changes what struct patterns and inferred calls let the compiler reject. `Reservations.take_expired/2` receives `%Reservations{}`, so `%{reservations | sweep_timer: nil}` names a field that concern does not own. Passing `%State{}` where the function expects `%Reservations{}` is likewise an incompatible inferred call. A flat State declares every field on the same struct, so both concerns remain mechanically available to every whole-state transition even when its `@type t` is complete. Typespecs document the partition, but the struct heads and the calls between them establish the code boundary.

The timer reference is also the sweep generation. `State.new/1` constructs an unarmed `Sweeper`; the server's bounded `handle_continue/2` calls `Impl.arm_sweep/1` inside the owning process, as shown in ADR-005 Rule 1. `:erlang.start_timer/3` therefore targets that process and sends `{:timeout, timer_ref, :sweep}` to it. The server passes the reference into `Impl.sweep/3`, and only the reference currently stored in `Sweeper` is accepted. Canceling a timer cannot retract a timeout already delivered to the mailbox, so an older reference must be ignored. `Reservations.take_expired/2` returns each expired reservation with its id, preserving the SKU and quantity `Impl.sweep/3` needs to restock before it recombines State. `Sweeper.rearm/2` owns the changing timer state, while the configured interval remains in `Config` and is passed into the concern when it is rearmed.

### Rule 4: Keep the state struct private to the domain

State privacy is an architectural dependency boundary, not visibility enforced by the Elixir language. The API module, Server, Impl, concern modules, and direct transition tests inside the owning subsystem may name State. Production code outside that subsystem does not depend on it. No public function exists whose purpose is to hand a live State, or one of its fields, to a caller, and no test inspects State read from a running process. Field-level assertions run against Impl transitions over a value built through `State.new/1`; process-level assertions run through the public API. `elixir-conventions` ADR-004 Rule 3's opt-in JSON rule does not reach State, because a serialized process view is a separate public value deliberately built by the API, not the live State exposed wholesale.

**Correct:**

```elixir
# test/my_app/inventory/impl_test.exs
test "reserving coordinates stock and reservation concerns" do
  stock_table = :ets.new(:stock, [:set, :public])
  :ets.insert(stock_table, {"sku-1", 5})

  state =
    State.new(%{
      name: nil,
      stock_table: stock_table,
      task_supervisor: self(),
      sweep_interval_ms: 60_000,
      max_reservations: 100,
      max_recounts: 10
    })

  {{:ok, id}, state} = Impl.reserve(state, "sku-1", 3)

  assert Reservations.pending?(state.reservations, id)
  assert [{"sku-1", 2}] === :ets.lookup(stock_table, "sku-1")
end
```

```elixir
# test/my_app/inventory/server_test.exs
test "releasing a reservation returns its stock", %{server: server} do
  {:ok, id} = Inventory.reserve(server, "sku-1", 3)

  assert :ok = Inventory.release(server, id)
  assert {:ok, _id} = Inventory.reserve(server, "sku-1", 3)
end
```

**Wrong:**

```elixir
# lib/my_app/inventory.ex, added so that ServerTest can look at pending reservations
@spec state(GenServer.name()) :: State.t()
def state(name), do: GenServer.call(name, :state)
```

```elixir
# lib/my_app/checkout.ex, written against that accessor once it exists
def reserve_if_below_cap(name, sku, qty) do
  case map_size(Inventory.state(name).reservations.entries) do
    open when open < 100 -> Inventory.reserve(name, sku, qty)
    open -> {:error, ErrorMessage.too_many_requests("Reservation cap reached", %{open: open})}
  end
end
```

**Why:** An exported accessor is a contract whether or not it was meant as one. Once `MyApp.Inventory.state/1` exists, production callers can depend on private field names, and the partition Rule 3 bought becomes a cross-subsystem breaking change. The accessor is also unsafe to act on. A GenServer serializes transitions through its mailbox, so `Inventory.state/1` followed by `Inventory.reserve/3` is two messages with an arbitrary number of other messages between them. A read that a decision depends on belongs in the same message as the decision, handled by one callback over the state the process already holds.

Tests do not inspect the result of `:sys.get_state/2` or assert against its fields. ADR-011 permits one narrow use: while the target is executing its normal GenServer receive loop, discarding that result can form an ordering barrier for messages the same test process previously sent to the same live PID. It provides neither global quiescence nor ordering for timer, task, or third-party messages. Impl transitions need no live-state read at all: they take a State built by `State.new/1` and return the next one, so field-level assertions happen where those private fields are already in scope.

## Consequences

- Every GenServer gains a `State` module beside its Server and Impl, with a fully enumerated `@type t`, exact `@enforce_keys`, and one construction function. `init/1` and direct transition tests call `State.new/1`; no other code directly constructs `%State{}`.
- `defstruct`, `%State{} = state` heads, and `%{state | field: value}` updates keep the known-field boundary in force. Typespecs document field-value types and give Dialyzer information without pretending to enforce them.
- Configuration and injected collaborators sit behind their own fields, while changing state has one field per concern. `new/1` rebuilds all of them from validated opts and fresh concern constructors, making restart behavior explicit.
- Concern modules become where transitions live. The Impl function for a message reads as a recombination of per-concern results rather than as a simultaneous rewrite of eight fields.
- State privacy is an architectural boundary: public APIs return behavior and deliberate projections, never live State or its fields.
- Tests assert on direct Impl transitions and public API behavior. They never inspect `:sys.get_state/2`; its only permitted use is a discarded, same-sender ordering barrier with the limits stated above.
- No field-count, nesting-depth, or line-count threshold decides when a flat struct has become a bag, and none is invented here: each of those tracks the problem without identifying it. Rule 3 triggers on the number of concerns the process coordinates, not on the size of the struct. What partitioning produces is checkable even where the decision to partition stays a design judgement: once concerns are split, a function that takes one concern's struct can neither read nor write another's, and that either builds or it does not.


***

---
type: adr
id: 13
title: "Scope PubSub Topics to the Entity, Not the Event Type"
status: accepted
date: 2026-08-13
tags: [elixir, otp, pubsub, message-passing, performance, scheduling]
description: "Phoenix.PubSub sends once for each local subscription entry on a topic. When every entity both publishes to and subscribes to one event-type topic, delivery volume grows as N² even though each receiver discards the messages for other entities. Put the entity identifier in the topic so Registry lookup selects the interested subscribers before local delivery, and publish on state change rather than on a timer so the broadcast rate carries information."
---
# ADR-013: Scope PubSub Topics to the Entity, Not the Event Type

## Context

A PubSub topic is a routing key. For local delivery, `Phoenix.PubSub.broadcast/3` passes the topic to `Registry.dispatch/3`, and the default dispatcher calls `send/2` once for each local subscription entry returned for that topic. A broadcast to a topic with S local subscription entries therefore performs S local sends. A clustered adapter adds its own work to forward the broadcast to other nodes before each node performs that local dispatch.

The receiver's `handle_info/2` clauses are not part of the routing step. Pattern matching happens only after the message has reached that process's mailbox. Message terms generally have to be copied for delivery between processes (ADR-009), although reference-counted binaries and literals are shared and a process configured with `message_queue_data: :off_heap` can keep queued message data outside its heap. Whether delivery wakes a waiting process or appends to the mailbox of one that is already runnable, the receiver has already been selected and sent the message before its patterns can reject it.

The scaling problem appears when N entities each publish at an O(1) rate to one event-type topic and all N entity processes subscribe to it. There are O(N) broadcasts and O(N) local deliveries per broadcast, so aggregate delivery volume is O(N²). From inside any one receiver the waste looks like a cheap pattern mismatch, but the routing mistake happened before that mismatch ran.

Delivery volume on a topic is the product of two terms: how many subscribers the lookup returns, and how often something is broadcast to it. Topic naming decides the first. What triggers a publish decides the second, and a publisher driven by a timer rather than by a change contributes rate that no subscriber can act on. Both terms belong to the publisher, and the two rules below address them in that order.

## Decision

### Rule 1: Name a PubSub topic after the entity whose events it carries

When subscribers select one entity or another stable routing key, put that key in the topic. Do not subscribe every entity process to one event-type topic and recover the routing decision from the message payload.

**Correct:**

```elixir
# lib/my_app/builds/impl.ex
@spec publish(State.t(), Builds.event()) :: :ok | {:error, term()}
def publish(%State{} = state, event) do
  PubSub.broadcast(MyApp.PubSub, "build:#{state.build_id}", {:build_update, event})
end

# lib/my_app/builds/watcher.ex - one watcher process per build
@impl true
def init(build_id) do
  :ok = PubSub.subscribe(MyApp.PubSub, "build:#{build_id}")
  {:ok, State.new(build_id)}
end

@impl true
def handle_info({:build_update, event}, %State{} = state),
  do: {:noreply, Impl.apply_event(state, event)}
```

**Wrong:**

```elixir
# lib/my_app/builds/impl.ex
@spec publish(State.t(), Builds.event()) :: :ok | {:error, term()}
def publish(%State{} = state, event) do
  PubSub.broadcast(MyApp.PubSub, "build_events", {:build_update, state.build_id, event})
end

# lib/my_app/builds/watcher.ex - one watcher process per build
@impl true
def init(build_id) do
  :ok = PubSub.subscribe(MyApp.PubSub, "build_events")
  {:ok, State.new(build_id)}
end

@impl true
def handle_info({:build_update, id, event}, %State{build_id: id} = state),
  do: {:noreply, Impl.apply_event(state, event)}

def handle_info(_message, %State{} = state), do: {:noreply, state}
```

**Why:** `Phoenix.PubSub.broadcast/3` performs local delivery by dispatching the topic through its duplicate-key `Registry`; the default dispatcher then sends to every subscription entry stored under that key. In the Wrong version the shared key returns every build watcher, so the repeated `id` variable in the receiving pattern can reject an irrelevant event only after a send has already placed that event in the watcher's mailbox. With N builds publishing at a constant per-build rate and N watchers on `"build_events"`, the registry returns N entries for each of O(N) broadcasts, producing O(N²) local deliveries and N-1 irrelevant deliveries per broadcast. In the Correct version the registry lookup for `"build:#{build_id}"` returns only subscribers interested in that build, which eliminates the cross-talk term: no process is delivered an event for an entity it does not track. What remains is each entity's own fan-out to subscribers that genuinely want its events. That is a different quantity with different remedies, and it is frequently not a design parameter at all, since a build everyone is watching has the audience it has. Rule 2 addresses the side of it a publisher does control. Consumers that genuinely require an all-events stream need a separate, explicit delivery contract, but their existence is not a reason to place entity-specific consumers on the aggregate topic or to issue an unchecked second broadcast from every publisher.

### Rule 2: Publish when the entity's state changes, not on a fixed interval

A timer that republishes unchanged state takes the broadcast rate from the clock rather than from the domain. Compare against the last published value and skip the broadcast when nothing moved.

**Correct:**

```elixir
# lib/my_app/builds/server.ex
@tick :timer.seconds(10)

@impl true
def handle_info(:tick, %State{} = state) do
  Process.send_after(self(), :tick, @tick)
  {:noreply, state |> Impl.refresh_progress() |> Impl.publish_changes()}
end

# lib/my_app/builds/impl.ex
@spec publish_changes(State.t()) :: State.t()
def publish_changes(%State{published_status: status, status: status} = state), do: state

def publish_changes(%State{} = state) do
  _ = publish(state, state.status)
  %State{state | published_status: state.status}
end
```

**Wrong:**

```elixir
# lib/my_app/builds/server.ex
@tick :timer.seconds(10)

@impl true
def handle_info(:tick, %State{} = state) do
  state = Impl.refresh_progress(state)
  Impl.publish(state, state.status)
  Process.send_after(self(), :tick, @tick)
  {:noreply, state}
end
```

**Why:** Delivery volume on a topic is its broadcast rate multiplied by its subscriber count. Rule 1 removes the subscribers that never wanted the event; it does not remove the ones that did, and how many of those an entity has is often set by user behavior rather than by design. The broadcast rate is the term the publisher does control, and in the Wrong version that term comes from `@tick`: a build that holds the same status for ten minutes republishes it sixty times, and each of those broadcasts is delivered to every subscriber before any of them can observe that nothing changed. The first clause of `publish_changes/1` repeats a variable in the pattern, which binds on the first occurrence and matches on the second, so the head itself states the condition "this status has already been published." Suppressing at the publisher costs one comparison and removes a whole round of delivery. The same comparison in each receiver costs one per subscriber and runs only after delivery has already been paid for. This is also why a periodic refresh and a publication are separate steps: `refresh_progress/1` may need to run on every tick to keep the process's own state current, while publication is warranted only by a change worth telling anyone about.

## Consequences

- Topic names carry the stable key subscribers use to select events, so routing happens in the PubSub subscriber lookup rather than in every receiver's mailbox.
- Delivery volume is subscriber count times broadcast rate per topic. Entity topics remove the N² cross-talk term outright. A single entity's fan-out to its genuine subscribers is a separate problem, addressed on the rate side by Rule 2 and, when one entity's audience is large, by coalescing updates over a window or by having subscribers read shared state on their own cadence.
- A publisher that repeats unchanged state on a timer emits rate carrying no information. The guard belongs at the publisher, where one comparison suppresses an entire round of delivery.
- Receiving clauses assert the message shape expected on an already-routed topic instead of recovering the routing key from the payload.
- Cluster forwarding and local fan-out still cost work, so high-volume aggregate streams remain an explicit design choice rather than an accidental side effect of one consumer needing every event.

