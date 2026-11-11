# UUIDv7 Snowflake UDF — replicate a Go UUIDv7-from-timestamp function

> **Standing directive:** Keep these files updated as work progresses. Treat them as the
> source of truth across sessions. Nothing under `projects/` is ever committed (gitignored).

## High-level context / goal

We are migrating data from **Snowflake → Postgres**. Postgres-side (or the app) uses a
**Go function that produces a UUIDv7 from a timestamp**. Snowflake has no native UUIDv7
generator. We need a **Snowflake UDF** that reproduces the exact same UUIDv7 output as the
Go function, so IDs generated/derived on the Snowflake side match the Postgres side during
and after the migration.

**Definition of done:**
1. A Snowflake UDF (SQL or JS/Python) that takes a timestamp (and any other inputs the Go
   function takes) and returns a UUIDv7 string identical to the Go output.
2. A **unit test** that validates the UDF against known Go input→output pairs — ideally
   sample vectors sourced online (RFC 9562 test vectors and/or the specific Go library's
   own tests) so we're testing against an independent reference, not just ourselves.

## Critical open question (blocks exact replication)

UUIDv7 is only **partially** determined by the timestamp. Per RFC 9562 the low bits
(`rand_a`, `rand_b`) are normally random. "Replicate the output" only makes sense if the Go
function fills those bits **deterministically** (zeroed, from a counter, or seeded). **We
need the exact Go source / library + version** to know how the non-timestamp bits are set.
Until we have it, we can build the timestamp+version+variant skeleton but not a
bit-exact match. See `decisions.md` → D-1 and `findings.md`.

## Table of Contents

| File | Purpose |
|------|---------|
| `_index.md` | This file — context, goal, TOC, status |
| `plan.md` | Tasks broken into single-session steps |
| `findings.md` | UUIDv7 layout, Go library research, sample vectors |
| `decisions.md` | Decisions (with why) + open questions |
| `progress.md` | Running session log |

## Status
- **Phase:** ✅✅ **DEPLOYED to `FES_USERS.ALEX_SOTIS` + 8/8 tests pass + examples generated
  from the live function.** (Owned by SYSADMIN; USAGE granted to FES_DATA_DEVELOPER.)
  `examples.md` holds real `UUIDV7()` output and is ready to send. If a shared home is needed,
  move to a team schema + grant the team role.
- **Phase (history):** Built + validated in Snowflake (read-only) + examples generated (Option A).
  Reference = `gofrs/uuid NewV7` (74 random bits → not reproducible); goal = "Snowflake mints
  valid v7s" (D-4). Implementation = **pure SQL** (D-2).
- **Validated in-DB:** 50k rows all-pass (distinct/regex/version/variant/ts-round-trip) +
  exact RFC 9562 vector reconstruction. Real examples in `examples.md`.
- **Deliverables:** `sql/uuidv7.sql` (pure-SQL UDFs), `sql/test_uuidv7.sql` (8 in-DB checks),
  `examples.md` (hand-off for the Go/Postgres team), `verify_local.py` (offline mirror, passes).
- **Next (needs user):** deploy `sql/uuidv7.sql` (`CREATE FUNCTION` — deny-listed for me) to a
  chosen dev→prod schema, run `sql/test_uuidv7.sql` (expect 8× PASS), confirm input column
  type/precision + UTC. Then send `examples.md` to the other team.
- **Last updated:** 2026-09-14

## TOC addition
- `sql/uuidv7.sql` — the pure-SQL UDFs (assembler, generators, decoders)
- `sql/test_uuidv7.sql` — read-only PASS/FAIL suite (8 checks)
- `examples.md` — real Snowflake example outputs + contract, for the Go/Postgres team
- `verify_local.py` — offline bit-layout proof (mirrors the SQL assembler)
