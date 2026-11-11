# Step 7 — Export missing events CSV

## Output

File: `results/missing_loyalty_events_599.csv`

- Line count: 600 (1 header + 599 rows)
- Header columns (20): `EVENT_TS, GAP_HOUR_UTC, LOYALTY_ACCOUNT_ID, LOYALTY_TXN_ID, TXN_STATUS, REDEEM_ID, TXN_AMOUNT, TXN_REASON, EXTERNAL_REF_ID, SITE_ID, TENANT_ID, PRIVATE_FAN_ID, TENANT_FAN_ID, IS_TEST_TXN, IS_GUEST, ADD_TYPE, EARN_TENANT_ID, PII, RAW_PAYLOAD, RAW_ENRICHED_ATTRS`
- Includes the full raw payload JSON and raw enriched_attrs JSON for each event so the platform team has complete context

## Action

Attach this CSV to the Confluence page (https://betfanatics.atlassian.net/wiki/spaces/FAN/pages/3066134696) as the "list of missed events" Anna requested.
