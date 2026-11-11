# `pii_strategy/scripts/`

Bootstrap automation for tagging dbt model columns with PII classifications, driven by Snowflake `SYSTEM$CLASSIFY()`.

**Spec**: see `../06_classify_script.md`.
**Decisions**: `../02_decisions.md` (D8 mapping, D9 confidence threshold, D10 hashed-PII limitation, D11 NULL profile).

## Install

```bash
pip install -r pii_strategy/scripts/requirements.txt
```

Requires:
- `snow` CLI installed and an active connection (`snow connection list`)
- `dbt` CLI installed and a working profile for `fes-airflow`

## Usage

Always start with `--dry-run`. The script writes YAML files in `fes-airflow` — review the diff before committing.

```bash
# Tag one model
python pii_strategy/scripts/classify_to_yaml.py \
  --select fangraph_resolver_pii \
  --dbt-project-dir ~/repos/fes-airflow/dags/dbt \
  --target dev \
  --dry-run

# Tag all fangraph models (uses `+` graph operator for downstream)
python pii_strategy/scripts/classify_to_yaml.py \
  --select tag:fangraph \
  --dbt-project-dir ~/repos/fes-airflow/dags/dbt \
  --target dev \
  --dry-run

# Apply for real (no --dry-run); add --force to overwrite existing tags
python pii_strategy/scripts/classify_to_yaml.py \
  --select fangraph_resolver_pii \
  --dbt-project-dir ~/repos/fes-airflow/dags/dbt \
  --target dev
```

## What it does (per model)

1. `dbt ls --select <selector> --output json` → list of models with database/schema/alias and the schema YAML file path.
2. `CALL SYSTEM$CLASSIFY('<db>.<schema>.<alias>', NULL)` via `snow sql`.
3. Saves the raw output to `pii_strategy/classify_runs/<model>_<timestamp>.json` (audit trail).
4. Splits classifications by confidence: HIGH → auto-apply, MEDIUM/LOW → logged for engineer review.
5. Maps Snowflake `semantic_category` → FES `(classification, pii_category)` via `mapping.py` (includes the FAN-override cases for DOB and partial-address fragments).
6. Edits the model's schema YAML via `ruamel.yaml`:
   - Adds the column entry if missing.
   - Updates `meta.classification` and `meta.pii_category`.
   - Skips columns that already have `meta.classification` unless `--force`.
   - Adds a `# auto-tagged YYYY-MM-DD via SYSTEM$CLASSIFY (...)` comment so engineers know what was auto-applied.

## Files

| File | Purpose |
|---|---|
| `classify_to_yaml.py` | CLI entrypoint, orchestrator |
| `mapping.py` | Snowflake → FES classification mapping (with FAN overrides) |
| `dbt_resolver.py` | Wraps `dbt ls`, finds each model's schema YAML |
| `snowflake_classify.py` | Wraps `snow sql -q "CALL SYSTEM$CLASSIFY(...)"` and parses output |
| `yaml_editor.py` | Round-trip YAML editor (preserves comments/formatting via ruamel) |
| `requirements.txt` | `ruamel.yaml` |
| `tests/` | Unit tests for the deterministic pieces (mapping, YAML edits) |

## Limitations

- **Hashed PII is not detected** (see D10). Engineer review is the safety net.
- **Confidence threshold defaults to HIGH** (D9). MEDIUM classifications are logged but not applied; pass `--min-confidence MEDIUM` to relax.
- **Unmapped semantic_categories** are logged and skipped (zero-doc principle — better no tag than wrong tag).

## Tests

```bash
cd pii_strategy/scripts
python -m unittest discover tests
```
