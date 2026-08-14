---
type: adr
id: 6
title: Use GenStage for Producer-Consumer Pipelines
status: accepted
date: '2026-04-29'
updated: '2026-08-09'
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
