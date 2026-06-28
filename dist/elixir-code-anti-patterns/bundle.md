# Elixir Code Anti-Patterns - ADRs

ADRs codifying the official Elixir code-related anti-patterns: comment overuse, with/else complexity, in-clause extraction, dynamic atoms, parameter lists, namespace trespassing, assertive access, and struct size.

Source: https://github.com/BobbieBarker/adrs

---
type: adr
id: 1
title: "Comments overuse"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, comments, documentation, readability, naming]
description: "Comments that restate self-explanatory code rot because the Elixir tokenizer discards them and nothing checks them against the code. Replace them with expressive names and module attributes, and move real contracts into `@doc`/`@moduledoc`, which compile into the BEAM Docs chunk and are testable as doctests."
---
# ADR-001: Comments overuse

## Context

Comments that restate self-explanatory code make code less readable, not more. They add visual lines a reader must scan past, and they carry a maintenance liability that the code itself does not.

The mechanism is the toolchain. The Elixir tokenizer discards every `#` comment before the compiler ever sees it, so nothing in the build checks a comment against the code beneath it. When the code changes and the comment does not, the comment silently lies, and a reader who trusts it is misled. Identifiers behave the opposite way: a function name, variable name, or module attribute is part of the program the compiler tracks, so it cannot drift out of sync with the behavior it names.

Elixir also draws a hard line between comments and documentation. `@moduledoc` and `@doc` compile into the BEAM Docs chunk and are reachable and testable at runtime; a `#` comment is none of that. So a comment that should be a contract belongs in `@doc`/`@moduledoc`, and a comment that merely narrates obvious code belongs nowhere.

## Decision

### Rule 1: Replace explanatory comments with expressive names

**Correct:**

```elixir
@five_min_in_seconds 60 * 5

defp unix_five_min_from_now do
  now = DateTime.utc_now()
  unix_now = DateTime.to_unix(now, :second)
  unix_now + @five_min_in_seconds
end
```

**Wrong:**

```elixir
# Returns the Unix timestamp of 5 minutes from the current time
defp unix_five_min_from_now do
  # Get the current time
  now = DateTime.utc_now()

  # Convert it to a Unix timestamp
  unix_now = DateTime.to_unix(now, :second)

  # Add five minutes in seconds
  unix_now + (60 * 5)
end
```

**Why:** Every comment in the wrong version restates information the function name, the variable names, and the function calls already carry. Because the tokenizer strips those comments, nothing keeps them honest as the code evolves, so they rot into false statements. The correct version moves the same intent into names the compiler tracks. Promoting `60 * 5` to `@five_min_in_seconds` supplies the one fact the raw expression did not: what that number means at the point it is used.

### Rule 2: Express contracts as documentation, not comments

**Correct:**

```elixir
defmodule MyApp.Accounts do
  @moduledoc "Public API for creating and authenticating users."

  @doc """
  Authenticates a user from an `email` and `password`.

  Returns `{:ok, user}` on success and `{:error, :unauthorized}` otherwise.
  """
  def authenticate(email, password) do
    with {:ok, user} <- fetch_by_email(email),
         :ok <- verify_password(user, password) do
      {:ok, user}
    end
  end
end
```

**Wrong:**

```elixir
# Public API for creating and authenticating users.
defmodule MyApp.Accounts do
  # Authenticates a user from an email and password.
  # Returns {:ok, user} on success and {:error, :unauthorized} otherwise.
  def authenticate(email, password) do
    with {:ok, user} <- fetch_by_email(email),
         :ok <- verify_password(user, password) do
      {:ok, user}
    end
  end
end
```

**Why:** The two versions read the same in source, but they compile to different artifacts. The `@moduledoc` and `@doc` text lands in the BEAM Docs chunk, so it is reachable through `h MyApp.Accounts`, through `Code.fetch_docs/1`, and through ExDoc, and `iex>` samples inside it run as doctests. The comment version is discarded by the tokenizer and is invisible to every one of those tools, untestable, and unreachable at runtime. A public contract written as a comment is a contract no tooling can surface or verify.

## Consequences

- Comments that restated code disappear; the names that replace them are tracked by the compiler and cannot drift out of sync with behavior.
- Magic numbers gain names through module attributes, making intent explicit at each use site.
- Public contracts live in `@doc`/`@moduledoc`, where the toolchain can surface and test them, instead of in comments no tool can reach.
- The comments that remain carry genuinely non-obvious context (a workaround rationale, a link to an external constraint), so the presence of a comment now signals something worth reading.


***

---
type: adr
id: 2
title: "Complex `else` clauses in `with`"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, with, error-handling, control-flow, readability]
description: "A `with` expression's single `else` block flattens the failures of every `<-` clause into one place, stripping the provenance of which clause failed and letting structurally similar errors collapse into the wrong catch-all. Normalize each step's return in a private function so `with` expresses only the success path."
---
# ADR-002: Complex `else` clauses in `with`

## Context

A `with` expression chains fallible steps with `<-`. When a step's value does not match the pattern on the left of its `<-`, the chain aborts and hands that non-matching value to the expression's single `else` block.

That single `else` is the problem. It receives the failure value from whichever clause aborted, stripped of any indication of which clause that was. Every `<-` in the chain funnels its failures into the same block, so the error-handling logic for unrelated steps is flattened together. Reading the `else`, you cannot tell which pattern on the left produced which branch on the right.

This degrades as the chain grows. Two steps that both fail with a structurally similar value (for example both returning `{:error, _}`) collapse into one catch-all clause in the `else`. A clause written to handle one step's failure silently captures another step's failure and maps it to the wrong reason. The more `<-` clauses a `with` has, the more likely unrelated failures overlap.

The fix is to give each fallible step a return shape that is unique and self-describing at its source, so `with` can express the success path alone and drop the `else` entirely.

## Decision

### Rule 1: Normalize each step's failure in a private function, not in a shared `else`

**Correct:**

```elixir
def open_decoded_file(path) do
  with {:ok, encoded} <- file_read(path),
       {:ok, decoded} <- base_decode64(encoded) do
    {:ok, String.trim(decoded)}
  end
end

defp file_read(path) do
  case File.read(path) do
    {:ok, contents} -> {:ok, contents}
    {:error, _} -> {:error, :badfile}
  end
end

defp base_decode64(contents) do
  case Base.decode64(contents) do
    {:ok, decoded} -> {:ok, decoded}
    :error -> {:error, :badencoding}
  end
end
```

**Wrong:**

```elixir
def open_decoded_file(path) do
  with {:ok, encoded} <- File.read(path),
       {:ok, decoded} <- Base.decode64(encoded) do
    {:ok, String.trim(decoded)}
  else
    {:error, _} -> {:error, :badfile}
    :error -> {:error, :badencoding}
  end
end
```

**Why:** In the wrong version the `else` block receives the aborting value from either `<-` clause with no record of which one fired. `File.read/1` failing with `{:error, _}` and `Base.decode64/1` failing with `:error` happen to be distinguishable here only because their shapes differ. Add a third step that also returns `{:error, _}` and it collapses into the existing `{:error, _} -> {:error, :badfile}` clause, mapping an unrelated failure to `:badfile` with no warning. Normalizing inside `file_read/1` and `base_decode64/1` attaches each failure reason at the exact site that produces it, so the shapes never compete for a shared clause. The `with` then has nothing to handle but the success case and the `else` disappears.

## Consequences

- `with` reads as the success path only; each step's failure is named at the function that produces it.
- Adding a step cannot silently re-route an existing step's error, because failures no longer share one catch-all clause.
- The normalizing functions are pure, independently testable, and reusable across other call sites.
- There is no `else` block to keep synchronized as the chain grows or reorders.


***

---
type: adr
id: 3
title: "Complex extractions in clauses"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, pattern-matching, multi-clause, readability, functions]
description: "A multi-clause function head should bind only the variables its patterns and guards use to select a clause. Extracting body-only struct or map fields in the head hides which bindings actually drive dispatch, because nothing distinguishes a selection variable from local plumbing in the signature."
---
# ADR-003: Complex extractions in clauses

## Context

A multi-clause function dispatches on its heads. Pattern matching and guards in a head decide which clause runs; every other binding in that head is plain local plumbing that happens to be written in the signature. Elixir lets you extract any number of fields from a struct or map argument directly in the head, and use those bindings either for dispatch or only inside the body.

That flexibility hides a readability cost. When extractions are spread across several clauses and several arguments, a reader can no longer tell at a glance which extracted variables participate in clause selection and which are merely consumed by the body. The head stops being a precise statement of the dispatch contract and becomes a mix of contract and data access. With many clauses, arguments, and extracted fields, recovering "what actually decides this clause" means diffing each head against its guard by eye.

The fix is to keep the head minimal: extract only the variables a pattern or guard needs, bind the whole argument with `= var`, and pull body-only fields out inside the body where they are used.

## Decision

### Rule 1: Extract only clause-deciding variables in the head

**Correct:**

```elixir
def drive(%User{age: age} = user) when age >= 18 do
  %User{name: name} = user
  "#{name} can drive"
end

def drive(%User{age: age} = user) when age < 18 do
  %User{name: name} = user
  "#{name} cannot drive"
end
```

**Wrong:**

```elixir
def drive(%User{name: name, age: age}) when age >= 18 do
  "#{name} can drive"
end

def drive(%User{name: name, age: age}) when age < 18 do
  "#{name} cannot drive"
end
```

**Why:** Only `age` decides which clause of `drive/1` runs; `name` is never matched on and never reaches a guard. In the wrong version the head binds both, so a reader scanning the signatures cannot separate the dispatch variable (`age`) from the body-only field (`name`) without reading the guard and the body to confirm. That conflation scales with the function: more clauses, more arguments, and more extracted fields turn every head into a puzzle about what is load-bearing for dispatch. The correct version makes the head the contract: `%User{age: age} = user` says "this clause matches on age," and `%User{name: name} = user` in the body binds the rest next to the code that consumes it.

## Consequences

- Each head reads as the dispatch contract: every binding in it either pattern-matches or feeds a guard.
- Body-only fields are bound where they are used, not announced in the signature.
- Adding a clause or an extracted field no longer forces re-reading every head to recover which variables drive selection.
- Multi-argument, multi-clause functions stay legible because the heads carry only selection logic.


***

---
type: adr
id: 4
title: "Dynamic atom creation"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, atoms, memory, security, input-validation]
description: "Converting uncontrolled external strings to atoms with String.to_atom/1 leaks atoms, which are never garbage collected and are capped at 1,048,576 per node. Map a fixed set with pattern matching, or guard open input with String.to_existing_atom/1."
---
# ADR-004: Dynamic atom creation

## Context

An atom is a basic Elixir type whose value is its own name. Atoms identify resources and express the state or result of an operation (`:ok`, `:error`, `:redirect`). Creating an atom is cheap and creating one dynamically is not wrong by itself.

The hazard is the atom table. Atoms are never garbage collected: once interned, an atom lives in memory for the entire lifetime of the VM. The BEAM caps the atom table at 1,048,576 entries by default. That ceiling is generous for every atom a program writes in its source, but it exists precisely to bound applications that leak atoms by minting them at runtime.

The leak appears when atoms are derived from values the developer does not control: a status field in an HTTP request, a key in a decoded JSON response, a name from an external system. `String.to_atom/1` (and the equivalent `List.to_atom/1` and `:erlang.binary_to_atom/2`) interns a fresh atom for every distinct string it has never seen. Pointed at attacker-controlled input, it converts request volume directly into permanent memory growth, and a few hundred thousand unique values exhaust the table and crash the node. The same function on trusted, finite input is harmless. The anti-pattern is specifically the case where the number of atoms created is unbounded because the input is unbounded.

## Decision

### Rule 1: Map a closed set of strings to atoms with pattern matching

When the valid values are a small, fixed set, match them explicitly. Each branch can also carry its own logic.

**Correct:**

```elixir
defmodule MyApp.RequestHandler do
  def parse(%{"status" => status, "message" => message}) do
    case status do
      "ok" -> %{status: :ok, message: message}
      "error" -> %{status: :error, message: message}
      "redirect" -> %{status: :redirect, message: message, code: 302}
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.RequestHandler do
  def parse(%{"status" => status, "message" => message}) do
    %{status: String.to_atom(status), message: message}
  end
end
```

**Why:** `status` comes off an external payload, so its set of values is unbounded. `String.to_atom/1` interns a new, never-collected atom for each distinct one, and the atom table is capped at 1,048,576 entries by default; an attacker who can send arbitrary status strings can fill that table and bring the node down. Pattern matching converts only the literals written in the source, so the atom count is fixed by the code and any unexpected value fails its clause loudly instead of growing memory.

### Rule 2: Guard open input with `String.to_existing_atom/1`

When the valid atoms are too many to enumerate inline but are known to already exist (struct fields, a schema's keys, atoms defined elsewhere in the program), convert through `String.to_existing_atom/1`.

**Correct:**

```elixir
defmodule MyApp.RequestHandler do
  def to_field(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, :unknown_field}
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.RequestHandler do
  def to_field(name) when is_binary(name) do
    String.to_atom(name)
  end
end
```

**Why:** `String.to_existing_atom/1` raises `ArgumentError` instead of interning when no matching atom is already in the table, so the atom count stays bounded by what the program defined at compile time no matter what arrives over the network. The caveat is code loading: the atom must already be referenced by loaded code (a literal, a module attribute, a struct field), or even a legitimate name raises. Prefer Rule 1 when the set is small and closed, since it needs no `rescue` and each value can branch independently.

## Consequences

- The number of atoms a node holds is bounded by source code, not by request volume or payload content.
- Input naming an unknown atom fails loudly (a failed clause or `ArgumentError`) instead of silently enlarging the never-collected atom table.
- The 1,048,576-entry atom-table ceiling stops being reachable from the network, closing a denial-of-service vector.
- Every accepted string resolves to an atom the compiler already interned.


***

---
type: adr
id: 5
title: "Long parameter list"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, function-design, api-design, maps]
description: "Functions with many positional parameters bind arguments by position, not by name, so same-typed parameters transpose silently with no MatchError or compiler warning. Group related arguments into a map or struct so each value is named at the call site, and split unrelated arguments into separate functions."
---
# ADR-005: Long parameter list

## Context

Elixir functions take all their inputs explicitly and return all their outputs, rather than reaching through shared mutable state. As a function accrues responsibility, its parameter count grows, and at some arity the interface becomes a memory test for the caller.

The mechanism that makes this dangerous is positional binding. Elixir matches arguments by position, not by name. When several adjacent parameters share a type (four strings in a row, two integers), transposing any two of them compiles cleanly, raises no `MatchError`, and triggers no compiler warning. The function runs with swapped values and the defect surfaces far downstream from the call site. Arity is also the ordering contract: every caller must reproduce the exact sequence, and every reorder or insertion is a breaking change across all of them.

The refactoring is to stop passing loose positional values. Group related arguments into a map or struct so each value is addressed by name, and split arguments that do not belong to one entity into separate functions.

## Decision

### Rule 1: Group related arguments into a map or struct

**Correct:**

```elixir
defmodule Library do
  def loan(user, book) when is_map(user) and is_map(book) do
    # reads user.email, book.title, ...
  end
end

# Caller names every value at the boundary:
Library.loan(
  %{name: name, email: email, password: password, alias: alias},
  %{title: title, ed: ed}
)
```

**Wrong:**

```elixir
defmodule Library do
  def loan(user_name, email, password, user_alias, book_title, book_ed) do
    # ...
  end
end

# email and password transposed: compiles clean, wrong at runtime.
Library.loan(name, password, email, alias, title, ed)
```

**Why:** In the six-arity version `email`, `password`, `user_alias`, `book_title`, and `book_ed` are all strings, so the transposed call binds the wrong value to each name with no `MatchError` and no warning. Grouping removes the positional slots that made the swap possible: in the literal `%{email: email, password: password}` written at the call site each value sits next to its own key, so transposing email and password is impossible by construction, there is no positional slot left to swap. Arity also drops from `loan/6` to `loan/2`, retiring the ordering contract every caller had to reproduce. Bind each group to a single variable and read its fields in the body rather than destructuring every key in the head (see ADR-003); if a grouping struct grows past the field count in ADR-010, that is a separate concern. For a private function, one mechanical split is two maps: one for data that changes and one for read-only data. Keep optional inputs in a trailing keyword list so adding one does not change arity.

### Rule 2: Split unrelated arguments into separate functions

**Correct:**

```elixir
defmodule Report do
  def build(rows, opts) do
    rows
    |> sort(opts.sort_key)
    |> paginate(opts.page_size)
    |> format(opts.locale, opts.currency)
  end
end

# Delivery is a separate responsibility, not a parameter of build:
defmodule Report.Mailer do
  def deliver(report, recipient, host) do
    # ...
  end
end
```

**Wrong:**

```elixir
defmodule Report do
  # Sorting, pagination, formatting, and delivery in one head.
  def generate(rows, sort_key, page_size, locale, currency, smtp_host, recipient) do
    # ...
  end
end
```

**Why:** When half a dozen parameters do not share a domain entity, the arity is counting responsibilities, not one entity's fields, and the function is trying to do too much. Forcing `smtp_host` and `recipient` into the same map as `sort_key` would be a false grouping the data does not justify. Each independent parameter is a separate axis of change, so a function that holds all of them has multiple reasons to change. Splitting gives `build/2` only the report-shaping inputs and `deliver/3` only the delivery inputs, so each function changes for one reason and composes with the others through the pipe.

## Consequences

- Call sites name each value next to its key, so transposing two same-typed arguments is impossible by construction instead of compiling into swapped data.
- Arity drops (`loan/6` becomes `loan/2`), removing the positional ordering contract callers had to memorize.
- Optional inputs live in a trailing keyword list, so adding one does not change arity or break existing callers.
- Functions whose parameters do not share a domain entity get split, surfacing multi-responsibility that the long signature was hiding.


***

---
type: adr
id: 6
title: "Namespace trespassing"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, modules, libraries, code-loading]
description: "A library must define every module under a prefix derived from its own package name, because the BEAM loads exactly one module per fully qualified name per node, so two libraries defining the same name become mutually incompatible."
---
# ADR-006: Namespace trespassing

## Context

The BEAM identifies a module by its fully qualified name, which is an atom. At any instant the virtual machine holds exactly one loaded instance per module name across the entire node. Two libraries that both define a module under the same name cannot coexist in a single release: code loading is keyed on the name alone, so whichever beam file loads wins and the other library silently runs against an implementation it did not write.

A library prevents this by treating its own name as a prefix and defining every module beneath it. A package named `:my_lib` defines `MyLib`, `MyLib.User`, `MyLib.Application`, and nothing outside the `MyLib` namespace. The prefix is the only thing that makes the names globally unique, because the runtime has no per-library scoping. Defining a module outside your own namespace, trespassing into a namespace owned by another package or the standard library, is the anti-pattern.

The hazard is latent and lands on someone else. An extension package `:plug_auth` that defines `Plug.Auth` works fine until `Plug` itself ships a `Plug.Auth` module in a later release. From that point the two packages define the same name and become mutually incompatible, and the clash surfaces at a downstream user's dependency resolution rather than at your build.

## Decision

### Rule 1: Prefix every module with your library's name

**Correct:**

```elixir
# package :plug_auth
defmodule PlugAuth do
  # ...
end

defmodule PlugAuth.Pipeline do
  # ...
end
```

**Wrong:**

```elixir
# package :plug_auth
defmodule Plug.Auth do
  # ...
end
```

**Why:** The BEAM loads exactly one module per fully qualified name per node. If `Plug` later defines its own `Plug.Auth`, the two definitions collide and the libraries cannot be used together, with the loaded one shadowing the other. A unique top-level prefix derived from the package name is the only guarantee against this collision. Three exceptions are sanctioned: protocol implementations are defined under the protocol's namespace by design (`defimpl`); a namespace owner may explicitly invite extensions into a sub-namespace, as Elixir does with custom Mix tasks under `Mix.Tasks.*`; and if you maintain both packages, you may share a namespace and own the responsibility for any future conflict.

## Consequences

- Two of your library's modules can never clash with a third party's, because the unique prefix is carried by every name.
- Module names read as self-documenting ownership: the prefix tells a reader and a tool which package a module belongs to.
- Extensions of another library (`:plug_auth`, `:ecto_enum`) carry their own root namespace instead of borrowing the host's.
- The sanctioned exceptions stay narrow: `defimpl`, owner-invited sub-namespaces such as `Mix.Tasks.*`, and packages you maintain on both sides of the boundary.


***

---
type: adr
id: 7
title: "Non-assertive map access"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, maps, access, assertiveness, structs]
description: "Access required map keys with static `map.key`, which raises `KeyError` at the access site, and reserve dynamic `map[:key]` for optional keys. Dynamic access on a missing required key returns `nil` through the Access behaviour, deferring the crash far from its cause."
---
# ADR-007: Non-assertive map access

## Context

Elixir maps expose two access notations, and they are not interchangeable. `map.key` compiles to a call that returns the value when the key exists and raises `KeyError` when it does not. For structs, whose field set is known at compile time, the compiler can additionally warn on a misspelled field before the code ever runs. `map[:key]` instead routes through the `Access` behaviour: it returns the value when the key exists and `nil` when it does not. It also supports runtime keys such as `map[some_var]`, which static access cannot.

The anti-pattern is reaching for the dynamic `map[:key]` form on a key that is always supposed to be there. Because dynamic access cannot raise on a missing key, an absent required key yields `nil` instead of a crash. That `nil` then propagates through unrelated code and surfaces as a failure far from its cause (for example an `ArithmeticError` deep inside a later calculation), where the original mistake (a caller that built an incomplete map) is no longer visible. The notation also erases intent: a reader and the compiler can no longer tell which keys the function requires and which it merely tolerates.

## Decision

### Rule 1: Access required keys statically with `map.key`

**Correct:**

```elixir
defmodule MyApp.Geometry do
  # Every point must carry :x and :y.
  def magnitude(point) do
    :math.sqrt(point.x * point.x + point.y * point.y)
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Geometry do
  def magnitude(point) do
    :math.sqrt(point[:x] * point[:x] + point[:y] * point[:y])
  end
end
```

**Why:** `point[:x]` goes through the `Access` behaviour and returns `nil` when `:x` is absent. A missing required key therefore produces `nil`, which feeds the multiplication and raises `ArithmeticError` on `nil * nil`, far from the caller that actually built the bad map. `point.x` raises `KeyError` at the access site the instant the key is missing, naming the key and the map, and for structs the compiler warns on a typo'd field at compile time. When you need to assert several required keys at once, pattern match them in the function head (`def magnitude(%{x: x, y: y})`), which is the assertive form covered by ADR-008.

### Rule 2: Access optional keys dynamically with `map[:key]`

**Correct:**

```elixir
defmodule MyApp.Geometry do
  # :z is present only for 3D points.
  def depth(point), do: point[:z]
end
```

**Wrong:**

```elixir
defmodule MyApp.Geometry do
  def depth(point), do: point.z
end
```

**Why:** `point.z` raises `KeyError` whenever `:z` is missing. For a genuinely optional key that is wrong: absence is a valid state and should yield `nil`, not a crash. `point[:z]` returns `nil` through the `Access` behaviour for a missing key, which is exactly the optional semantics you want. Reserve static access for keys whose absence is a bug and dynamic access for keys whose absence is allowed. When the default for a missing optional key is something other than `nil`, use `Map.get(point, :z, default)` rather than overloading either notation.

## Consequences

- A missing required key raises `KeyError` at the access site, not after a `nil` has travelled through unrelated code and crashed somewhere else.
- The access notation documents, per key, whether that key is required (`map.key`) or optional (`map[:key]`), making the function's expectations legible to readers and the compiler.
- Under static access on structs, the compiler warns on misspelled or non-existent fields at compile time.
- For data shared across modules, an `@enforce_keys` struct makes required keys static by default and raises on construction. This adds a compile-time dependency: a change to the struct's fields forces dependent modules to recompile. Weigh that (and field-count limits) before defining wide structs; see ADR-010.
- Dynamic access stays where it belongs: optional keys and `Access`-based traversal with runtime keys (`map[some_var]`).


***

---
type: adr
id: 8
title: "Non-assertive pattern matching"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, pattern-matching, error-handling, assertive-code]
description: "Defensive accessors like Enum.at/2 and catch-all `_` clauses return a plausible value for malformed or unexpected input instead of failing, so corruption escapes the process that produced it. Destructure with a match and enumerate the expected case clauses so a mismatch raises a localized MatchError or CaseClauseError the supervisor can act on."
---
# ADR-008: Non-assertive pattern matching

## Context

Elixir systems are built from many supervised processes. An error in one process is localized: the supervisor detects it, reports it, and can restart the process while the rest of the application keeps running. That containment only works if errors actually surface. Code that defends against malformed input by returning a plausible-looking value instead of failing defeats containment, because the bad value escapes the process that produced it and corrupts callers far from the source.

The BEAM offers assertive constructs for exactly this: a match with `=`, function-head and `case/2` patterns, and guards. A failed match raises `MatchError` (or `CaseClauseError`) at the precise line of the mismatch, with the offending value in the message. That is a loud, localized failure a supervisor can act on. Defensive accessors like `Enum.at/2`, which returns `nil` for an out-of-range index, instead convert a structural violation into a silent wrong answer that looks like success.

This is the pattern-matching sibling of ADR-007 Non-assertive map access, which covers reading keys out of maps.

## Decision

### Rule 1: Destructure with a match, not positional accessors

**Correct:**

```elixir
defmodule MyApp.Extract do
  def get_value(query_string, desired_key) do
    query_string
    |> String.split("&")
    |> Enum.find_value(fn pair ->
      [key, value] = String.split(pair, "=")
      key == desired_key && value
    end)
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Extract do
  def get_value(query_string, desired_key) do
    query_string
    |> String.split("&")
    |> Enum.find_value(fn pair ->
      key_value = String.split(pair, "=")
      Enum.at(key_value, 0) == desired_key && Enum.at(key_value, 1)
    end)
  end
end
```

**Why:** A well-formed pair `"lab=ASERG"` splits to `["lab", "ASERG"]`, but a malformed segment `"university=institution=UFMG"` splits to `["university", "institution", "UFMG"]`. `Enum.at/2` never fails on the malformed list: it reads index 0 and index 1 and reports `"institution"` as the value, so `get_value/2` returns a wrong answer that looks correct and propagates to its caller. The match `[key, value] = String.split(pair, "=")` asserts exactly two parts and raises `MatchError` on anything else, naming the offending list in the message. The crash is localized to the process that hit it and hands the decision (treat as invalid, or handle a newly discovered case) back to the caller instead of silently emitting corrupt data.

### Rule 2: Match every expected return shape, not a catch-all `_`

**Correct:**

```elixir
case MyApp.Accounts.fetch_user(id) do
  {:ok, user} -> render(user)
  {:error, _reason} -> render_error()
end
```

**Wrong:**

```elixir
case MyApp.Accounts.fetch_user(id) do
  {:ok, user} -> render(user)
  _ -> render_error()
end
```

**Why:** A bare `_` clause matches any value, so it absorbs return shapes the author never considered. If `fetch_user/1` later gains a `{:pending, token}` return, the catch-all swallows it and renders an error for a non-error result, with no crash to point at the regression. The correct version asserts the `{:error, _reason}` tuple shape (only the unused reason is wildcarded) and leaves any unanticipated shape unmatched, so a new return raises `CaseClauseError` at the call site. That loud, localized failure is the signal that the contract changed. Reserve `_` for the inner values that are genuinely irrelevant, not for the whole result.

## Consequences

- Malformed input crashes at the line that destructures it, naming the offending value, instead of producing a plausible wrong answer somewhere downstream.
- Failures stay inside the process that hit them, where the supervisor can report and restart, rather than propagating corrupt data to callers.
- Adding a new return shape to a matched function surfaces as a `CaseClauseError` at every call site that did not handle it, instead of being silently captured by `_`.
- Wildcards are reserved for values that are genuinely unused, keeping each clause's intent explicit.


***

---
type: adr
id: 9
title: "Non-assertive truthiness"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, truthiness, booleans, erlang-interop, assertive-code]
description: "Elixir's `&&/2`, `||/2`, and `!/1` operate on truthiness and silently coerce any non-`nil`, non-`false` term as true. When operands are guaranteed booleans, use `and/2`, `or/2`, and `not/1`, which require a boolean operand and raise `BadBooleanError` otherwise, catching unexpected non-boolean values such as Erlang's `:undefined` at the boundary."
---
# ADR-009: Non-assertive truthiness

## Context

Elixir has truthiness: `nil` and `false` are falsy, every other term is truthy. The operators `&&/2`, `||/2`, and `!/1` are built on truthiness. They accept any term, treat only `nil` and `false` as falsy, and short-circuit on that basis. Using them on genuinely truthy values is correct and idiomatic. The anti-pattern is reaching for them when every operand is already expected to be a boolean.

Elixir also provides `and/2`, `or/2`, and `not/1`. These assert their operand is a boolean: `and/2` and `or/2` require the left operand to be `true` or `false` and raise `BadBooleanError` on anything else, and `not/1` raises `ArgumentError` on a non-boolean. They compile to the BEAM `andalso`, `orelse`, and `not` operators and are allowed in guards, which the truthiness operators are not. Choosing them where booleans are guaranteed promotes the operand's type from an assumption to an enforced contract.

The risk is sharpest at Erlang boundaries. Erlang has no concept of truthiness and never returns `nil`; its functions return `:error`, `:undefined`, or other atoms in places an Elixir function would return `nil` or `false`. Every such atom except `false` is truthy, so a truthiness operator silently accepts an unexpected `:undefined` or `:error` as a real value. This is the truthiness member of the assertive-code family; see ADR-007 for map access and ADR-008 for pattern matching.

## Decision

### Rule 1: Use `and`/`or`/`not` when operands are booleans

When every operand is known to be a boolean (typically the result of a type guard or a predicate), use the strict boolean operators.

**Correct:**

```elixir
if is_binary(name) and is_integer(age) do
  greet(name, age)
else
  reject()
end
```

**Wrong:**

```elixir
if is_binary(name) && is_integer(age) do
  greet(name, age)
else
  reject()
end
```

**Why:** `is_binary/1` and `is_integer/1` always return a boolean. `&&/2` is the truthiness operator: it accepts any term and treats everything except `nil` and `false` as true. Using it where booleans are guaranteed is more permissive than the code needs and hides the contract that the operands are booleans. `and/2` requires its left operand to be `true` or `false` and raises `BadBooleanError` otherwise, so it both documents the boolean contract and turns a future non-boolean operand into an immediate crash instead of a silent truthy coercion. `and/2` compiles to the BEAM `andalso` short-circuit and is permitted in guards; `&&/2` is neither.

### Rule 2: Use the strict operators at Erlang boundaries

When a value comes from an Erlang API, combine it with the strict operators so an unexpected non-boolean fails loud.

**Correct:**

```elixir
defp authorized?(token) do
  # :my_authz.check/1 returns true | false | :undefined
  :my_authz.check(token) or admin_override?()
end
```

**Wrong:**

```elixir
defp authorized?(token) do
  :my_authz.check(token) || admin_override?()
end
```

**Why:** Erlang has no truthiness and never returns `nil`; `check/1` can return `:undefined`. To `||/2` the atom `:undefined` is truthy, so the wrong version short-circuits and returns `:undefined`, and the caller treats authorization as granted on a value that signals "no answer." `or/2` requires a boolean left operand and raises `BadBooleanError` on `:undefined`, converting a silent misinterpretation into a loud failure exactly at the boundary where the unexpected shape entered. The same reasoning applies to `and/2` and `not/1` against any Erlang return that may be `:error`, `:undefined`, or another non-boolean atom.

## Consequences

- Boolean expressions raise `BadBooleanError` (or `ArgumentError` for `not/1`) on a non-boolean operand instead of silently coercing it as true.
- The operator choice documents intent: `&&`/`||`/`!` mark a genuinely truthy value, `and`/`or`/`not` mark a guaranteed boolean.
- Erlang return values such as `:undefined` and `:error` fail at the boundary instead of propagating through the system as truthy.
- Because `and/2`, `or/2`, and `not/1` are guard-safe and compile to BEAM short-circuit operators, the same expressions can move into guards unchanged.


***

---
type: adr
id: 10
title: "Structs with 32 fields or more"
status: accepted
date: 2026-06-28
tags: [elixir, anti-pattern, structs, memory, performance, data-modeling]
description: "A struct with 32 or more declared fields crosses the BEAM threshold from flat-map to hash-map representation, losing per-update key-tuple sharing and the compile-time key tuple shared across instances, which raises memory use. Keep declared fields under 32 by nesting optional or rarely-touched fields."
---
# ADR-010: Structs with 32 fields or more

## Context

A struct is a compile-time map with a fixed set of keys plus a hidden `__struct__` metadata key. The BEAM has two internal map representations: a flat map and a hash map. A flat map is stored as two tuples, one holding the keys and one holding the values. A hash map (a HAMT) has a more elaborate node structure that scales to large key counts but does not share its key space.

The VM uses a flat map for up to 32 keys and a hash map above that. Because a struct carries the extra `__struct__` key, the practical ceiling is 31 declared fields. A struct at or above 32 declared fields crosses into hash-map representation, and two optimizations disappear at once. First, updating a flat map (`%s{field: v}`) reuses the existing key tuple and allocates only a new values tuple, so the keys are never recopied. Second, every instance of a given struct constructed inside the same module shares one key tuple fixed at compile time, so building many structs with `%MyStruct{...}` notation does not re-pay for the keys each time. A hash-map struct loses both: keys are no longer shared on update, and instances no longer share a compile-time key tuple.

The fix is structural, not cosmetic. Keep the declared field count under 32 by grouping fields into nested data so the top-level struct stays a flat map.

## Decision

### Rule 1: Keep a struct under 32 declared fields

**Correct:**

```elixir
defmodule MyApp.Account do
  # 8 declared fields: stays a flat map.
  defstruct [
    :id,
    :email,
    :name,
    :status,
    profile: %{},
    billing: %{},
    preferences: %{},
    metadata: %{}
  ]
end
```

**Wrong:**

```elixir
defmodule MyApp.Account do
  # 35 declared fields: forced into hash-map representation.
  defstruct [
    :id,
    :email,
    :name,
    :status,
    :phone,
    :avatar_url,
    :timezone,
    :locale,
    :billing_street,
    :billing_city,
    :billing_zip,
    :marketing_opt_in,
    :last_login_at
    # ...and 22 more fields (35 total)
  ]
end
```

**Why:** At 35 declared fields the VM represents `%MyApp.Account{}` as a hash map. Updating it (`%{account | status: :active}`) no longer shares the key tuple, so each update copies keys as well as values, and the many account structs built inside one module no longer share a single compile-time key tuple. The flat-map version keeps both forms of sharing. Three techniques bring the count back under the threshold: nest optional fields (those initialized to `nil`) under a `:metadata` or `:optionals` key, which also lets you pattern match on presence instead of probing for `nil`; nest rarely read or written fields into a nested struct; and collapse fields that are always accessed together (`billing_street`, `billing_city`, `billing_zip`) into a tuple or composite. Balance the grouping against ergonomics: fields that are read and written frequently are poor candidates for nesting.

## Consequences

- The struct stays a flat map, so `%s{field: v}` updates reuse the shared key tuple and allocate only a new values tuple.
- Many instances built inside one module share a single compile-time key tuple, cutting the memory cost of construction.
- Optional fields nested under `:metadata` become matchable by presence rather than by a sentinel `nil`.
- Grouping is a deliberate API tradeoff: frequently accessed fields stay top level, while cold or co-accessed fields move into nested maps, structs, or tuples.

