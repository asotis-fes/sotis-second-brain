# Decisions & Open Questions

## ✅ BLOCKER RESOLVED (2026-09-14) — user confirmed: rows have NO UUIDv7, we generate them
Option A is correct: these are legacy Snowflake rows with no existing UUIDv7, and Snowflake
is assigning one. **Load-bearing operational rule:** the generator is `VOLATILE` (fresh
randomness per call), so the assigned ID MUST be **materialized once** into a stored column
(`CREATE TABLE AS` / `INSERT` / `UPDATE`) — never left as a live `UUIDV7()` in a view, or it
changes on every read. See D-5 (range guard fix) and `code_review.md`.

--- (original blocker text, now answered) ---
**D-4 ("Option A: Snowflake mints new UUIDs") — the deciding question:** did the rows being
moved ALREADY have a UUIDv7 (assigned by the Go/Postgres app)? **Answer: NO — none do.**
- If YES → Snowflake must **preserve/pass through** the existing ID. Minting a new one breaks
  foreign keys and duplicates identity. Our `UUIDV7()` is also `VOLATILE` → **non-idempotent**
  (re-running the migration yields different IDs for the same row).
- If NO (legacy Snowflake rows that need a UUID assigned for the first time) → Option A is
  legitimate, but the generated ID must be **materialized once** (written to a column), never
  recomputed on read.
**Action:** confirm with the other team which case this is. See `code_review.md`.

## Open questions (need answers before/while building)
- **Q1 (critical):** Where is the Go UUIDv7 function? Which library + version, or bespoke?
- **Q2 (now the critical one):** The low bits are **seeded from the timestamp** (per user).
  To reproduce bit-for-bit I must match the exact PRNG + seeding:
  - Which PRNG? `math/rand` (Lagged-Fibonacci), `math/rand/v2` (PCG / ChaCha8), or a hash
    (SHA-256/FNV) over the ts? Each gives a totally different bit stream from the same seed.
  - What exactly is the seed value (raw int64 ms? hashed?) and API (`NewSource`/`Seed`)?
  - Order the random draws map into `rand_a` / `rand_b`, and which bits get masked where.
  → Need the ~5 lines of Go that seed + draw the bits, or library + version.
- **Q3:** Input signature — timestamp only? What precision (ms/µs/ns)? Timezone (UTC)?
- **Q4:** Where should the finished UDF live (Snowflake DB/schema, ownership)?

## Decisions

### D-1 — Feasibility: RESOLVED in principle (timestamp-seeded → deterministic)
User confirmed (2026-09-14) the Go fn **seeds a PRNG with the timestamp** — e.g.
`uuidv7("creation_time")` — so output is fully deterministic (same ts → same UUID). This
removes the crypto-random blocker; replication is now possible.
**BUT** bit-exact replication still requires the exact Go source, because "seed with the
timestamp" is underspecified — see Q2. **Status:** feasible, still needs the code.
**Why:** avoids building a UDF that can never match a random reference.

### D-4 — Goal is Option A (Snowflake mints ids); implementation chosen
User confirmed **Option A** (2026-09-14): Snowflake is the source of truth generating the
UUIDv7s; no need to match gofrs. Built:
- `UUIDV7_ASSEMBLE(epoch_ms, rand_hex)` — IMMUTABLE JS UDF, pure RFC 9562 byte assembly.
- Generators `UUIDV7(TIMESTAMP_LTZ/NTZ)`, `UUIDV7()`, `UUIDV7_FROM_EPOCH_MS(NUMBER)` — VOLATILE,
  randomness from native `UUID_STRING()` (so NO PRNG reimplementation).
- Decoders `UUIDV7_EPOCH_MS`, `UUIDV7_TIMESTAMP`.
**Why UUID_STRING() for randomness:** crypto-random, native, avoids depending on JS
`Math.random`. **Why a JS assembler:** int->hex + bitmasking is trivial in JS, painful in
pure SQL (no native int->hex). Files: `sql/uuidv7.sql`, `sql/test_uuidv7.sql`, `verify_local.py`.

### D-5 — Range guard added (code-review MAJOR fix)
`TO_CHAR(EPOCH_MS,'XXXXXXXXXXXX')` silently emits two's-complement hex for negative
(pre-1970) ms and `############` on >48-bit overflow. Added a `CASE` guard to `UUIDV7_ASSEMBLE`:
input outside `[0, 2^48)` (or NULL) now raises a loud error (`uuidv7_epoch_ms_out_of_range:…`)
instead of producing a valid-looking wrong UUID. Happy path unchanged. In `sql/uuidv7.sql`,
`sql/deploy_and_generate.sql`, `sql/redeploy_and_verify.sql`. Not a concern for this
migration's data (all recent), but fail-loud > silent-corrupt.

### D-3 — Exact replication is IMPOSSIBLE (gofrs/uuid confirmed) → clarify the real goal
gofrs `NewV7` = 74 random bits. A given row can NOT get the same UUID on both sides. So the
task as literally framed ("replicate the output") cannot be done. Two viable reframings —
**need the team to pick**:
- **(A) Snowflake mints the ids.** If Snowflake is the source of truth generating NEW
  UUIDv7s for migrated rows (and Postgres just stores them), then matching gofrs is
  irrelevant — I build a UDF that emits *valid, k-sortable* UUIDv7s (48-bit ts + version +
  variant + my own random 62 bits). **Easy + correct.** No test-against-Go needed.
- **(B) Ids must agree across both sides.** Then neither side can use a random UUIDv7. The
  system must switch to a **deterministic** id (e.g. `uuidv7`-shaped but with low bits =
  hash of a stable business key/timestamp), generated identically on both sides. This is a
  design change on the Go/Postgres side, not just a Snowflake UDF.
**Status:** OPEN — this is the key question back to the team.

### D-2 — UDF language: RESOLVED → PURE SQL (was leaning JS)
Discovered in-DB that Snowflake `TO_CHAR(n,'X…')` / `TO_NUMBER(h,'X…')` handle int<->hex, and
`UUID_STRING()` (a v4 UUID) already carries a valid variant nibble at hex position 17. So the
full RFC 9562 assembly is a clean pure-SQL expression — no JavaScript engine needed. The
assembler force-sets the variant bits (`BITOR(BITAND(nibble,3),8)`) so any input hex is valid.
**Chosen: pure-SQL UDFs** (`sql/uuidv7.sql`). Validated read-only (50k rows + RFC vector)
before wrapping as functions. **Status:** DONE.
