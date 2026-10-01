---
type: adr
id: 1
title: Design Modules for Information Hiding, High Cohesion, and Low Coupling
status: accepted
date: '2026-09-30'
tags: [software-design, modules, information-hiding, cohesion, coupling, decomposition, language-agnostic]
description: "Organize modules around cohesive responsibilities, hide implementation choices behind useful interfaces, and limit dependencies between concerns that change independently. Establish ownership as part of each change. Judge a boundary by the knowledge and coordination it removes, including when keeping related code together produces the better design."
---

# ADR-001: Design Modules for Information Hiding, High Cohesion, and Low Coupling

## Context

A system is easier to change when a developer can understand a responsibility
without reconstructing the surrounding system. Dividing code into files does
not ensure that independence. Two small modules can require detailed
knowledge of each other's representations, call order, and state transitions;
a larger module can encapsulate that knowledge behind a useful interface.

This decision adopts the tradition of **information hiding** established by
[David Parnas](https://www.cs.lafayette.edu/~gexia/cs301/resources/parnas.html): organize modules around difficult or likely-to-change
design decisions, and keep other modules from depending on those choices.
**High cohesion** brings together behavior that serves a coherent
responsibility and preserves its invariants. **Low coupling** limits the
knowledge and coordination required among those responsibilities. These
principles concern dependencies on knowledge, including behavioral assumptions,
regardless of whether a language enforces private access.

[Robert Martin's Single Responsibility Principle](https://blog.cleancoder.com/uncle-bob/2014/05/08/SingleReponsibilityPrinciple.html) links cohesion and
coupling to the reasons for change, particularly the business responsibilities
that drive those changes. [John Ousterhout's deep modules](https://web.stanford.edu/~ouster/cgi-bin/cs190-winter18/lecture.php?topic=modularDesign) provide a
complementary criterion: an interface should be simple relative to the
capability it provides. Each additional interface carries a cost. Good decomposition
must account for that cost as well as the complexity it introduces.

Design erodes through changes that are individually easy to justify. A new
policy lands beside the code that invokes it because that makes a small diff.
Its tests and later extensions settle around that location. Moving it becomes
more expensive, while no subsequent change is asked to pay the cost. A length
limit eventually triggers a split, but moving half the functions into another
file leaves their shared assumptions intact. Module ownership must be considered
in the change that introduces or extends a responsibility.

## Decision

Organize modules around cohesive responsibilities. Encapsulate their
implementation choices behind interfaces that let callers use their
capabilities without depending on those choices. Separate concerns that change
independently, and keep behavior that shares essential knowledge or invariants
together. Introduce a boundary when doing so reduces the knowledge and coordination
required to understand or change the system.

Here, a module is a unit of responsibility with an identifiable interface and
implementation. Its realization may be a language module, class, or package,
and its file layout follows the language and project conventions. The billing
examples below use illustrative pseudocode and omit routine validation and
error handling.

### 1. Define cohesive responsibilities and keep their invariants together

Describe what a module is responsible for, what knowledge it owns, and what
must remain consistent within it. This description determines which changes
belong there. Choose a name that makes the responsibility clear, and
document the contracts and exclusions that a short name cannot express.

An `InvoiceNumber` module might format, parse, and validate invoice numbers.
These operations share a numbering scheme: they must agree on the prefix,
field widths, separators, and the interpretation of each component. The module
contains several choices, and those choices need not change together.
They belong together because the operations must interpret the same scheme
consistently. Separate formatter, parser, and validator modules that each
encode the scheme would spread that knowledge across three owners.

A `LateFee` module has a distinct responsibility. Its rate, cap, and rounding
rules determine the fee. A change to the numbering scheme gives it no reason
to change, and a change to the fee policy gives `InvoiceNumber` no reason to
change. Putting both in `BillingHelpers` creates a broad home for unrelated
behavior without providing a useful shared abstraction.

The level of decomposition is a responsibility, not an individual constant,
operation, or branch. Shared input alone does not establish cohesion: two
policies can read the same invoice yet change for independent reasons.
Conversely, operations with different inputs may belong together because they
maintain a single invariant. Extracting a private helper within a cohesive module
is often sufficient to make an algorithm readable.

Use names such as `InvoiceNumber`, `LateFee`, and `InvoiceStore` to express
ownership. Generic collections such as `helpers`, `utils`, and `misc` do not
provide a criterion for the next change. A role name can be useful
when its scope is clear: `BillingController` can coordinate billing use cases,
while the policies and representations those use cases depend on have their
own owners.

### 2. Hide representation and policy knowledge behind behavioral interfaces
A useful interface lets callers request an outcome without reconstructing the
implementation that produces it. Private fields alone do not achieve this.
Knowledge can leak through argument and result shapes, required call order,
error handling, or assumptions about how state is stored.

Consider three billing operations that share an invoice table:

```text
issue(entries, id, amount):
    entries["invoice:" + id] = {status: OPEN, amount: amount, attempts: 0}

record_failed_attempt(entries, id):
    entry = entries["invoice:" + id]
    require entry.status == OPEN
    entry.attempts += 1
    return entry.attempts

void_invoice(entries, id):
    entries["invoice:" + id].status = VOID
```

All three operations know the key format and stored representation. If a
key-format change affects only the issue path, the other paths look in the
wrong place. Keeping each operation in its own file preserves that dependency.
Replacing the literal with a shared key helper removes one duplication but
still leaves callers manipulating the entry representation themselves.

An `InvoiceStore` can own the keyed entries and expose operations on them:

```text
InvoiceStore:
    open(id, amount)
    record_failed_attempt(id) -> failure_count
    void(id)

issue(store, id, amount):
    store.open(id, amount)

charge_failed(store, schedule, id):
    failure_count = store.record_failed_attempt(id)
    return schedule.after_failure(failure_count)

void_invoice(store, id):
    store.void(id)
```

Only the store implements key construction and entry updates. The retry
schedule receives a count, and the use case receives a retry decision. Neither
needs the stored entry. This boundary also gives the store a place to enforce
the preconditions for its updates. More complex billing eligibility rules
would need their own explicit owner rather than accumulating in the store,
which can see all the data.

Issue, collection, and voiding may remain separate use-case modules. Execution
order is insufficient as a decomposition criterion, but orchestration is a
legitimate responsibility. Use cases compose the owners of shared knowledge;
they do not each implement their own version of that knowledge.

Specify the interface's behavior and its signatures: preconditions,
results, failures, ordering requirements, and any atomicity or lifecycle
guarantees callers rely on. Returning the internal table, or requiring callers
to perform a fragile sequence of updates to preserve its invariants, would
undermine the store boundary, even if its fields were private.

An implementation change can remain local if it preserves this observable
contract. Changing public meaning requires an impact analysis across callers.
Changing a storage layout may also require migrating existing data. Local
ownership identifies who is responsible for a change; it does not prove that
the change has no effects elsewhere.

### 3. Make each boundary earn its interface cost

Evaluate a proposed split by comparing what callers must understand
before and after the split. Examine the concepts, representations, sequencing
obligations, and failure cases the interface exposes. A short signature can still
carry a large contract; a module with several operations can provide a single
coherent abstraction.

In the billing example, a retry schedule can encapsulate backoff, limits, and
later additions such as jitter. Its caller supplies the relevant facts and
receives a decision. Separating each arithmetic step into a module would force
the caller to reassemble the policy. Likewise, splitting the store into
read and write modules that both understand its representation would require
coordination whenever that representation changes. Such splits need a benefit
that outweighs the additional coupling; smaller files alone provide none.

Give collaborators the data or capabilities their responsibilities require.
A retry schedule should not receive the entire billing state merely because
the caller has it. Keeping its inputs narrow makes unrelated dependencies
harder to introduce and its behavior easier to test independently. Where
several collaborators genuinely need the same stable domain value, passing
that value is reasonable; inventing a separate, near-identical type for each
caller can add complexity without hiding anything.

If two proposed modules must continually access each other's internals,
synchronize every update, or call back and forth to complete an operation,
reconsider their ownership and interface. Keeping them together may produce
a stronger abstraction. A dependency cycle introduced by extraction is a
reason to revisit the split, not to relabel the same dependency through a
generic helper or callback.

Module length is a prompt to investigate cohesion and interface quality. It
does not determine the boundary. A large cohesive module can be appropriate;
a small module can still mix unrelated responsibilities. When a project
enforces a length limit, meeting it still requires a coherent decomposition.
Document a conflict when the limit would force a worse boundary. Do not meet
it with numbered or `continued` halves that pass the same broad state between
them.

### 4. Establish ownership in the change that needs it

For each addition, identify the responsibility it extends. Place it with its
existing owner when it fits. When the change introduces a separate concern,
establish its owner and the necessary interface in that change. Preparing
that structure is part of delivering the behavior and should not be deferred
merely to keep the diff small. Keep the work bounded to the responsibilities
the change actually touches.

For example, introducing a retry policy involves deciding where its rules
reside and how the caller receives a decision. It does not require a generic
policy framework, speculative extension points, or a module for each future
retry strategy. The useful boundary can start with one caller and a small,
concrete interface.

For stateful behavior, ensure ownership spans the complete lifecycle. In a
retrying workflow, deciding the delay and owning a pending timer are distinct
responsibilities. The timer's owner must also account for correlation, stale
delivery, cancellation, and completion. A policy extraction should make that
ownership clear rather than distributing timer operations among helpers that
each know only one step. The same reasoning applies to resources and to
operations that can fail partway through.

When restructuring existing code:

1. Identify before choosing new modules, review responsibilities, likely changes, and invariants. Map state access, external interactions, and calls to identify candidate groups and dependencies. Examine existing clusters as evidence; they may reflect the coupling being removed.
2. Define what each proposed interface promises and what knowledge callers can rely on. Resolve shared state and lifecycle ownership before moving functions. Avoid exporting implementation details solely to make the move compile.
3. Extract or combine code while preserving existing behavior unless a contract change is explicitly included in the work. Inspect affected callers, including dynamic calls, persisted values, and external protocols, as relevant. Use dependency tools as evidence alongside source and contracts.
4. Exercise each responsibility through its public interface and retain integration coverage for composition, failure propagation, and lifecycle behavior. Move or adapt focused tests as appropriate. A controller's tests still need to verify the behavior promised by the whole use case.

## Review criteria

A proposed module or extraction should have concrete answers to these
questions:

- What responsibility does it own, and which invariants must it maintain?
- What implementation knowledge can callers remain unaware of? Does that
  knowledge escape through arguments, results, errors, or required call order?
- What plausible changes belong here, and which should belong elsewhere?
- Does the boundary reduce the understanding and coordination needed for those
  changes, after accounting for the new interface?
- Who owns shared state, resources, and completion or cleanup after failure?
- What evidence shows that the affected contracts still hold?

An answer such as "the file was too long" or "these functions run next"
does not establish a useful boundary. Neither does assigning a plausible name to a fragment
while its callers still implement the responsibility.

## Consequences

- Responsibilities and their internal invariants have identifiable owners. Reviewers can determine where new behavior belongs without treating current file placement as the design authority.
- Changes to encapsulated implementation choices require less coordination when public contracts remain stable. However, changes to those contracts still require explicit review of affected participants.
- Design work is included in feature and repair changes. This can increase
  the immediate diff and review effort; it avoids making later changes absorb
  an ever-growing cost of establishing ownership.
- Some changes create modules; others combine modules or keep related code together. Every added interface incurs costs in concepts, navigation, testing, and compatibility obligations. Reducing overall design complexity takes precedence over minimizing the size of an individual module.
- Boundaries reflect current responsibilities and plausible changes, and may need revision as the system evolves. Naming a responsibility is not proof that its boundary will remain appropriate indefinitely.
- Length and dependency checks remain useful signals. They support review, but passing them does not establish cohesion or information hiding.
