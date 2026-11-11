# `SYSTEM$CLASSIFY()` → YAML Automation Script

Script that takes a dbt selector, runs `SYSTEM$CLASSIFY()` against each matched model's materialized Snowflake table, and edits the model's schema YAML to add `meta.classification` and `meta.pii_category` tags.

**Status**: Built and tested. Lives in `fes-airflow/dags/dbt/python_scripts/pii_classify/`. 16 unit tests pass (9 mapping + 7 yaml_editor). End-to-end run pending.

**Why it lives in fes-airflow, not brock-bot**: the script depends on `dbt` CLI with fes-airflow's profile env vars (e.g. `DBT_ENV_USER`) and writes to YAML files inside fes-airflow. Co-locating with the dbt project removes cross-repo path juggling. The design docs in this folder (brock-bot) remain the source of truth for the spec, mapping decisions, and rollout plan.

## Why a script (not an LLM)

The user explicitly chose deterministic over LLM-driven: "this seems repeatable enough that we shouldn't need an LLM to interpret the output and change the yaml file." The classify output is structured JSON; YAML edits are mechanical. Pure code.

## Workflow

```
1. User runs:
     python pii_strategy/scripts/classify_to_yaml.py \
       --model dim_customer \
       --database fangraph_dev \
       --dry-run

2. Script:
   a. Resolves dbt model → Snowflake table (via dbt manifest)
   b. Runs `CALL SYSTEM$CLASSIFY('<db>.<schema>.<table>', NULL)` via snow CLI
   c. Stores raw output to pii_strategy/classify_runs/<model>_<timestamp>.json
   d. Parses classify output → desired YAML state per column
   e. Reads existing schema.yml → current YAML state per column
   f. Diffs: prints what would change (in --dry-run) or applies changes
   g. On apply: writes back schema.yml using ruamel.yaml (preserves formatting, comments, key order)

3. User reviews git diff, commits.
```

## Output structure (confirmed from `classify_runs/sample_fangraph.json`)

```json
{
  "classification_result": {
    "<COLUMN_NAME>": {
      "alternates": [],
      "recommendation": {                   // PRESENT only if classified
        "confidence": "HIGH" | "MEDIUM",    // "LOW" possible per Snowflake docs
        "coverage": 0.46,                   // fraction of values matching this category
        "details": [                        // sub-classifiers (e.g., US_STREET_ADDRESS vs CA_STREET_ADDRESS)
          { "coverage": 0.46, "semantic_category": "US_STREET_ADDRESS" }
        ],
        "privacy_category": "IDENTIFIER" | "QUASI_IDENTIFIER" | "SENSITIVE",
        "semantic_category": "EMAIL" | "NAME" | "PHONE_NUMBER" | ...,
        "tags": [
          { "tag_applied": false, "tag_name": "snowflake.core.semantic_category", "tag_value": "..." },
          { "tag_applied": false, "tag_name": "snowflake.core.privacy_category", "tag_value": "..." }
        ]
      },
      "valid_value_ratio": 0.46
    }
  }
}
```

Key rules for the parser:
- A column with no `recommendation` key → unclassified, skip.
- Multiple alternates (`alternates: [...]`) — not seen in fangraph sample but per docs they appear when classifier is uncertain. Treat as MEDIUM-equivalent: skip + log.
- `details[]` is sub-classification (locale). We use the top-level `semantic_category` for mapping; `details` only relevant if we ever want locale-specific tagging.

## Snowflake → FES classification mapping

Locked table. Two override cases (DOB and address fragments) where FAN catalog is stricter than Snowflake. See [`02_decisions.md`](02_decisions.md) D8 for reasoning.

| Snowflake `semantic_category` | Snowflake `privacy_category` | FES `classification` | FES `pii_category` | Notes |
|---|---|---|---|---|
| EMAIL | IDENTIFIER | `critical` | `email` |  |
| NAME | IDENTIFIER | `critical` | `name` |  |
| PHONE_NUMBER | IDENTIFIER | `critical` | `phone` |  |
| STREET_ADDRESS | IDENTIFIER | `critical` | `address` | Has house number per Snowflake's classifier |
| DATE_OF_BIRTH | QUASI_IDENTIFIER | `critical` | `dob` | **Override** — FAN says DOB is Critical |
| CITY | QUASI_IDENTIFIER | `highly_confidential` | `address_partial` | **Override** — FAN says partial address fragments are HC |
| ADMINISTRATIVE_AREA_1 | QUASI_IDENTIFIER | `highly_confidential` | `address_partial` | **Override** — state field, partial address |
| COUNTRY | QUASI_IDENTIFIER | `highly_confidential` | `address_partial` | **Override** — partial address |
| POSTAL_CODE | QUASI_IDENTIFIER | `highly_confidential` | `address_partial` | **Override** — partial address |
| AGE | QUASI_IDENTIFIER | `highly_confidential` | `age` | Not in FAN catalog explicitly; conservative bucket |
| GENDER | QUASI_IDENTIFIER | `highly_confidential` | `gender` | Not in FAN catalog explicitly; conservative bucket |
| SALARY | SENSITIVE | `highly_confidential` | `salary` | FAN: "Employee Salary" = HC. Note: AAIA_INCOME_* in fangraph is census-derived income (not employee salary) — engineer should review. Conservative default. |

### Unmapped categories

If `semantic_category` is not in the table above:
- Log it as `[CLASSIFY-UNMAPPED] <table>.<column> = <semantic_category>`
- Do not write a tag (zero-doc principle)
- These accumulate as a TODO list of mapping extensions

Categories observed in production but not yet in the mapping should be added here in a future update.

## Confidence threshold

Per D9 ([`02_decisions.md`](02_decisions.md)):

| Snowflake `confidence` | Behavior |
|---|---|
| HIGH | Auto-apply tag (regardless of `coverage` — sparse columns still hold PII) |
| MEDIUM | Skip, log as `[CLASSIFY-REVIEW] <table>.<column> needs review` |
| LOW | Skip silently |

`--min-confidence` CLI flag overrides this default (e.g., `--min-confidence MEDIUM` to auto-apply MEDIUM too — not recommended).

## Classification profile: NULL is correct for V1

The 2nd argument to `SYSTEM$CLASSIFY('<table>', <profile>)` accepts a classification profile object that can override defaults. We pass NULL — locked as D11 in [`02_decisions.md`](02_decisions.md). Brief reasoning:

| Profile setting | What it would do | V1 decision |
|---|---|---|
| `auto_tag: true` | Writes `snowflake.core.semantic_category` and `snowflake.core.privacy_category` directly as Snowflake column tags | **No** — would create a 2nd source of truth alongside dbt YAML |
| `custom_classifiers` | Adds column-name regex or value-pattern classifiers | **No** — would help with hashed PII (col name `*email*` + hex values) but that's F7 |
| `sample_size` | Override the default ~10k row sample | **No** — default is sufficient |
| `include_columns` / `exclude_columns` | Scope the run | **No** — we want all columns scanned |

When V2 wants column-name heuristics for hashed PII, we'd create a named profile (e.g., `GOVERNANCE.CLASSIFICATION.FES_PII_PROFILE`) then. Not before.

## Limitations (documented)

### Hashed PII is not detected (V1 known limitation, D10)

`SYSTEM$CLASSIFY()` inspects values. Hashed PII (MD5/SHA email, phone, name) is hex strings that match no built-in classifier. Confirmed via `sample_hashed_email_detection.json`: column `N_QP` (= `MD5(fangraph_email)`) returned no recommendation.

Per the FAN catalog, hashed PII is still PII-classified. The classifier just can't see it. Mitigations:

1. **Engineer review during initial tag rollout** — current Phase 1 approach.
2. **Naming convention** — require hashed-PII columns to follow a pattern (e.g., `*_hashed`, `*_md5`). Script can pattern-match.
3. **Lineage propagation** (F7, future) — walk the dbt manifest, propagate PII tags through `ref()` chains. A column derived from `MD5(upstream_email)` inherits the email tag.

**V1 stance**: accept and document. Engineer review during initial tag rollout catches hashed-PII columns. No code changes attempted in V1.

### Coverage with small samples

`coverage` is the fraction of values matching the category. With small sample tables (the user's test was `LIMIT 50`), coverage can be misleadingly low. E.g., `FANGRAPH_DOB` showed coverage 0.02 but HIGH confidence — meaning of the 1 non-null DOB in 50 rows, classification was correct.

The fix: trust `confidence` not `coverage`. The script does this by default (D9).

For production runs, prefer sampling against larger tables or using `SYSTEM$CLASSIFY()` with a profile that increases sample size.

## CLI

```
python pii_strategy/scripts/classify_to_yaml.py \
  --model <dbt_model_name> \
  [--database <override_db>]              # default: read from dbt target
  [--schema <override_schema>]            # default: read from manifest
  [--dry-run]                             # show diff, don't write
  [--force]                               # overwrite existing meta.classification (default: skip if already tagged)
  [--min-confidence HIGH|MEDIUM]          # default: HIGH
  [--verbose]                             # log unmapped categories and MEDIUM-skipped columns
```

## File layout

Lives in `fes-airflow`:

```
fes-airflow/dags/dbt/python_scripts/pii_classify/
├── classify_to_yaml.py          # CLI entrypoint, orchestrator
├── mapping.py                   # Snowflake → FES mapping (D8 overrides included)
├── dbt_resolver.py              # wraps `dbt ls`, finds each model's schema YAML
├── snowflake_classify.py        # wraps `snow sql -q "CALL SYSTEM$CLASSIFY(...)"`
├── yaml_editor.py               # ruamel.yaml round-trip editor
├── requirements.txt             # ruamel.yaml
├── README.md                    # usage docs
├── .gitignore                   # ignores .venv/, classify_runs/, __pycache__
└── tests/
    ├── test_mapping.py          # 9 tests (lock FAN-override cases)
    └── test_yaml_editor.py      # 7 tests (round-trip preserves comments/formatting)
```

Runs via tox from the `fes-airflow` repo root:

```bash
# Dry run against one model
tox -e pii-classify -- --select fangraph_resolver_pii --target dev --dry-run --verbose

# Real apply across all fangraph models
tox -e pii-classify -- --select tag:fangraph --target dev

# Unit tests
tox -e pii-classify-test
```

The `[testenv:pii-classify]` and `[testenv:pii-classify-test]` envs are defined in `fes-airflow/tox.ini`. They install `requirements/requirements-dbt.txt` (which provides `dbt-core` + transitive `ruamel.yaml`), so `dbt` is on PATH inside the env and YAML round-tripping works.

`snow` CLI must be available system-wide with an active connection (separate from the tox env).

Don't add this as a dbt macro — it's an occasional bootstrap tool, not part of the dbt run loop.

## YAML write behavior

For each column in the table:
- **Already has `meta.classification`** → skip (unless `--force`)
- **No Snowflake classification, MEDIUM/LOW confidence, or unmapped category** → skip, log
- **HIGH confidence, mapped category** → add `meta.classification` and `meta.pii_category`

Add a comment marker so engineers can find auto-tagged columns later:

```yaml
columns:
  - name: fangraph_email
    description: Customer email address
    meta:
      classification: critical    # auto-tagged 2026-06-10 via SYSTEM$CLASSIFY (HIGH conf)
      pii_category: email
```

The comment is added on first auto-tag. On `--force` re-runs, the comment is updated with the new run date.

### ruamel.yaml requirement

dbt schema YAMLs contain comments, key ordering, and quoting choices that PyYAML destroys. ruamel.yaml's round-trip loader preserves all of that. **The script MUST use ruamel.yaml, not PyYAML.**

```python
from ruamel.yaml import YAML
yaml = YAML()
yaml.preserve_quotes = True
yaml.indent(mapping=2, sequence=4, offset=2)
```

## Test plan

Using existing samples in `classify_runs/`:

1. **Parser test** — `sample_fangraph.json` has 497 columns, 41 classified. Test that parser:
   - Identifies all 41 as classified
   - Maps 5 EMAIL columns → `critical/email`
   - Maps 4 STATE columns → `highly_confidential/address_partial` (override case)
   - Skips `COMMERCE_PRODUCT_PLAYER_NAME` (MEDIUM confidence)
   - Logs unmapped categories (if any new ones appear)

2. **Override test** — Verify DOB (`FANGRAPH_DOB`) maps to `critical/dob` despite Snowflake's `QUASI_IDENTIFIER`.

3. **Negative test** — `sample_hashed_email_detection.json` returns no recommendations. Script should produce zero YAML edits and zero error.

4. **Idempotency test** — Run twice in `--dry-run`: second run should show zero diff.

5. **End-to-end** — Pick a small `fangraph_dev` model, run script `--dry-run`, review output, run for real, `dbt run` the model, verify masking via `INFORMATION_SCHEMA.POLICY_REFERENCES`.

## Open questions for this doc

- Sample size for production classify runs. SYSTEM$CLASSIFY default is ~10k rows; can be increased via profile config. Probably fine as-is — engineer review catches edge cases.
- Should the script accept multiple models in one invocation? Probably yes (`--model dim_customer dim_order ...` or `--all-models-in-schema fangraph_dev`). Phase 1: single-model. Add bulk in Phase 2.
