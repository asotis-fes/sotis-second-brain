# Step 1 — Recreate LOYALTY_MISSING_EVENTS as persistent table

## Result

- Table created: `FES_USERS.ALEX_SOTIS.LOYALTY_MISSING_EVENTS`
- Row count: **664**

## Interpretation

- Matches V2 exactly (664)
- Adding `NULLIF(..., '')` inside the COALESCE on the join keys did NOT change the count → there are no empty-string-vs-NULL mismatches on `redeem_id` or `loyalty_account_id`. Both sides treat missing values as NULL consistently.
- Table is now persistent (not TEMP) so it survives across sessions.
