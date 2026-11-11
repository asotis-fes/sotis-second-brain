# Findings

## UUIDv7 bit layout (RFC 9562, §5.7)

128 bits, big-endian, laid out as:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           unix_ts_ms                          |  48 bits
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          unix_ts_ms (cont)    |  ver  |       rand_a          |  ver=0x7 (4b), rand_a 12b
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|var|                        rand_b                             |  var=0b10 (2b), rand_b 62b
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                            rand_b                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- **unix_ts_ms**: 48 bits, milliseconds since Unix epoch (big-endian), occupies the first
  6 bytes → first 12 hex chars (`xxxxxxxx-xxxx-...`).
- **version**: nibble 13 = `7`.
- **rand_a**: 12 bits. Some implementations use this for sub-millisecond precision (µs/ns
  fraction) — the "Method 3 / monotonic" variants in RFC 9562. **Depends on the Go fn.**
- **variant**: top 2 bits of byte 8 = `10` → the 17th hex char is one of `8,9,a,b`.
- **rand_b**: 62 bits. Random, counter, or (if deterministic) seeded/zeroed. **Depends on
  the Go fn.**

Canonical string: `xxxxxxxx-xxxx-7xxx-Nxxx-xxxxxxxxxxxx` where `N ∈ {8,9,a,b}`.

## CONFIRMED (2026-09-14): library = `github.com/gofrs/uuid`, `NewV7()` / `NewV7AtTime(t)`

Doc comment from the team: *"a k-sortable UUID based on the ... millisecond-precision UNIX
epoch and 74 bits of pseudorandom data. It supports single-node batch generation ... with
a Monotonic Random counter."*

**CORRECTION (2026-09-14, from code review vs actual source at v5.3.1/v5.5.x/master):** the
doc comment is misleading. In the real gofrs implementation, **`rand_a` (12 bits) is a
MONOTONIC clock-sequence counter, not random** — gofrs uses it to guarantee strict ordering
of UUIDs generated within the same millisecond. Only **`rand_b` (~62 bits) is random**
(`crypto/rand`). So it's ~62 random bits, not 74.

**Verdict UNCHANGED: NOT reproducible from a timestamp.** The random `rand_b` alone (62 bits)
makes a specific UUID unrecomputable on the Snowflake side — there is no seed to match. But
note the consequence for our minted UUIDs: gofrs provides **strict intra-millisecond
ordering** (via the rand_a counter) that our random-low-bits approach does NOT. Within a
single millisecond our ordering is random; gofrs's is monotonic.

Input confirmed by team: **just a timestamp** (ms precision).
Sample input→output pairs: team can provide (#5) — useful for validating *format/timestamp
bits*, but cannot make the random bits match.

> **This is the "stop before building" finding.** Exact replication is impossible. What's
> possible depends on the actual migration goal — see `decisions.md` D-3.

## Source timestamp precision (confirmed in Snowflake 2026-09-14)
The backfill's source timestamp is `LOYALTY.LOYALTY_CORE.LOYALTY_ANALYTICS_LEDGER.CREATION_TIME`
(the migration repo `fes-loyalty-fancash-migration-ws` reads `creation_time`; the new Postgres
side is `LOYALTY.SOURCE.TRANSACTION_UNI_EXT.created_at`, nanosecond-capable).
- Type = **`TIMESTAMP_LTZ`** (true instant → feed the `UUIDV7(TIMESTAMP_LTZ)` overload; UTC-safe,
  the NTZ/UTC ambiguity does NOT apply here).
- Data precision = **exactly milliseconds**: of 1,000,000 sampled rows, 999,024 (~99.9%) carry
  sub-second, and **0** carry anything finer than a ms. Raw e.g. `...27.891000000`.
- **Rows DO share the same millisecond** (a `LIMIT 8` returned 8 rows all at `.891` — batch
  inserts collide at ms).
Consequences: (1) our 48-bit ms UUIDv7 captures the FULL source precision, no loss; (2) the
gofrs intra-millisecond ordering difference is real in the data but immaterial for a historical
backfill (parity pairs on MINUTE; uniqueness comes from the 62 random bits). See `code_review.md`.

## Sample vectors (TBD — Task 2)
- RFC 9562 provides one worked UUIDv7 example — capture it here with the exact ms value.
- Library-specific testdata to be added once the library is confirmed.
