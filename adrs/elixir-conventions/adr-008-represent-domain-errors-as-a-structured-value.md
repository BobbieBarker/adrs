---
type: adr
id: 8
title: Represent Domain Errors as a Structured Value
status: accepted
date: 2026-08-05
updated: 2026-08-09
tags: [elixir, errors, error-handling, result-tuples, contracts]
description: "Every expected domain or application failure is returned as `{:error, %ErrorMessage{}}` beside the function's success value. The error carries a supported status-category `code`, a public-safe `message`, and optional bounded diagnostic `details`. Bare strings and bare atoms are not application error values."
---

# ADR-008: Represent Domain Errors as a Structured Value

## Context

An application function whose declared contract represents an expected domain or application failure as data has to hand the caller something. The two shapes that arrive by default are both lossy. `{:error, "User not found"}` puts the failure in a string, so a caller who wants to branch on the kind of failure has to compare text, and an untested branch silently stops working when someone improves the wording. `{:error, :not_found}` fixes the matching and loses everything else: there is no sentence to show a user and nowhere to put deliberately selected diagnostic context, so the call site invents both, differently each time.

What a codebase needs from an expected error is three things at once. A stable category to match on. A safe sentence for the least-privileged intended reader. An optional, bounded place for selected diagnostic facts. Once those live in one internal value, boundary translation can be centralized instead of being invented per call site. That internal value is not itself a public response or a production log line; each boundary deliberately projects only fields appropriate to its audience.

This ADR fixes that value as a struct with `code`, `message`, and `details`. The `error_message` package on Hex provides it, along with status-named constructors and `http_code/1`, so most projects take the dependency rather than rewriting it. Nothing below depends on that package specifically: a project that declares its own three-field struct with the same discipline gets the same result. What matters is that application-owned code uses one shape, dependency-specific result forms are normalized at the first application-owned boundary, and the three fields keep their jobs. Unexpected exceptions, exits, and invariant violations still crash; they are not rescued merely to manufacture an `ErrorMessage`.

## Decision

Every declared expected failure returns a tagged tuple whose error member is a structured error value. Match on `code`, write `message` for its least-privileged intended reader, and put only approved diagnostic facts in `details`.

### Rule 1: Return `{:ok, value} | {:error, %ErrorMessage{}}` for every declared expected failure

An application-owned function whose contract represents an expected domain or application failure as data returns `{:ok, value}` or `{:error, %ErrorMessage{}}`. When success carries no payload, return `:ok` rather than `{:ok, nil}`. Say so in the `@spec` with `ErrorMessage.t_res(value_type)` or `ErrorMessage.t_ok_res()`. Normalize a dependency's result shape at the first application-owned boundary instead of leaking it through the call graph.

**Correct:**

Here `Store` is an application-owned adapter: its write function already returns `ErrorMessage.t_ok_res()`. `fetch_account/1` is the first owned boundary for the lookup result and normalizes the dependency-specific `:missing` value there.

```elixir
defmodule MyApp.Accounts do
  alias MyApp.Accounts.Account

  @spec fetch_account(Account.id()) :: ErrorMessage.t_res(Account.t())
  def fetch_account(id) do
    case Store.lookup(:accounts, id) do
      {:ok, account} -> {:ok, account}
      :missing -> {:error, ErrorMessage.not_found("Account not found", %{account_id: id})}
    end
  end

  @spec deactivate(Account.t()) :: ErrorMessage.t_ok_res()
  def deactivate(%Account{id: id, status: :closed}) do
    {:error, ErrorMessage.conflict("Account is already closed", %{account_id: id})}
  end

  def deactivate(%Account{} = account) do
    Store.put(:accounts, account.id, %{account | status: :closed})
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Accounts do
  alias MyApp.Accounts.Account

  def fetch_account(id) do
    case Store.lookup(:accounts, id) do
      {:ok, account} -> {:ok, account}
      :missing -> {:error, "Account not found"}
    end
  end

  def deactivate(%Account{status: :closed}), do: {:error, :already_closed}

  def deactivate(%Account{} = account) do
    Store.put(:accounts, account.id, %{account | status: :closed})
  end
end
```

**Why:** The two Wrong returns fail in opposite directions and a caller has to absorb both. `{:error, "Account not found"}` can only be matched by comparing the string, so a clause is coupled to copy and silently stops matching when that wording changes unless a test exercises the branch. `{:error, :already_closed}` matches cleanly and carries nothing else, so each caller invents a sentence and diagnostic context independently. The Correct version gives every caller one result shape. Its `@spec` documents that contract and gives Dialyzer information it can use to find provable inconsistencies; a typespec neither enforces the return shape nor guarantees every drift is reported, including at the function that introduced it. `t_ok_res()` describes the no-payload path, and returning `:ok` instead of `{:ok, nil}` keeps `with` chains from binding a value that means nothing (ADR-005 Rule 1).

This rule governs expected failures, not every way execution can stop. Do not rescue an unexpected exception, catch an exit, or absorb an invariant violation merely to return an `ErrorMessage`; let supervision and the owning boundary handle faults outside the declared result contract.

### Rule 2: Construct errors through the status-named constructors

Build new errors with a project-approved, package-supported 4xx or 5xx status constructor matching the boundary category. Common examples include `not_found/2`, `conflict/2`, `unprocessable_entity/2`, `unauthorized/2`, `forbidden/2`, `too_many_requests/2`, and `internal_server_error/2`; that list is illustrative, not closed. `service_unavailable/2` is also appropriate when an expected dependency failure makes the operation temporarily unavailable. Do not invent domain atoms such as `:account_not_found`.

**Correct:**

```elixir
{:error, ErrorMessage.not_found("Account not found", %{account_id: id})}
{:error, ErrorMessage.conflict("Email already registered", %{operation: :register_account})}

{:error,
 ErrorMessage.service_unavailable("Account service is unavailable", %{operation: :fetch_account})}

{:error, ErrorMessage.too_many_requests("Rate limit exceeded", %{retry_after_ms: 30_000})}
```

**Wrong:**

```elixir
{:error, %ErrorMessage{code: :account_not_found, message: "Account not found", details: %{}}}
{:error, %ErrorMessage{code: :duplicate, message: "Email already registered", details: %{}}}
{:error, %ErrorMessage{code: :validation_failed, message: "Invalid", details: %{}}}
```

**Why:** Supported categories let one owned translation boundary derive a status without maintaining a domain-code table. A status-named constructor fixes `code` and, by its arity, requires a message. Hand-writing a struct literal does not bypass `@enforce_keys`: the literal still requires the enforced keys to be present. But `@enforce_keys` accepts explicit `nil`, validates no value type, and cannot prove that the chosen status describes the failure. Constructors remove those opportunities when creating a new error. This construction rule does not prohibit legitimate `%ErrorMessage{}` patterns or updates to an error already received.

An invented code also fails differently than a catch-all clause suggests. A broad `{:error, %ErrorMessage{} = error}` boundary still matches the struct; the unsupported code later makes `ErrorMessage.http_code/1` raise while mapping it. It neither misses the broad struct clause nor automatically becomes a generic 500. Use the supported constructor vocabulary so that translation remains total for the values application code can produce.

`code` is a stable status category, not necessarily a unique domain cause. Several failures may correctly be `:conflict` or `:unprocessable_entity`. A genuine error with no narrower supported category uses an appropriate general status such as `internal_server_error` or `service_unavailable`. A genuine non-error outcome uses another tagged value. Compensation is orthogonal cleanup that preserves the original `ErrorMessage`, not an alternate error classification (ADR-007).

### Rule 3: Write `message` for the person reading it and put the context in `details`

`message` is safe for the least-privileged intended recipient and says what happened in that person's terms. `details` is optional, bounded, and allowlisted: it contains only deliberately selected diagnostic facts. Appropriate fields include an operation name, an entity identifier, normalized validation information, and a request or trace id. Do not place whole changesets or domain structs, credentials, tokens, authorization headers, raw params, or unfiltered provider request or response bodies in it. Neither field does the other's job.

**Correct:**

```elixir
{:error,
 ErrorMessage.unprocessable_entity(
   "Could not save your changes",
   %{
     operation: :update_user,
     user_id: user_id,
     validation_errors: normalize_validation_errors(changeset),
     request_id: request_id
   }
 )}
```

**Wrong:**

```elixir
{:error,
 ErrorMessage.unprocessable_entity(
   "Could not save changes (errors: #{inspect(changeset.errors)}, request: #{request_id})",
   %{}
 )}

{:error,
 ErrorMessage.unprocessable_entity(
   "duplicate key value violates unique constraint \"users_email_index\"",
   %{
     params: params,
     authorization: authorization_header,
     provider_response: provider_response
   }
 )}
```

**Why:** The struct does not enforce this split, which is why it has to be a rule. A message carrying interpolated validation data varies across occurrences, produces noisy grouping, and can expose internals. A database constraint name tells the intended reader nothing actionable and reveals schema detail. Moving raw inputs or provider payloads into `details` does not make them safe; it merely moves the leak. The Correct example selects the small facts needed to diagnose this operation and normalizes validation information before it crosses the boundary.

### Rule 4: Build an explicit projection at every boundary the error crosses

`%ErrorMessage{}` is the application's internal contract, not a response body and not a log line. At each boundary, name the fields that cross it. A public projection carries `code` and `message` and omits `details` unless specific keys have been approved for that audience; a diagnostic projection selects the `details` keys the operator needs.

**Correct:**

```elixir
defp public_error(%ErrorMessage{} = error) do
  %{error: %{code: error.code, message: error.message}}
end

defp report_error(%ErrorMessage{details: nil} = error),
  do: report_error(%ErrorMessage{error | details: %{}})

defp report_error(%ErrorMessage{details: details} = error) do
  Logger.warning("account operation failed",
    error_code: error.code,
    operation: Map.get(details, :operation),
    request_id: Map.get(details, :request_id)
  )
end
```

**Wrong:**

```elixir
json(conn, ErrorMessage.to_jsonable_map(error))
Logger.error("account operation failed: #{error}")
```

**Why:** Both Wrong lines publish `details` without deciding to. `to_jsonable_map/1` serializes the whole struct, `details` included, so anything Rule 3 put there for an operator reaches the client. The interpolation is the less obvious of the two: `ErrorMessage` implements `String.Chars`, and that implementation appends the details map, so `"#{error}"` on an error carrying a token or a raw parameter writes it into the log body as text. Neither line is a mistake a reviewer catches by reading it, because both look like ordinary rendering. An explicit projection makes the field list the reviewable artifact: adding a key to `details` for debugging cannot change what a client sees, because no code path carries the struct across the boundary whole. One fallback controller, channel handler, or job wrapper can still own this. Centralizing the translation means one place chooses the projection, not that the internal struct is rendered from one place.

## Consequences

- Every function with a declared expected failure documents `ErrorMessage.t_res(type)` or `ErrorMessage.t_ok_res()`. Dialyzer can use that information to find provable inconsistencies without pretending the contract is runtime enforcement.
- Dependency-specific result forms are normalized at the first application-owned boundary; unexpected exceptions, exits, and invariant violations still crash.
- `{:error, %ErrorMessage{code: :not_found}}` matches wherever that supported status category matters, without coupling callers to message text or inventing a unique atom for every domain cause.
- Boundaries translate errors in one owned place by constructing explicit public projections and selecting redacted diagnostic fields.
- `details` contains optional, bounded, allowlisted diagnostic facts; `message` remains safe for its least-privileged intended recipient.
- Bare strings and bare atoms are not error values. A `{:error, :something}` in a diff is a review comment.
- Genuine errors without a narrower supported category use an appropriate general status. Genuine non-errors use another tagged outcome, while compensation preserves the original structured error.
