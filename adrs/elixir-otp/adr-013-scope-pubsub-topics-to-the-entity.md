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
