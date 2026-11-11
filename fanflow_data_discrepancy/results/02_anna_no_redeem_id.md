# Step 2 — Anna's verification: join without redeem_id

## Result

| | count |
|---|---|
| missing_without_redeem_id | **664** |

## Interpretation

- Confirmed. Removing `redeem_id` from the join yields the **same 664** missing events.
- For this dataset, `redeem_id` is a no-op in the join. None of the missing events are REDEEM-status transactions (which are the only ones where `redeem_id` is populated per the data dictionary).
- Anna's intuition was correct — we can drop `redeem_id` from the join in the Confluence doc to simplify the methodology description.
- The simplified 3-column join key (`loyalty_account_id`, `loyalty_txn_id`, `txn_status`) is sufficient.

## Action

- Update Confluence doc to use the 3-column join key (drop `redeem_id`)
- Note in the doc that we verified `redeem_id` had no effect on our missing-event count
