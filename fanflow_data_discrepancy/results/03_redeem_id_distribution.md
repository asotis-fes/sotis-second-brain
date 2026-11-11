# Step 3 — redeem_id distribution

## Result

| redeem_id_kind | txn_status | missing_count |
|---|---|---|
| null | ADD | 652 |
| null | CAPTURE_1 | 7 |
| null | AUTH | 4 |
| null | VOID_1 | 1 |

## Interpretation

- All 664 missing events have `redeem_id IS NULL`. No empty strings, no values.
- Status distribution confirmed: 0 REDEEMs in the missing set
  - 652 ADD (earns)
  - 7 CAPTURE_1 (captures)
  - 4 AUTH (auth-only)
  - 1 VOID_1 (void)
- Independently confirms Step 2: dropping `redeem_id` from the join is safe because both sides are uniformly NULL for these rows.
