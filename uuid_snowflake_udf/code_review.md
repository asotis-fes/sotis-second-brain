# Independent Code + Design Review — UUIDv7 Snowflake UDF

*Reviewer: adversarial pass, 2026-09-23. Primary sources: RFC 9562 (rfc-editor.org),
gofrs/uuid source at tags v5.3.1 / v5.5.0 / v5.5.1 and `master` (fetched via GitHub API).*

---

## Verdict

The **implementation** is small, mostly correct, and the RFC 9562 byte layout is right — the
assembler reproduces the RFC A.6 worked vector byte-for-byte and I independently confirmed the
timestamp decode (0x017F22E279B0 → 1645557742000 ms → **2022-02-22 19:22:22 UTC**, which the
project correctly corrected from an earlier 20:22:22). But two things did **not** get done right.
(1) **The requirements question was skipped.** For a *migration* of records that already carry a
UUIDv7 from the Go/Postgres side, minting *fresh* UUIDs on the Snowflake side is very likely an
outright correctness bug (broken joins / duplicated identity), and "Option A" was accepted without
ever confirming whether Snowflake is the ID *source* or the ID *carrier*. That is the biggest risk
and it dwarfs every code issue below. (2) **The gofrs characterization is factually wrong** — in
*every* gofrs version, including the exact one the team quoted, `rand_a` is a **monotonic counter /
clock-sequence**, not random; only ~62 bits (rand_b) are random. That error doesn't change the
Option-A code, but it was used as load-bearing justification for the reframe, so it deserves
correcting. Implementation-wise there is one real **MAJOR** bug: negative/out-of-range timestamps
silently corrupt the output.

---

## High-level / requirements findings (READ THIS FIRST)

### H-1 — "Option A" may be the wrong requirement entirely — **BLOCKER (design)**
The framing says: *records move between Snowflake and Postgres; the Go/Postgres app already
generates UUIDv7 via gofrs `NewV7()`.* If those records **already have a UUIDv7 primary key**, then
the correct behavior during migration is to **carry/preserve the existing ID**, not to mint a new
one. Minting new IDs on the Snowflake side would:
- break any foreign-key / join relationship that references the original UUID;
- create two identities for one logical record (duplicate-identity bug);
- make the migration non-idempotent (re-running mints different IDs every time — the UDF is
  VOLATILE and `examples.md` explicitly shows the same input producing different UUIDs).

`decisions.md` D-3 actually *raised* exactly this fork — "(A) Snowflake mints" vs "(B) IDs must
agree across both sides" — and then D-4 records that the user "confirmed Option A." That may be
right, but the notes never capture the one question that decides it: **do the rows being migrated
already have a UUID, and does anything downstream reference it?** If yes, Option A is wrong
regardless of what gofrs does. The reframe from "replicate" to "mint" solved the *impossible*
sub-problem (byte-matching random bits) but may have quietly redefined the *actual* task. This must
be re-confirmed with the other team in one sentence: *"Are we generating IDs for brand-new rows
that have none, or copying rows that already have a UUIDv7?"* If the latter, the right Snowflake
"UDF" is a pass-through/cast, and this whole generator is not what's needed.

### H-2 — If Option A is genuinely correct, the generator is fine but under-scoped — MINOR
Option A is legitimately correct **only** in the narrow case where Snowflake is authoritative for
brand-new rows that arrive without an ID (e.g. Snowflake-originated inserts flowing *to* Postgres).
In that case the design is sound and the collision math (62 random bits) is adequate. Even then,
document the intended call site (which table/column, which direction) in `examples.md` so the other
team can sanity-check that no existing ID is being overwritten.

---

## Implementation correctness findings

### I-1 — Negative / out-of-range epoch_ms silently corrupts the UUID — **MAJOR**
`sql/uuidv7.sql:33-34` (and the decoders) rely on `TO_CHAR(EPOCH_MS, 'XXXXXXXXXXXX')`.
Per Snowflake's SQL format-model docs, the `X` element:
- **cannot represent a negative number as a hex prefix** — a negative value is printed in
  two's-complement ("negative numbers have all 1's in the most significant bit(s)"), so a pre-1970
  timestamp (negative `EPOCH_MILLISECOND`) yields an all-`f…` garbage prefix, **not** an error;
- **overflows to `############`** when the value needs more than 12 hex digits, i.e. any ms beyond
  the 48-bit range (> 281474976710655, ≈ year 10889) produces a string that fails the v7 regex.

Neither case errors; both silently emit an invalid or wrong-timestamped UUID. gofrs, by contrast,
*clamps* out-of-range times to the nearest end of the 48-bit field (`atMs := min(max(...,0), maxV7Timestamp)`).
**Fix:** clamp before formatting — `GREATEST(0, LEAST(EPOCH_MS, 281474976710655))` — or raise. At
minimum add a test for epoch 0 (present), a negative epoch, and `0xFFFFFFFFFFFF`.

### I-2 — Timezone/UTC assumption is real but only half-guarded — MAJOR (correctness-sensitive)
`UUIDV7(TIMESTAMP_LTZ)` (`:49-53`) uses `DATE_PART('EPOCH_MILLISECOND', TS)`, which is correct — an
LTZ/TZ value maps to a true instant regardless of session TZ. But `UUIDV7(TIMESTAMP_NTZ)` (`:56-60`)
takes the *wall-clock* number and treats it as UTC. If the source column is NTZ storing
**local** time (very common in this org's Snowflake data), the embedded timestamp is silently
shifted by the UTC offset — the UUIDs are still valid and unique, but their embedded time (and
k-sort order across a DST boundary) is wrong. The comment says "adjust upstream if not UTC," which
is fine as a contract, but it's exactly the kind of thing that needs explicit sign-off. The
`examples.md` "one open confirmation" mentions ms precision but **not** the NTZ-is-UTC assumption —
add it there. This is called out in `_index.md` "Next (needs user): confirm input column
type/precision + UTC" but is **not yet confirmed**, so it remains open, not done.

### I-3 — Decoder is not the inverse of the generator across TZ — MINOR
`UUIDV7_TIMESTAMP` (`:75-79`) returns `TIMESTAMP_NTZ` built from `epoch_ms/1000` via
`TO_TIMESTAMP_NTZ`, i.e. it yields the **UTC** wall clock. Round-tripping `UUIDV7(ntz_local)` →
`UUIDV7_TIMESTAMP` will therefore *not* return the original NTZ value when the input wasn't UTC.
Test #7 only exercises the UTC path so this asymmetry is invisible. Document that the decoder is
UTC-only.

### I-4 — Variant/version bit math is correct — NIT (verified, no action)
`BITOR(BITAND(nibble,3),8)` (`:36-37`) correctly forces the top two bits to `10` while preserving
the low two, so the nibble lands in `{8,9,a,b}`; the literal `-7` sets the version nibble. I
verified against the RFC A.6 vector: nibble `9` → `(9&3)|8 = 9`, and the full assemble reproduces
`017f22e2-79b0-7cc3-98c4-dc0c0c07398f`. The canonical-string positions (version = first hex of group
3, variant = first hex of group 4) match RFC 9562 §5.7. Good.

### I-5 — Reusing a v4 `UUID_STRING()` as the random source wastes a few bits — NIT
The random hex is a v4 UUID, so its own char 12 (`'4'`) and char 16 (variant) are non-random. The
assembler happens to draw rand_a from `r[0:3]` and rand_b from `r[17:20]+r[20:32]`, and forces the
variant itself, so this is *safe* — but char 16 of the v4 (used as the variant seed) is already
constrained to `{8,9,a,b}`, meaning the low two variant bits are not uniformly random. Immaterial
for uniqueness (still ~120 usable random bits); worth a one-line comment so a future reader doesn't
think all 74 low bits are full-entropy.

### I-6 — VOLATILE choice is correct; double-call footgun is real — MINOR
Marking the generators `VOLATILE` (`:42-66`) is right: it prevents Snowflake from constant-folding
`UUIDV7()` to a single value per query. But that same property makes `UUIDV7()` a footgun if
referenced twice for the "same" row (e.g. once in SELECT and again in a later CTE/subquery) — you'll
get two different IDs. The project notes materializing in a CTE; that is reliable **only** if the
CTE is itself materialized/consumed once. Under Snowflake's optimizer a non-materialized CTE can be
inlined and re-evaluated. If a stable per-row ID is needed, generate it in an explicit
`INSERT ... SELECT` / `CREATE TABLE AS` and never reference the function output more than once, or
wrap generation in a subquery that is provably evaluated once. Call this out in the hand-off.

### I-7 — `UUIDV7_ASSEMBLE` marked IMMUTABLE is correct — NIT
Pure function of its inputs; IMMUTABLE is appropriate and lets it fold. Fine.

---

## Testing gaps

The 8 in-DB tests (`sql/test_uuidv7.sql`) are mostly meaningful, but with holes:

- **Test #1 (RFC vector) is a legitimate independent check** — it feeds the RFC's *own* published
  low bits back in and asserts the exact published string. Good; this is the one test that isn't
  self-referential.
- **Tests #2–#5** (regex / version / variant / uniqueness over 10k) are meaningful sanity checks but
  are properties the code trivially enforces; they'd only catch a gross regression.
- **Test #6 (round-trip)** is fine but only exercises one positive, in-range ms.
- **Test #8 (k-sortable)** compares only two hand-picked values; it does **not** test the
  intra-millisecond case, which is exactly where this implementation diverges from gofrs (random low
  bits → **no** intra-ms ordering; gofrs has a counter → strict ordering). If any downstream relies
  on ordering *within* a millisecond, this passes yet the property is absent.
- **Not tested at all (should be):** negative epoch (I-1), ms beyond 48-bit range (I-1),
  NTZ-vs-LTZ/timezone behavior (I-2/I-3), decoder inverse on a non-UTC input, and behavior on NULL
  input. The two silent-corruption edge cases (I-1) are the important omissions.
- `verify_local.py` is a faithful mirror of the assembler and is a nice offline proof, but note it
  is **testing the same logic twice**, not an independent oracle. Its comment header still says
  "mirrors ... UUIDV7_ASSEMBLE JS UDF" (`verify_local.py:5`) — stale, the UDF is now pure SQL.

---

## Spec-conformance check (RFC 9562 + gofrs)

### RFC 9562 §5.7 — layout: **CONFORMANT**
Confirmed against the RFC:
- 48-bit `unix_ts_ms`, big-endian, octets 0–5 → first 12 hex chars. ✔ (matches `findings.md`)
- version `0b0111` at bits 48–51 = first hex of group 3. ✔
- 12-bit `rand_a` at bits 52–63. ✔
- variant `0b10` at bits 64–65 = first hex of group 4 → `{8,9,a,b}`. ✔
- 62-bit `rand_b` at bits 66–127. ✔
- RFC A.6 worked example `017f22e2-79b0-7cc3-98c4-dc0c0c07398f`, ms `0x017F22E279B0` =
  1645557742000 = 2022-02-22 19:22:22 UTC — reproduced exactly by the assembler. ✔
- §6.2 monotonicity methods: **Method 1** = fixed-length dedicated counter; **Method 2** = monotonic
  random; **Method 3** = replace leftmost random bits with sub-ms clock precision. The project's
  design uses *none* of these (pure random low bits) — valid per RFC, but not monotonic within a ms.
Source: https://www.rfc-editor.org/rfc/rfc9562.html (§5.7, §6.2, Appendix A.6).

### gofrs/uuid `NewV7` / `NewV7AtTime` — project's characterization is **INACCURATE** — MAJOR (doc)
Fetched the real source at multiple tags:
- **v5.3.1** (the version whose doc comment the team quoted — *"74 bits of pseudorandom data … with
  a Monotonic Random counter"*): `getV7`/`NewV7AtTime` writes the **monotonic clock sequence** into
  `rand_a` via `binary.BigEndian.PutUint16(u[6:8], clockSeq)` with the comment *"set rand_a with
  clock seq which is random and monotonic."* So even here `rand_a` is **not** free random data — it
  is an incrementing sequence seeded once with random bits.
- **v5.5.0 / v5.5.1 / master** (rewritten July 2026, commits `6f59794f` + `dce88088`): `rand_a`
  holds an explicit **12-bit monotonic counter** (Method 1), reseeded with 11 random bits per
  millisecond tick (`v7CounterSeedMask = 0x07ff`, leading bit as rollover guard), guaranteeing
  **strictly increasing** UUIDs even within a millisecond and across backwards clock moves. Only
  `rand_b` (~62 bits, `u[8:16]` minus the 2 variant bits) is random.

**Implications for the review's premises:**
1. The claim in `findings.md`/`decisions.md` that gofrs fills "**74 bits** … crypto-pseudorandom"
   is wrong: it's ~62 random bits + a 12-bit monotonic counter. The doc string says "74 bits of
   pseudorandom data" but the *code* does not treat rand_a as free random.
2. gofrs **does** provide **strict intra-millisecond ordering**; this implementation does **not**.
   `examples.md`'s "one open confirmation" is right to flag it, but understates it: it's not merely
   "no monotonic counter like gofrs" — it's that two IDs minted in the same ms have random,
   arbitrary relative order. For a k-sortable key that's usually fine; for anything that assumes
   insertion order within a tick it is not.
3. Precision: gofrs is **millisecond** (`UnixMilli()`), big-endian — matches the project. ✔
4. This does **not** invalidate Option A's code, but since the (mischaracterized) gofrs randomness
   was cited as the reason exact replication is "impossible," the reasoning chain should be
   corrected: replication is impossible not because *74* bits are random, but because rand_b (62
   bits) is drawn from `crypto/rand` per call and rand_a is a *runtime* counter with no derivable
   seed — either way non-reproducible. Conclusion (D-3: not reproducible) stands; the *justification*
   is wrong.
Source: https://github.com/gofrs/uuid `generator.go` at tags v5.3.1, v5.5.0, v5.5.1, master.

---

## Deployment / ops findings

### O-1 — Functions live in a personal schema — MAJOR for production
`FES_USERS.ALEX_SOTIS` is a **personal** schema (per this repo's own `hot.md` conventions).
Anything a migration depends on must not live there:
- discoverability/ownership: schema owned by `SYSADMIN`, functions granted USAGE to
  `FES_DATA_DEVELOPER`, but a personal-schema home implies "scratch," not "shared contract";
- if the schema is ever cleaned up or the owner leaves, the migration breaks;
- naming a migration dependency after one engineer is an anti-pattern.
**Fix before any real use:** deploy to a durable team schema (e.g. a shared `LOYALTY`/utility
schema) via Terraform/`fanapp-terraform` so ownership and grants are code-managed, matching this
team's standard for Snowflake objects.

### O-2 — No Terraform / IaC path — MINOR
These are `CREATE OR REPLACE FUNCTION` statements applied by hand. For a production migration
dependency the DDL should live in the Snowflake IaC repo (versioned, reviewed, environment-promoted
dev→prod) rather than an ad-hoc script in a gitignored `projects/` folder.

### O-3 — Portability note — NIT
The implementation is pure SQL and portable within Snowflake. `TO_CHAR(..,'X')`,
`DATE_PART('EPOCH_MILLISECOND', ..)`, `UUID_STRING()`, and `BITOR/BITAND` are all Snowflake-specific,
so this UDF is not portable to Postgres — which is fine given the Postgres side already has gofrs,
but worth stating explicitly so no one tries to "share" the definition.

---

## Recommended next actions (prioritized)

1. **(BLOCKER) Re-confirm the requirement before shipping.** One question to the other team: *are we
   generating IDs for rows that have none, or preserving IDs on rows that already carry a gofrs
   UUIDv7?* If the latter, Option A is wrong and the deliverable should be a pass-through, not a
   generator. Record the answer in `decisions.md` D-4 with the exact question and reply.
2. **(MAJOR) Fix the out-of-range/negative-ms silent corruption (I-1):** clamp `EPOCH_MS` to
   `[0, 281474976710655]` (mirror gofrs) or raise; add tests for negative, zero, and max-ms.
3. **(MAJOR) Nail the NTZ/UTC contract (I-2/I-3):** confirm the source column's type and whether NTZ
   values are UTC or local; add the assumption explicitly to `examples.md`, and add a TZ test.
4. **(MAJOR) Move off the personal schema (O-1/O-2):** deploy to a durable team schema via
   Terraform before any migration relies on it.
5. **(MAJOR, doc) Correct the gofrs characterization** in `findings.md`/`decisions.md`: rand_a is a
   monotonic counter/clock-sequence in *every* gofrs version (incl. the quoted v5.3.x), only rand_b
   is random, and gofrs *does* give strict intra-ms ordering that this implementation does not.
6. **(MINOR) Strengthen tests:** intra-ms ordering expectation, NULL input, decoder-inverse on
   non-UTC, and refresh the stale "JS UDF" comment in `verify_local.py:5`.
7. **(MINOR) Document the double-call footgun (I-6)** in the hand-off: generate the ID exactly once
   per row in an `INSERT…SELECT`/`CTAS`, never reference `UUIDV7()` twice for the same row.
