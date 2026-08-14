---
type: adr
id: 1
title: "Share Upstream Backpressure Within a Quota Bucket"
status: accepted
date: 2026-08-13
tags: [elixir, resilience, http, rate-limiting, backpressure, retry, finch, connection-pool]
description: "A 429 is evidence about a provider-defined quota bucket, whose scope may be a credential, tenant, resource, endpoint, or wider client identity. Preserve Retry-After in the structured error and extend a shared deadline keyed by that bucket before sending another request, instead of making each request independently rediscover a known cooldown."
---
# ADR-001: Share Upstream Backpressure Within a Quota Bucket

## Context

HTTP client libraries commonly model retry as a property of one request. `Req` accepts `:retry` and `:max_retries`, and a loop around `Finch.request/2` can implement the same policy by hand. That model fits an attempt-local failure such as a transient connection reset.

A 429 response carries different information: the server is rate limiting some category of requests. HTTP does not define the identity or counting scope behind that limit. Depending on the provider, the relevant quota bucket may be a credential, tenant, account, resource, endpoint class, node, or the client as a whole. Callers known to share that bucket should share the cooldown; unrelated buckets must not be stopped merely because one request received 429.

That coordination becomes impossible if the HTTP boundary funnels 429 into a generic error and discards its headers. It is also ineffective if each request sleeps and retries privately: other callers in the same bucket continue sending until each independently receives the same response. Some may already be in flight when the first 429 arrives, so a local gate cannot reduce those attempts, but it can prevent subsequent attempts from consuming connection-pool capacity and upstream work to rediscover a cooldown already known on that node.

## Decision

### Rule 1: Preserve `Retry-After` and the quota bucket in the structured error

Match 429 before the generic response branch. Parse `Retry-After` as either delay-seconds or an HTTP date, apply a documented fallback when it is absent or invalid, and carry the non-negative delay with the application-defined quota bucket.

**Correct:**

```elixir
# lib/my_app/upstream/rest.ex
@default_cooldown_ms :timer.seconds(30)

@spec post(Quota.bucket(), String.t(), map()) :: ErrorMessage.t_res(map())
def post(bucket, path, body) do
  case Finch.request(build(path, body), MyApp.Finch) do
    {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
      {:ok, decode(body)}

    {:ok, %Finch.Response{status: 429, headers: headers}} ->
      {:error,
       ErrorMessage.too_many_requests("upstream rate limit reached", %{
         quota_bucket: bucket,
         retry_after_ms: retry_after_ms(headers)
       })}

    {:ok, %Finch.Response{status: status}} ->
      {:error, ErrorMessage.bad_gateway("upstream rejected request", %{status: status})}

    {:error, exception} ->
      {:error,
       ErrorMessage.service_unavailable("upstream unreachable", %{reason: exception})}
  end
end

@spec retry_after_ms(Mint.Types.headers()) :: non_neg_integer()
defp retry_after_ms(headers) do
  case List.keyfind(headers, "retry-after", 0) do
    {_name, value} -> parse_retry_after_or_default(value)
    nil -> @default_cooldown_ms
  end
end

defp parse_retry_after_or_default(value) do
  case RetryAfter.parse_ms(value, DateTime.utc_now()) do
    {:ok, delay_ms} -> max(delay_ms, 0)
    {:error, _reason} -> @default_cooldown_ms
  end
end
```

**Wrong:**

```elixir
# lib/my_app/upstream/rest.ex
@spec post(String.t(), map()) :: ErrorMessage.t_res(map())
def post(path, body) do
  case Finch.request(build(path, body), MyApp.Finch) do
    {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
      {:ok, decode(body)}

    # 429 lands here with its headers and quota scope discarded.
    _response_or_error ->
      {:error, ErrorMessage.internal_server_error("upstream call failed", %{path: path})}
  end
end
```

**Why:** Finch exposes response headers as a list of binary name/value pairs, and Mint normalizes received header names to lowercase, so the Finch response boundary is where `"retry-after"` remains available. RFC 9110 permits either non-negative delay-seconds or an HTTP date; an HTTP-date parser must accept IMF-fixdate and the two obsolete date forms HTTP recipients are required to recognize. The Wrong version erases both the cooldown and the information needed to select who should observe it. The Correct version converts the header into a monotonic duration while wall-clock context is still available for the date form, then carries that duration and the provider-specific bucket as structured data. A delay of zero is valid, which is why the type is `non_neg_integer()` rather than `pos_integer()`.

### Rule 2: Extend a shared deadline keyed by quota bucket before sending

Check shared state before acquiring HTTP capacity. Serialize deadline updates and keep the later deadline when concurrent 429 responses propose different cooldowns. Prefer an existing keyed TTL cache when it provides atomic max/extend semantics; otherwise give an owned table a small API rather than exposing storage operations to callers.

**Correct:**

```elixir
# lib/my_app/upstream/gate.ex
defmodule MyApp.Upstream.Gate do
  use GenServer

  @table __MODULE__

  @type bucket :: term()
  @type check_result :: :open | {:closed, non_neg_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec check(bucket()) :: check_result()
  def check(bucket) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, bucket) do
      [{^bucket, deadline}] when deadline > now -> {:closed, deadline - now}
      _missing_or_expired -> :open
    end
  end

  @spec close_for(bucket(), non_neg_integer()) :: :ok
  def close_for(bucket, retry_after_ms) do
    deadline = System.monotonic_time(:millisecond) + retry_after_ms
    GenServer.call(__MODULE__, {:extend, bucket, deadline})
  end

  @impl true
  def init(:ok) do
    _table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:extend, bucket, proposed}, _from, state) do
    deadline =
      case :ets.lookup(@table, bucket) do
        [{^bucket, current}] -> max(current, proposed)
        [] -> proposed
      end

    true = :ets.insert(@table, {bucket, deadline})
    {:reply, :ok, state}
  end
end

# lib/my_app/upstream.ex
@spec post(Quota.bucket(), String.t(), map()) :: ErrorMessage.t_res(map())
def post(bucket, path, body) do
  case Gate.check(bucket) do
    :open -> bucket |> REST.post(path, body) |> record_result()

    {:closed, remaining_ms} ->
      {:error,
       ErrorMessage.too_many_requests("upstream rate limit in effect", %{
         quota_bucket: bucket,
         retry_after_ms: remaining_ms
       })}
  end
end

defp record_result({:error, %ErrorMessage{code: :too_many_requests, details: details}} = error) do
  :ok = Gate.close_for(details.quota_bucket, details.retry_after_ms)
  error
end

defp record_result(result), do: result
```

**Wrong:**

```elixir
# lib/my_app/upstream.ex - each request retries on its own schedule
@spec post(String.t(), map()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
def post(path, body) do
  Req.post(url(path), json: body, retry: :transient, max_retries: 5)
end
```

**Why:** Req's transient retry policy includes 429, and `max_retries: 5` permits as many as six total attempts for one call. That policy coordinates neither with other calls nor with other quota buckets. In the Correct version every request first performs a concurrent ETS read keyed by the bucket, while writes go through the table owner. `GenServer.call/3` serializes `handle_call/3`, so two concurrent responses cannot race an unconditional write: `max(current, proposed)` prevents a shorter later response from reopening the bucket before a longer known deadline. `System.monotonic_time/1` has an unspecified origin and can be negative, but differences and ordering between values from the same VM are suitable for deadlines and are not moved by wall-clock correction. Expired rows read as open; a bounded set of configured buckets can retain those rows, while an unbounded bucket space needs TTL eviction or a periodic sweep. The gate affects only requests that check it after the deadline has been recorded. Calls already in flight can still receive 429, and a caller rejected by the gate receives an error; it is not queued and does not resume automatically.

## Consequences

- A rate-limited response remains distinguishable from transport and upstream failures, and downstream code retains the server's requested cooldown.
- Backpressure is shared only among callers mapped to the same provider-defined quota bucket; unrelated credentials, tenants, resources, and endpoint classes remain independent.
- Concurrent 429 responses can extend but cannot shorten an outstanding cooldown.
- Subsequent calls fail before acquiring HTTP capacity, while calls already in flight are allowed to finish and may still report additional rate-limit responses.
- The gate is node-local and starts open after its owner restarts. A cluster-wide quota requires a store with equivalent keyed, monotonic-extension semantics or an intentionally conservative per-node allocation.
- The gate rejects calls rather than holding them. Any later retry or jitter policy belongs to the caller or a separate retry scheduler and is not implied by this decision.
