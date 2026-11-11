# Loyalty Tier Points Migration

Second loyalty program migration to the fes-loyalty bucket-model Postgres backend. Follows the pattern established by the OneCredits migration (`../loyalty_ingest_migration/`, completed 2026-07-06).

## ⚠️ Instructions for Claude

Same rules as `../loyalty_ingest_migration/README.md`:
- Keep durable context in files, not the conversation
- Save durable things (decisions with reasons, table lists, open questions)
- Don't narrate every step

## Status

- **OneCredits migration**: complete (prod cutover 2026-07-06). Reference — same repo `../loyalty_ingest_migration/`.
- **Tier Points migration**: STARTING (2026-07-13). Loyalty engineer has test_-prefixed tier tables in dev PG.

## Task

Migrate the Tier Points program (currently on Salesforce Loyalty Cloud) to the same bucket-model schema OneCredits uses. Tier Points writes to the shared `transaction` and `account_balance` tables via `program_id = 2`, plus 4-5 tier-specific tables that need new ingest wiring.

Same operational shape as OneCredits:
- Dev PG has test_-prefixed sandbox tables now.
- Prod PG cutover happens later, tables become un-prefixed atomically.
- We deploy dormant, flip 2 config values at cutover.

## Loyalty Engineer's message (verbatim, 2026-07-13)

> it is test_account_balance, test_tier_account_override, test_transacrion, test_tier, test_override_configuration, test_invite_approval

`test_transacrion` is almost certainly a typo for `test_transaction`. Other names likely differ from schema doc — see `context/loyalty_eng_message.md` for full interpretation.

## Folder structure

```
loyalty_tier_points_migration/
├── README.md                              ← you are here
├── context/
│   ├── loyalty_eng_message.md              ← the message + name mapping
│   ├── onecredits_pattern_reference.md    ← what to reuse from OC migration
│   ├── schema_doc_findings_tp.md          ← tier-specific findings from main-branch schema doc
│   └── schema_docs/
│       ├── SCHEMA_DATA_main.md             ← ★ authoritative (main, fetched 2026-07-13)
│       ├── SCHEMA_DATA_schema2.md          ← OneCredits-era reference (2026-06-24)
│       └── SCHEMA_DATA_tp-lu.md            ← feature/new-ledger-schema-tp-lu (incomplete)
├── questions_to_ask.md                     ← open questions for Suneel / AE
└── (analysis/, decisions/, plans/ will be added as work proceeds)
```

## Cross-references

- Previous migration record (OneCredits): `../loyalty_ingest_migration/`
- Schema doc (fes-loyalty, schema2 branch), Tier Tables section:
  https://github.com/fanatics-gaming/fes-loyalty/blob/schema2/docs/SCHEMA_DATA.md
- Code lives in: `/Users/alex.sotis/repos/fes-airflow`
