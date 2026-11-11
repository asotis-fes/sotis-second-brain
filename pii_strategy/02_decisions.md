# Decision Log

Append-only record of design decisions. Resolved decisions are summarized in [`01_design.md`](01_design.md); this file captures the reasoning and any open questions.

## Resolved

### D1 — Mask value: type-aware non-null sentinels (option C)
**Date**: 2026-06-10
**Question**: What value do masked columns return? NULL, hashed, or a sentinel?
**Decision**: Non-null sentinels, type-aware. `'*** MASKED ***'` for STRING, `-1` for NUMBER, `'1900-01-01'` for DATE, etc.
**Why**:
- Hashing was rejected — the FAN catalog explicitly states "If data is encrypted or hashed, does that change the classification? No, it does not change the classification." Hashing offers no compliance benefit and adds CPU cost (confirmed in `snowflake_masking_tax/` — P_HASH was 50%+ slower).
- NULL would break downstream joins/aggregations where columns are NOT NULL.
- Type-aware sentinels preserve NOT NULL semantics and signal "this is masked" visibly to humans.
**Trade-off**: Sentinels can poison `MAX(LENGTH(...))` or `COUNT(DISTINCT)` reporting if analysts forget they're masked. Mitigation: descriptive sentinel value makes it obvious.

### D2 — One PII reader role (option A)
**Date**: 2026-06-10
**Question**: One role unlocks all PII, or tiered roles per classification?
**Decision**: Start with one role: `FES_PII_READER`. Migrate to tiered when a use case justifies it.
**Why**:
- Avoids doubling the role hierarchy in `fanapp-terraform`.
- Most analyst access patterns are all-or-nothing for PII in this domain.
- YAML tag schema (D3) preserves enough information to migrate to tiered roles later without re-tagging.
**Migration path**: When tiered is needed, split `FES_PII_READER` into `FES_PII_READER_CRITICAL` + `FES_PII_READER_HC` (and possibly more). Update the masking policy body to check `IS_ROLE_IN_SESSION()` per tier. Update YAML enforcement to route based on `classification`.

### D3 — Categorical tag taxonomy (option B)
**Date**: 2026-06-10
**Question**: Boolean `pii: true` flag, or categorical tags?
**Decision**: Dual-key categorical: `meta.classification` (tier) + `meta.pii_category` (element).
**Why**:
- `classification` drives the policy decision (mask if critical or highly_confidential).
- `pii_category` (email, name, address, phone, dob, ssn, …) preserves audit-trail granularity and enables tiered roles later.
- Aligns with the FAN Data Classification Catalog structure.
- Adding both is free now; reverse-engineering later is expensive.
**Tag enum**: see [`03_classification_catalog.md`](03_classification_catalog.md).

### D4 — Pilot on `fangraph_dev`, not `fangraph`
**Date**: 2026-06-10
**Question**: Where to start the rollout?
**Decision**: `fangraph_dev` database (the dev sandbox).
**Why**: Fangraph has heavy PII (names, emails, addresses, DOB, phone), is well-known, and the dev DB is safe to break. Once stable, promote to prod `fangraph`.

### D5 — on-run-end orchestration (with `FORCE`)
**Date**: 2026-06-10
**Question**: post-hook per model, or on-run-end sweep?
**Decision**: on-run-end macro scanning the dbt manifest; uses `ALTER … SET MASKING POLICY <p> FORCE` for idempotency.
**Why**:
- Single source of truth: one place that knows desired state.
- `FORCE` handles both fresh tables (`create or replace`) and persistent tables (incremental) uniformly — no conditional logic needed.
- Drift detection: every run reasserts desired state; manual `ALTER`s outside dbt get clobbered.
- Implicit skip: models with no tagged columns produce no DDL.
**Known limitation**: Brief race window after `create or replace` and before on-run-end. Acceptable in MWAA service context. Documented; not mitigated.
**Future ticket**: Skip ALTER for incremental models (policy persists across runs). Saves a metadata op per column per run.

### D6 — MWAA service user grants `FES_PII_READER`
**Date**: 2026-06-10
**Question**: Does the dbt service role see masked or real PII?
**Decision**: Real. Grant `FES_PII_READER` to the MWAA service user.
**Why**:
- dbt tests that compare exact values (uniqueness, accepted_values, custom data tests) need real data.
- The MWAA service user is non-interactive — no human reads raw query output directly.
**Follow-up**: CI log handling. dbt failure messages can contain example values. If this becomes a concern, configure dbt to suppress sample rows in test failures, or run a separate redaction step on logs.

### D7 — Greenfield (no migration)
**Date**: 2026-06-10
**Question**: Is there existing masking, classification tagging, or PII column tagging to migrate from?
**Decision**: No. Start clean.

### D8 — Snowflake → FES classification mapping (with explicit overrides)
**Date**: 2026-06-10
**Question**: When Snowflake's `SYSTEM$CLASSIFY()` returns `(privacy_category, semantic_category)`, what is our `(classification, pii_category)`?
**Decision**: Locked mapping table in [`06_classify_script.md`](06_classify_script.md) "Mapping". Two cases override Snowflake's recommendation because the FAN catalog is stricter:
- **DOB** — Snowflake says `QUASI_IDENTIFIER`; FAN catalog says Customer DOB is Critical. We override to `critical`.
- **Partial address fragments** (CITY, ADMINISTRATIVE_AREA_1, COUNTRY, POSTAL_CODE individually) — Snowflake says `QUASI_IDENTIFIER`; FAN catalog rule explicitly classifies "any combination of street name, city, state, zip code that does not include house number" as Highly Confidential. We map each fragment to `highly_confidential` with `pii_category: address_partial`.
**Why**: FAN catalog is the legal/compliance source of truth; Snowflake's classifier is a useful but not authoritative signal.

### D9 — Confidence threshold and behavior
**Date**: 2026-06-10
**Question**: When does the classify-to-YAML script auto-apply vs flag for review?
**Decision**:
- **HIGH confidence** (any coverage) → auto-apply tag.
- **MEDIUM confidence** → skip, log for engineer review.
- **LOW confidence** (not seen in sample but documented in Snowflake) → skip silently.
**Why**:
- Coverage in small samples is noisy — a DOB column at 2% coverage (mostly null) still holds DOB in its non-null rows. Confidence is the better filter.
- MEDIUM is exactly the "Tom Brady" case (`COMMERCE_PRODUCT_PLAYER_NAME` flagged NAME — probably product names, not people). Engineer eye catches these.
- Better no tag than wrong tag (zero-doc principle from `dbt-column-documenter` skill).

### D10 — Hashed PII detection: V1 known limitation, accepted
**Date**: 2026-06-10
**Question**: Snowflake `SYSTEM$CLASSIFY()` doesn't detect MD5-hashed email. Solve it in V1, or accept and document?
**Decision**: **Accept and document as a V1 known limitation.** Do not attempt to solve in V1.
**Why**:
- The classifier inspects values. MD5/SHA hashes are hex strings that match no built-in pattern. This is fundamental, not a config issue.
- Solving it properly requires **lineage propagation** through the dbt manifest (a column derived from `MD5(upstream.email)` should inherit `email` tags). That's a meaningful feature, not a quick fix.
- Solving it cheaply requires **column-name heuristics** in a custom classifier (e.g., col name contains "email" AND values look like 32-char hex). That's fragile and incomplete.
- Per the FAN catalog, hashed PII is still PII-classified — but if `SYSTEM$CLASSIFY()` misses it, engineer review during initial rollout catches it. This is the V1 safety net.
**V1 mitigation**: Engineer review of all auto-tagged tables before commit (already part of the workflow). Document in `06_classify_script.md` Limitations section.
**Follow-up (F7)**: Lineage-based PII tag propagation through dbt `ref()` chains. Phase 3+.

### D12 — Lazy type expansion for masking policies
**Date**: 2026-06-11
**Question**: Should we pre-create `FES_PII_MASK_*` policies for every Snowflake data type (FLOAT, BOOLEAN, TIMESTAMP_NTZ/TZ/LTZ, VARIANT, …) or only what's actually needed?
**Decision**: Only what's needed. V1 ships STRING, NUMBER, DATE — the three types observed on PII columns in fangraph_dev. Other types are added when a column of that type is flagged as PII.
**Why**:
- Snowflake's type system is strict, but most PII is STRING (names/emails/addresses/phones), NUMBER (rare — age/phone-as-number), DATE (DOB). FLOAT/BOOLEAN/TIMESTAMP PII is rare in practice.
- Adding 6+ speculative policies in terraform inflates the review surface for no validated need.
- The `get_masking_policy_for_type` macro returns empty string for unmapped types, and the calling macro logs and skips with an actionable message ("add a `FES_PII_MASK_FLOAT` policy if needed"). No crash.
**How to expand**: when a new type is required, add one mapping line in `get_masking_policy_for_type.sql` AND one Snowflake masking policy in the terraform module. Single PR.

### D11 — Use default classification profile (NULL) for V1
**Date**: 2026-06-10
**Question**: Should we create a custom Snowflake classification profile, or pass NULL as the 2nd argument to `SYSTEM$CLASSIFY()`?
**Decision**: **Pass NULL** for V1. No custom profile.
**Why**:
- We do NOT want `auto_tag=true`. That setting writes `snowflake.core.semantic_category` and `snowflake.core.privacy_category` as Snowflake tags directly on the column — which would create a second source of truth alongside our dbt YAML tags. One source of truth (dbt YAML) is the design.
- We do not need `custom_classifiers` in V1. Default classifiers covered all expected cases in the fangraph sample (EMAIL, NAME, PHONE_NUMBER, STREET_ADDRESS, DOB, etc.).
- We do not need custom `sample_size` — Snowflake's default (~10k rows) is sufficient for pattern detection.
- NULL is stable and requires no governance object to maintain.
**When to revisit**: If V2 wants to detect hashed PII via column-name heuristics, that's the case for a custom classifier — and at that point we'd create a named profile (e.g., `GOVERNANCE.CLASSIFICATION.FES_PII_PROFILE`).

## Open

None at the moment. Add new questions here as they surface.

## Future considerations (tracked, not decided)

- **F1 — Tiered roles**: Migrate to per-tier roles when a use case justifies it (see D2).
- **F2 — Incremental skip optimization**: Skip ALTER on incremental models where policy persists (see D5).
- **F3 — View masking**: Currently table-only. If we materialize PII-bearing views, decide whether to mask at view level or upstream.
- **F4 — Cross-tenant PII**: Some data (e.g., loyalty earn/burn) spans tenants. Confirm masking covers all replicated tables.
- **F5 — Snapshot masking**: dbt snapshots (`snapshots/`) get the same treatment? They're tables — should be in scope. Confirm during pilot.
- **F6 — Test log hardening**: Suppress PII in dbt test failure output if D6 follow-up becomes a real concern.
- **F7 — Hashed-PII detection via dbt lineage**: `SYSTEM$CLASSIFY()` can't detect hashed PII from values. Build a separate tagger that propagates tags through `ref()` chains in the dbt manifest, so a `MD5(email)` column inherits the email tag from its upstream. Phase 3+.
