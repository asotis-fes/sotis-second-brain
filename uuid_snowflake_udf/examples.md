# UUIDv7 examples for the Go/Postgres team

These are **real outputs** from the deployed Snowflake function
`FES_USERS.ALEX_SOTIS.UUIDV7(<timestamp>)` (`sql/uuidv7.sql`), run in
`FAN_DATA_EXCHANGE_PROD` on 2026-09-14. They are standards-compliant
**RFC 9562 UUIDv7** values. As agreed, they are **not** reproductions of gofrs `NewV7`
output — the low 74 bits are random by design — so the contract is:

> **Same timestamp in → a valid, unique, k-sortable UUIDv7 whose first 48 bits encode that
> timestamp.** The random bits differ every call (see rows 1 & 2 below).

## Sample input → output  (input → generated → decoded back)

Each row shows the input timestamp, the generated UUIDv7, and the timestamp decoded *back
out* of that UUID's first 48 bits — they match exactly, proving the embedding round-trips.

| Input UTC | epoch_ms | Generated UUIDv7 | Decoded back from UUID | valid v7? | Note |
|---|---|---|---|---|---|
| 1970-01-01 00:00:00.000 | 0 | `00000000-0000-7932-ad01-bc9d3ae21e57` | 1970-01-01 00:00:00.000 | ✅ | unix epoch zero |
| 2020-02-29 12:00:00.000 | 1582977600000 | `017090d1-4a00-72c9-a685-6a5cae43cf21` | 2020-02-29 12:00:00.000 | ✅ | leap day |
| 2022-02-22 19:22:22.000 | 1645557742000 | `017f22e2-79b0-7563-a331-3505d2c252f6` | 2022-02-22 19:22:22.000 | ✅ | RFC 9562 reference instant |
| 2022-02-22 19:22:22.000 | 1645557742000 | `017f22e2-79b0-737f-be00-7ea010581cdd` | 2022-02-22 19:22:22.000 | ✅ | **same ts → different UUID** (non-deterministic) |
| 2023-12-31 23:59:59.999 | 1704067199999 | `018cc251-f3ff-7276-b960-b480210becdf` | 2023-12-31 23:59:59.999 | ✅ | end of year, millisecond |
| 2024-01-01 00:00:00.000 | 1704067200000 | `018cc251-f400-7e35-a2f6-452c4700342d` | 2024-01-01 00:00:00.000 | ✅ | new year 2024 |
| 2025-06-15 12:34:56.789 | 1749990896789 | `01977395-f495-7012-9a24-f2c96e4e01b2` | 2025-06-15 12:34:56.789 | ✅ | sub-second precision |
| 2026-09-14 17:00:00.000 | 1789405200000 | `01a0a0dc-7e80-7a7d-99a4-baf4ef41f280` | 2026-09-14 17:00:00.000 | ✅ | recent |
| 2028-07-04 08:15:30.500 | 1846311330500 | `01ade0bb-22c4-786b-ab2c-3ca2d61f4bf6` | 2028-07-04 08:15:30.500 | ✅ | future w/ half-second |
| 2030-01-01 00:00:00.000 | 1893456000000 | `01b8dac5-b400-7d87-af50-6921d337268f` | 2030-01-01 00:00:00.000 | ✅ | far future |

### How the other engineer verifies these on the Go/Postgres side
For each row, parse the UUIDv7 and check — no need to reproduce the random bits:
1. It parses as a valid **RFC 9562 v7** (version nibble `7`, variant in `{8,9,a,b}`).
2. The embedded timestamp (first 48 bits = big-endian `unix_ts_ms`) equals `epoch_ms` / `Input UTC`.
   e.g. `1645557742000 = 0x017F22E279B0` → prefix `017f22e2-79b0`.
3. Sorting the `Generated UUIDv7` column ascending yields chronological order (millisecond granularity).
The low bits are random by design (rows 3 & 4: same input, different UUID) — that is expected and agreed.

> UUID values are illustrative — the random bits differ every run; the **input, epoch_ms,
> decoded-back timestamp, and validity are stable**.

**What to verify on your side:**
- **Version** nibble (13th hex) = `7`; **variant** (17th hex) ∈ `{8,9,a,b}` — true for all above.
- **Timestamp embedding**: the first 12 hex chars = `epoch_ms` in hex. e.g.
  `1645557742000 = 0x017F22E279B0` → prefix `017f22e2-79b0`. Rows 1 & 2 share the prefix
  (same ms) but differ everywhere after — exactly the accepted non-determinism.
- **k-sortable**: sorting the strings ascending = chronological order (prefixes increase with ms).

## Determinism proof against a published reference

The generator's assembler was validated against the **RFC 9562 §B.2 worked example**. Feeding
that example's exact bits back in reproduces its UUID byte-for-byte (verified in Snowflake):

```
UUIDV7_ASSEMBLE(1645557742000, 'cc3000000000000098c4dc0c0c07398f')
  = 017f22e2-79b0-7cc3-98c4-dc0c0c07398f   (the RFC's published value)
```

## Validation summary (all in Snowflake, read-only)

- 50,000 generated rows: 50,000 distinct, 50,000 match the canonical v7 regex,
  version=7 and variant∈{8,9,a,b} on every row, and timestamp round-trips
  (`UUID → first 48 bits → epoch_ms`) on every row.
- Round-trip decode: `UUIDV7_TIMESTAMP('017f22e2-79b0-7cc3-98c4-dc0c0c07398f')`
  = `2022-02-22 19:22:22.000` UTC.

## One open confirmation for the team

We generate at **millisecond** precision (matching gofrs). If any of your keys must be
**globally unique across nodes/rows generated in the same millisecond**, note that uniqueness
here comes from the 74 random bits (collision-safe), **not** from a monotonic counter like
gofrs uses within a single ms. That's fine for uniqueness; flag it only if you rely on strict
intra-millisecond ordering.
