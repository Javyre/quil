# Ubiquitous Language

Agent context for high-value terminology in `src/SkipRope.zig` and
`src/SkipRange.zig`.

Policy: when shared B-skiplist wording conflicts, use SkipRope terms unless
SkipRange sparse semantics differ.

Note: SkipRange names are provisional for shared structure. Trust SkipRope
language first, then SkipRange invariants/tests for sparse behavior.

## Naming guidance

- `ofs` may be absolute or relative. Qualify when needed: `abs_ofs`, `rel_ofs`,
  `base_ofs`.
- `idx` = array/pool index; `rank` = in-block logical position. Do not use
  either for byte offset.
- Abbrevs are good when local meaning is clear: `ib`, `db`, `rb`, `ofs`,
  `len`, `cur`.

## Logical vs. Physical communication angle

When writing about an algorithm, dont force-merge the two angles.
Start with a logical explanation in the established domain analogy.
Then translate that into relevant clarifications about physical reality of the
operations in question.

## SkipRope

- **Subtree width** (`Ib.wide`): byte count covered by one index slot’s down
  pointer. Not SkipRange gap/reach.

## SkipRange

- **Range**: domain interval with caller payload and boundary flags. Do not use
  for SkipRope byte spans.
- **Same-start range**: range whose start offset already exists in the leaf
  stream. Not a new leader.
- **Distinct-start range**: range whose start offset is new to the leaf stream.
  May create/promote a leader.
- **Gap** (`gap`): distance to next distinct start leader; `0` means same-start
  continuation or no next leader, disambiguated by position/view. Not SkipRope
  width.
- **Reach** (`reach`): distance from child base/leader to max reachable range
  end. Not range length.

## Shared B-skiplist structure

Use only when concept is common to SkipRope and SkipRange.

- **Layer**: horizontal block sequence at one skiplist height. Not “level”
  when vertical count/position is meant.
- **Height**: highest layer where a leader participates; `0` = leaf-only. Not
  fullness; not the same as `ib_height` bookkeeping.
- **Leader**: byte/start offset that owns skiplist structure at a layer. Not
  generic key if domain term is clearer.
- **Header virtual leader** (`first_is_header`): virtual leading `-inf` leader
  exposed by first-block walk state. Not stored domain item or block property.
- Header `gap == 0` with non-null `down` owns the rest of its bounded view;
  no body Leader follows at that layer.
- **Tower**: vertical entries for one promoted leader. Not same-layer chain.
- **Promotion**: creating upper-layer entries for a leader. Not spill.
- **Spill**: same-layer sibling storage growth due capacity. Not promotion.

## Mutation language

- **Lazy subtree**: SkipRope insertion helper that materializes inserted-text
  layers on demand. Not SkipRange pending tower.
- **Pending tower**: SkipRange promoted child chain carried during insert
  unwind. Not SkipRope lazy subtree.

## Repo TODO domains

TODO: add high-signal terms for Buffers, Windows/layout, Rendering when those
domains get a pass.

## Traps

- `index` can mean byte offset, local rank, or key. Use `ofs`, `rank`, or
  **Leader**.
- `range` means SkipRange **Range** only; use byte-span wording for
  SkipRope/Zig spans.
- `width` means SkipRope **Subtree width**. In SkipRange use **Gap** or
  **Reach**.
- `gap == 0` can mean same-start continuation, right edge, or an unbounded
  header child; cell/slot kind and `down` disambiguate it.
- `reach` is **Reach**, not range length.
- `start` needs context: start offset, leader, `start_abs`, `start_rel`.
- `cell` is `Rb` leaf-only; index entries are slots.
- `split` often means **Spill**, not **Promotion**.
- `head` can mean root or view head. Qualify it.
- `base` means view base offset; prefer `base_abs` / `base_rel`.
- `first_is_header` exposes **Header virtual leader** for a walk/view; not a
  block property.
- `ib_height` is tree index-height bookkeeping, not general **Height**.
- `Find` names the predecessor anchor; header is inferred from
  `first_is_header and rank == 0`; its `start_rel` is the view base `0`.
- `exact` needs target type: exact start, exact offset, exact rank.
- `level` and `layer` drift. Use **Layer** for horizontal structure; **Height**
  for vertical count/position.

## Example dialogue

> **Dev:** “For SkipRange insert, does every Range get a Tower?”
>
> **Domain expert:** “No. A Same-start range stays in the leaf stream. A
> Distinct-start range creates a Leader and may promote a Tower.”
>
> **Dev:** “So Gap is not SkipRope Subtree width?”
>
> **Domain expert:** “Right. SkipRope Subtree width counts dense bytes under
> an index slot. SkipRange Gap is distance to next distinct Leader; Reach
> tracks distance to max range end under the child.”
