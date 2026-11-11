# Plan

Each task is scoped to a single working session.

## Task 1 — Nail down the Go reference (BLOCKER)
- Get the **exact Go function / library + version** that generates the UUIDv7 from a timestamp.
  - Ask the user where it lives (repo/path), OR
  - Identify the library (candidates: `google/uuid`, `gofrs/uuid`, `sqids`, or a bespoke fn).
- Determine **how the non-timestamp bits are set**: `rand_a` (12 bits) and `rand_b` (62 bits).
  Are they random, zeroed, a monotonic counter, or seeded? This decides feasibility (see D-1).
- Confirm the **input signature**: just a timestamp? ms vs µs vs ns precision? UTC?
- Record the version nibble / variant handling.

## Task 2 — Find independent sample vectors
- Source known input→output pairs online:
  - RFC 9562 Appendix test vectors (UUIDv7 example).
  - The chosen Go library's own unit tests / testdata.
- Save vectors into `findings.md` (or a `vectors/` file) with attribution.

## Task 3 — Build the Snowflake UDF
- Implement as a UDF. Language choice (see D-2): SQL UDF (bit-twiddling with
  `TO_BINARY`/`BITSHIFTL`/hex) vs **JavaScript/Python UDF** (easier byte assembly + hex format).
- Layout (RFC 9562): 48-bit `unix_ts_ms` | 4-bit version (0x7) | 12-bit rand_a |
  2-bit variant (0b10) | 62-bit rand_b. Format canonical `8-4-4-4-12` hex.
- Handle the deterministic bit-fill exactly as Task 1 found.

## Task 4 — Unit test
- Write a test that runs the UDF over the Task 2 vectors and asserts exact string equality.
- Run it in Snowflake (read/compute only; no writes to prod). Record results in `progress.md`.

## Task 5 — Package & document
- Final UDF DDL + test harness saved in the project (and proposed destination repo/schema).
- Note deployment path (which Snowflake DB/schema, ownership) for the human to apply.
