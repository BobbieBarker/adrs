# Elixir Design Anti-Patterns - ADRs

ADRs codifying the official Elixir design-related anti-patterns: return-type consistency, boolean and primitive obsession, exceptions for control flow, unrelated multi-clause functions, and library configuration.

Source: https://github.com/BobbieBarker/adrs

---
type: adr
id: 1
title: "Alternative return types"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, design, api-design, return-types, typespecs]
description: "A function whose options change its return type forces its spec into a union of every possible shape that no caller can narrow, because the option selecting the shape is a runtime value. Give each return shape its own named function so each has a single, statically knowable return type."
---
# ADR-001: Alternative return types

## Context

This anti-pattern is a function that takes an options keyword list where one of those options changes the function's return type. The classic shape is a parser whose `:discard_rest` option flips the result between a bare `integer()` and a `{integer(), String.t()}` tuple.

Options are optional and are frequently built dynamically: merged from application config, request parameters, or computed defaults. When the value that selects the return shape is itself a runtime value, no caller can statically know which shape comes back without tracing where every option was set.

The mechanism is type resolution at the call site. Elixir resolves the return shape here at runtime, so the function's typespec degenerates into a union of every shape any option combination can produce (`integer() | {integer(), String.t()} | :error`). Nothing ties a given call site to a single member of that union, so both a human reader and the type checker must treat every call as possibly returning any member. The wider the union, the less a `case` on the result can be made exhaustive, and the more defensive every call site becomes.

## Decision

### Rule 1: One function name per return type

Give each return shape its own named function. Do not let an option select the return type.

**Correct:**

```elixir
defmodule MyApp.Parser do
  @spec parse(String.t()) :: {integer(), String.t()} | :error
  def parse(string) do
    Integer.parse(string)
  end

  @spec parse_discard_rest(String.t()) :: integer() | :error
  def parse_discard_rest(string) do
    case Integer.parse(string) do
      {int, _rest} -> int
      :error -> :error
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Parser do
  @spec parse(String.t(), keyword()) :: integer() | {integer(), String.t()} | :error
  def parse(string, options \\ []) when is_list(options) do
    if Keyword.get(options, :discard_rest, false) do
      case Integer.parse(string) do
        {int, _rest} -> int
        :error -> :error
      end
    else
      Integer.parse(string)
    end
  end
end
```

**Why:** In the wrong version the selecting option (`:discard_rest`) is a runtime value, so neither a reader nor the type checker can narrow the return at a call site. The spec collapses to a three-member union that every caller must defensively destructure, even though any concrete call returns exactly one shape. A `case` on the result cannot be made total, because the compiler cannot rule out the other members. Splitting into two named functions gives each a single, statically knowable return type: the name announces the shape, each spec is a smaller union, and the compiler's type inference can check each call site against one concrete return. Options remain appropriate for behavior that does not change the return type.

## Consequences

- Each function has one documented return type, and the function name announces which shape the caller gets.
- Specs narrow from a union-of-all-options into one type per function, so type inference and Dialyzer can check call sites instead of widening every caller to the full union.
- Callers pattern match the result exhaustively without inspecting which options were passed or where they were set.
- Options stay available for behavior that does not alter the return type; only the return-type-selecting option is removed.


***

---
type: adr
id: 2
title: "Boolean obsession"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, design, data-modeling, atoms]
description: "Multiple overlapping boolean options or struct fields encode one piece of state across 2^N representable combinations, most of which are invalid and must be resolved by hand-written priority logic. Replace them with a single atom field (or a composite type) whose values name only the valid states."
---
# ADR-002: Boolean obsession

## Context

Boolean obsession is using booleans to encode information that a richer type models better. The booleans themselves are not the problem. The problem appears when two or more booleans describe one underlying piece of state with overlapping or mutually exclusive values. N booleans make 2^N combinations representable, but usually only a few are valid. The invalid combinations do not disappear: they have to be excluded by hand, with priority logic that silently picks a winner when two flags are set at once.

A function taking `admin: true` and `editor: true` is the canonical case: two flags configuring one notion of access.

This is the boolean-typed case of the Primitive obsession anti-pattern; see it for the general rule. The fix is the same: replace the primitives with one type whose values name exactly the valid states. An atom suffices when those states form a flat enumeration; reach for a tuple or other composite type when the collapsed state is structured rather than a flat set of names.

## Decision

### Rule 1: Collapse overlapping booleans into a single atom

When several booleans encode one mutually exclusive state, replace them with one field whose atom values enumerate the valid states.

**Correct:**

```elixir
defmodule MyApp.Invoices do
  def process(invoice, options \\ []) do
    case Keyword.get(options, :role, :default) do
      :admin -> handle_admin(invoice)
      :editor -> handle_editor(invoice)
      :default -> handle_default(invoice)
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Invoices do
  def process(invoice, options \\ []) do
    cond do
      options[:admin] -> handle_admin(invoice)
      options[:editor] -> handle_editor(invoice)
      true -> handle_default(invoice)
    end
  end
end
```

**Why:** The two booleans admit four combinations, but only three are meaningful and `admin: true, editor: true` is a contradiction. The `cond` resolves that contradiction by clause order (admin wins), so the invalid state is reachable and the priority rule is invisible at the call site. A single `:role` atom makes only `:admin`, `:editor`, and `:default` representable: the contradiction cannot be constructed, and the `case` is exhaustive over the valid set. The same applies to data: a `User` struct carrying `:admin` and `:editor` booleans should carry one `:role` field, so the struct cannot hold an admin-and-editor record.

### Rule 2: Prefer a named state atom over a lone boolean that will grow

Even a single boolean argument is better expressed as an atom when the domain has, or will have, more than two states.

**Correct:**

```elixir
MyApp.Invoices.update(invoice, status: :approved)
```

**Wrong:**

```elixir
MyApp.Invoices.update(invoice, approved: true)
```

**Why:** `approved: true` hard-codes a binary into the contract. Adding a third state such as `:pending` forces either a second boolean (`pending: true`), which reintroduces the overlapping-combination problem from Rule 1, or a breaking change to the boolean's meaning. A `status:` atom extends by adding one clause and one atom value, with no new representable contradictions. It also reads at the call site: `status: :approved` states the domain concept, `approved: true` states an implementation detail. Because booleans are internally the atoms `:true`/`:false`, there is no performance difference between the two forms.

## Consequences

- Invalid flag combinations stop being representable, and the hand-written priority logic that used to resolve them disappears.
- Adding a state is a new atom value and a new clause, not another boolean that multiplies the combination space.
- `case` over the atom is exhaustive, so the compiler and Dialyzer can flag an unhandled state.


***

---
type: adr
id: 3
title: "Exceptions for control-flow"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, error-handling, control-flow, library-design]
description: "Driving expected control flow through raise and try/rescue captures a stacktrace and unwinds the stack on the normal path, and a rescue clause cannot tell an anticipated error from an unrelated bug it silently absorbs. Match result tuples with case, and have library functions return {:ok, value} | {:error, reason} with a bang variant built on top."
---
# ADR-003: Exceptions for control-flow

## Context

Exception handling is not itself an anti-pattern. The anti-pattern is using `raise` and `try/rescue` to drive ordinary, expected control flow instead of `case` and pattern matching on result tuples.

The mechanism matters. `raise` constructs an exception struct, captures a stacktrace by walking the current call stack, and then unwinds stack frames one by one until it reaches the nearest enclosing `try`. A tagged tuple like `{:error, reason}` is an ordinary return value matched in constant time by a `case`. Routing the expected branches of a computation through exceptions therefore pays stacktrace capture and stack unwinding on the normal path, where a `case` pays nothing.

A `rescue` clause matches by exception type, so it catches every exception of that type raised anywhere inside the protected block. It cannot distinguish the failure you anticipated (a missing file) from an unrelated bug raised by some other call in the same `try`. Pattern matching on `{:error, reason}` only matches the specific failure the callee declared, so a real bug still crashes loudly instead of being silently absorbed.

Whether a given error is exceptional is the caller's decision. A library that only raises removes that choice and forces every caller into `try/rescue`. The convention that preserves the choice: expose a function that returns `{:ok, value} | {:error, reason}`, and a bang variant (`foo!`) built on top that raises.

Raising directly is correct for structural errors, not semantic ones. `File.read(123)` should raise because `123` is never a valid filename. Tests, scripts, and one-off pipelines call the bang variants to fail fast with a clear message. Some frameworks (Phoenix) deliberately let code raise and convert those exceptions into responses through a protocol. The anti-pattern is specifically using exceptions for the expected, recoverable branches of normal flow.

## Decision

### Rule 1: Match result tuples; do not try/rescue an expected failure

**Correct:**

```elixir
defmodule MyApp.Reader do
  def print_file(file) do
    case File.read(file) do
      {:ok, binary} -> IO.puts(binary)
      {:error, reason} -> IO.puts(:stderr, "could not read file #{file}: #{reason}")
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.Reader do
  def print_file(file) do
    try do
      IO.puts(File.read!(file))
    rescue
      e -> IO.puts(:stderr, Exception.message(e))
    end
  end
end
```

**Why:** A missing file is an expected outcome of reading a file, not an exceptional one. The wrong version raises through `File.read!/1`, capturing a stacktrace and unwinding the stack on a branch that is part of normal operation, then rebuilds the message from the exception. The `rescue e ->` clause is also indiscriminate: it would swallow an unrelated exception raised by `IO.puts/1` or by any future code added to the `try` block, masking real bugs as if they were the missing-file case. `File.read/1` returns the failure as a value, so `case` selects the branch in constant time and only the declared `{:error, reason}` shape matches.

### Rule 2: Library authors expose a non-raising function and build the bang variant on top

**Correct:**

```elixir
defmodule MyApp.HTTP.Error do
  defexception [:reason]

  @impl true
  def message(%{reason: reason}), do: "request failed: #{inspect(reason)}"
end

defmodule MyApp.HTTP do
  def fetch(url) do
    case :httpc.request(url) do
      {:ok, resp} -> {:ok, build_response(resp)}
      {:error, reason} -> {:error, %MyApp.HTTP.Error{reason: reason}}
    end
  end

  def fetch!(url) do
    case fetch(url) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end
end
```

**Wrong:**

```elixir
defmodule MyApp.HTTP do
  def fetch!(url) do
    case :httpc.request(url) do
      {:ok, resp} -> build_response(resp)
      {:error, reason} -> raise "request failed: #{inspect(reason)}"
    end
  end
end
```

**Why:** When the only API raises, every caller that wants to treat a failed request as ordinary flow has no option but `try/rescue`, inheriting the stacktrace-capture, unwind, and bug-masking costs from Rule 1. Returning `{:error, Exception.t}` hands the decision back to the caller: code that wants to recover matches the tuple, and code that does want to fail re-raises with `raise error`. The bang variant is exactly that re-raise wrapped once in the library, so `fetch!/1` is implemented on top of `fetch/1` rather than the reverse.

## Consequences

- Expected failures travel as `{:error, reason}` values matched by `case`, with no stacktrace capture or stack unwinding on the normal path.
- `try/rescue` is reserved for genuinely exceptional conditions (invalid arguments, programmer error, boundary failures), where it catches only what is declared and does not absorb unrelated bugs.
- Library functions ship in pairs: a tuple-returning `foo` and a raising `foo!` built on top, so callers keep the choice of whether a given error is exceptional.
- Scripts, tests, and pipelines call the bang variant to fail fast with a clear message, while long-running code matches the tuple and recovers.


***

---
type: adr
id: 4
title: "Primitive obsession"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, design, data-modeling, structs]
description: "Carrying structured domain values (addresses, money) in bare strings or floats forces every consumer to re-parse and re-validate, because primitive guards like is_binary/1 match any value of the type. Parse once at the boundary into a struct, and model money as integer minor units or Decimal since IEEE 754 floats cannot represent decimal fractions exactly."
---
# ADR-004: Primitive obsession

## Context

Primitive obsession is the use of Elixir's basic types (integer, float, binary) to carry structured domain information that a composite type (tuple, map, or struct) would represent directly. An address flattened into a single string, or money held as a float, is the typical shape.

A primitive carries no shape. The guards that test it (`is_binary/1`, `is_float/1`) match every value of that type, so the pattern matcher cannot separate a valid address from arbitrary text, or a currency amount from any other float. Validity is therefore unenforceable at the boundary and gets re-derived inside every consumer: each function that needs a field re-parses the string. The repeated extraction is both a correctness hazard (every call site can parse differently) and dead work.

Holding money in a float is the same mistake: a float is the wrong representation for a value that must be exact.

## Decision

### Rule 1: Model structured values with a struct, parsed once at the boundary

**Correct:**

```elixir
defmodule MyApp.Address do
  defstruct [:street, :city, :state, :postal_code, :country]
end

defmodule MyApp do
  def parse(address) when is_binary(address) do
    # Returns %MyApp.Address{}
  end

  def extract_postal_code(%MyApp.Address{} = address) do
    address.postal_code
  end

  def fill_in_country(%MyApp.Address{} = address) do
    # Fill in missing country...
  end
end
```

**Wrong:**

```elixir
defmodule MyApp do
  def extract_postal_code(address) when is_binary(address) do
    # Re-parse the string to find the postal code...
  end

  def fill_in_country(address) when is_binary(address) do
    # Re-parse the string to find the country...
  end
end
```

**Why:** `is_binary(address)` matches every binary, so the guard cannot tell a real address from arbitrary text, and each function must re-parse the string to reach a field. Parsing once into `%MyApp.Address{}` moves extraction to a single place: downstream functions pattern-match the struct, so a wrong shape fails the function clause immediately instead of parsing garbage. A struct also fixes its key set at compile time, so `address.postal_code` and `%MyApp.Address{postal_code: code}` are checked against the definition. A misspelled field is a compile error, not the silent `nil` a free-form map returns from `Map.get/2`.

### Rule 2: Model money and currency with exact types, not floats

**Correct:**

```elixir
defmodule MyApp.Money do
  defstruct [:cents, :currency]

  def add_tax(%__MODULE__{cents: cents} = money, rate) do
    %{money | cents: round(cents * rate)}
  end
end

MyApp.Money.add_tax(%MyApp.Money{cents: 1000, currency: :usd}, 1.0825)
```

**Wrong:**

```elixir
def add_tax(price, rate) when is_float(price) do
  price * rate
end

add_tax(10.0, 1.0825)
```

**Why:** A `float` is an IEEE 754 double: it stores values in base 2, and decimal fractions like 0.1 and 0.2 have no exact binary representation, so `0.1 + 0.2` evaluates to `0.30000000000000004` and the error accumulates across operations. Holding the amount as an integer count of the smallest unit (cents), or as a `Decimal`, carries the value exactly; rounding happens explicitly and once. Pairing the amount with its `:currency` in a struct also prevents silently adding two different currencies, which a bare number permits.

## Consequences

- Parsing and validation happen once at the boundary. Downstream functions receive a typed struct and fail fast on the wrong shape via the function clause, instead of `is_binary/1` matching any binary.
- Field access is by key, checked against the struct definition, instead of re-extracting from a string on every call.
- Money arithmetic is exact: integer minor units or `Decimal` carry no representation error, and currency travels with the amount.
- The boolean-valued instance of this pattern (a bare `true`/`false` standing in for a domain state) is covered separately in ADR-002.


***

---
type: adr
id: 5
title: "Unrelated multi-clause function"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, design, multi-clause, pattern-matching]
description: "A multi-clause function shares one name, one @spec, and one @doc across every clause. Grouping unrelated behavior under that single contract widens the spec into a union of disjoint types that constrains no caller and forces the documentation into per-argument conditionals; split unrelated clauses into separately named functions."
---
# ADR-005: Unrelated multi-clause function

## Context

Multi-clause functions dispatch on the shape of their arguments by pattern matching on the function head. This is a core Elixir mechanism and the right tool when a single operation has variations (an empty list versus a non-empty one, a struct with one field value versus another). The anti-pattern appears when one function name is reused to host genuinely unrelated business logic, so each clause does something the other clauses have no relationship to.

The cost comes from the fact that the function name, not the individual clause, is the unit of contract. All clauses share one `@spec` and one `@doc`. When the behaviors are unrelated, the `@spec` widens to a union of disjoint types (`update(Product.t() | Animal.t())`) that no longer constrains callers, and the `@doc` degenerates into a conditional narration of how the function behaves per argument combination. That conditional documentation is the reliable tell: if you cannot describe the function without "if given an X, ...; if given a Y, ...", the clauses are unrelated and belong under separate names.

## Decision

### Rule 1: One function name, one operation

If two clauses implement unrelated business rules, give them distinct names (and, where the rules diverge enough, distinct modules).

**Correct:**

```elixir
@doc "Updates a product."
@spec update_product(Product.t()) :: Product.t()
def update_product(%Product{count: count, material: material}) do
  # ...
end

@doc "Updates an animal."
@spec update_animal(Animal.t()) :: Animal.t()
def update_animal(%Animal{count: count, skin: skin}) do
  # ...
end
```

**Wrong:**

```elixir
@doc """
Updates a struct.

If given a product, it reprices and restocks it.
If given an animal, it feeds and reweighs it.
"""
@spec update(Product.t() | Animal.t()) :: Product.t() | Animal.t()
def update(%Product{count: count, material: material}) do
  # ...
end

def update(%Animal{count: count, skin: skin}) do
  # ...
end
```

**Why:** All clauses of `update/1` share one `@spec` and one `@doc`. Because the behaviors are unrelated, the `@spec` widens to `Product.t() | Animal.t()`, so the type checker can no longer tell a caller that passed an animal that a product-shaped result is wrong: the union admits both. The single `@doc` collapses into per-argument conditionals, which is the diagnostic that the clauses do not belong together. Distinct names give each operation a precise spec, a self-describing doc, and a call site that states which behavior it invoked. Keep clauses under one name only when they are variations of a single operation (`update_product/1` may still match `%Product{count: 0}` against a `material` guard) or when the function behaves uniformly for every input (as `struct/2` does for any struct given); in both cases the shared contract stays coherent. Note that this refactoring renames the public function, so it ripples to every caller.

## Consequences

- Each operation carries a precise `@spec` instead of a union of disjoint types that constrains nothing.
- Documentation describes one behavior, not a conditional table keyed on argument shape.
- Call sites name the operation they invoke, so dispatch is visible at the call rather than hidden in the function head.
- The split renames a public function, so it is a breaking change to the function's contract and must be propagated to callers.
- Multi-clause dispatch is retained for genuinely related variations and for functions that behave uniformly across all inputs.


***

---
type: adr
id: 6
title: "Using application configuration for libraries"
status: accepted
date: '2026-06-28'
tags: [elixir, anti-pattern, configuration, library-design, application-environment, supervision]
description: "A library that reads its own configuration from the application environment exposes a single node-global value per key, so every consumer and every call site is locked into one behavior. Take configuration as function arguments, consumer-owned child specs, or required options on `use` instead."
---
# ADR-006: Using application configuration for libraries

## Context

The application environment (`Application.get_env/3`, `Application.fetch_env!/2`, `Application.compile_env/3`) is a node-global key-value store, indexed by application name and key, used to parameterize values across an Elixir system. It is a useful mechanism and not an anti-pattern by itself. The anti-pattern is a library author reaching for it to configure the library's own behavior.

Because the store is global, there is exactly one value for each `{application, key}` pair on the node. A library that reads its configuration from the application environment therefore exposes exactly one configurable value to the entire world: every application that depends on the library, and every call site within those applications, shares it. Two consumers of the same library cannot configure the same aspect differently, and a single consumer cannot vary it between two calls.

The fix in every case is to source configuration from the caller rather than from library-owned global state: function arguments for runtime values, consumer-owned child specs for processes, and required options on `use` for compile-time values. Each pushes the decision to the point where the library is consumed.

## Decision

### Rule 1: Take runtime configuration as function arguments

**Correct:**

```elixir
defmodule DashSplitter do
  def split(string, opts \\ []) when is_binary(string) and is_list(opts) do
    parts = Keyword.get(opts, :parts, 2)
    String.split(string, "-", parts: parts)
  end
end

# Each call site chooses its own behavior:
DashSplitter.split("a-b-c-d", parts: 3)
DashSplitter.split("a-b-c-d")
```

**Wrong:**

```elixir
# config/config.exs
config :dash_splitter, parts: 3

defmodule DashSplitter do
  def split(string) when is_binary(string) do
    parts = Application.fetch_env!(:dash_splitter, :parts)
    String.split(string, "-", parts: parts)
  end
end
```

**Why:** The application environment is a node-global store indexed by `{application, key}`, so a library that calls `Application.fetch_env!(:dash_splitter, :parts)` reads exactly one slot for the entire node. Every dependent application, and every call site within them, is forced into the same `parts` value, and a single caller cannot ask for three parts here and five parts there. A keyword list parameter moves the choice to the call site: the default lives in the function head and any caller overrides it per call. The legitimate exception is using the application environment to swap one behaviour-conforming dependency for another (for example, an alternate CSV parser): that is fine because the outcome must be identical regardless of which implementation is chosen.

### Rule 2: Expose a child spec instead of starting your own supervision tree

**Correct:**

```elixir
# The library provides a child spec; the consumer starts it under its own tree
# and reads its own application env only if it wants per-environment values.
children = [
  {DNSCluster, query: Application.get_env(:my_app, :dns_cluster_query) || :ignore}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

**Wrong:**

```elixir
# The library starts its own tree and reads global config to parameterize it.
defmodule DNSCluster.Application do
  use Application

  def start(_type, _args) do
    query = Application.fetch_env!(:dns_cluster, :query)
    children = [{DNSCluster.Worker, query: query}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

**Why:** An application starts exactly one supervision tree, so if the library starts its own and reads its options from the global application environment, those options are fixed once per node for all consumers. Exposing a child specification inverts ownership: the consumer lists the process under its own supervision tree and passes options at init time, reading its own application's environment only if and when it wants per-environment values. The library never forces the global lookup on anyone.

### Rule 3: Take compile-time configuration as options on `use`

**Correct:**

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, adapter: Ecto.Adapters.Postgres
end

# The consumer decides for itself whether to vary the value per environment:
defmodule MyApp.Repo do
  use Ecto.Repo, adapter: Application.compile_env(:my_app, :repo_adapter)
end
```

**Wrong:**

```elixir
# The library bakes one global adapter at compile time for every consumer.
defmodule Ecto.Repo do
  defmacro __using__(_opts) do
    quote do
      @adapter Application.compile_env(:ecto, :adapter)
      # ... a single repo, configured once for the whole node
    end
  end
end
```

**Why:** `Application.compile_env/3` is read once during compilation from the same node-global store and frozen into the compiled artifact, so a library that calls it internally bakes a single value for every consumer (for a repository library, that means one repo for the whole node). Requiring the value as an option on `use` generates the configured code per call site, so a consumer can define as many repositories as it needs and choose for itself whether to source each adapter from its own application environment. Code generation carries its own tradeoffs, so reserve it for configuration that genuinely must be fixed at compile time.

## Consequences

- Configuration lives at the call site (keyword lists), in the consumer's own supervision tree (child specs), or in the consumer's own module (`use` options), never in node-global application environment owned by the library.
- Multiple consumers, and multiple call sites within one consumer, configure the same library aspect independently.
- Library behavior is determined by its arguments, so tests do not mutate shared application environment between runs and can stay `async: true`.
- Acceptable residual uses remain: swapping a behaviour-conforming implementation, or providing customizable defaults when generating code from data files, where the chosen value does not change the outcome.
- Mix tasks read per-project configuration via `Mix.Project.config/0` or `OptionParser` command-line arguments rather than the global application environment.

