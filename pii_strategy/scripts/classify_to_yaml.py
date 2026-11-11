#!/usr/bin/env python3
"""Run SYSTEM$CLASSIFY against every model matching a dbt selector and write
classification tags to each model's schema YAML.

Workflow per model:
  1. Resolve via `dbt ls --select <selector>` -> database, schema, alias, yaml_path
  2. CALL SYSTEM$CLASSIFY('<db>.<schema>.<alias>', NULL) via the snow CLI
  3. Save raw output to pii_strategy/classify_runs/<model>_<timestamp>.json
  4. Map Snowflake (privacy_category, semantic_category) -> FES (classification, pii_category)
  5. Edit the model's schema YAML via ruamel.yaml (preserves comments/formatting)

Spec: pii_strategy/06_classify_script.md
Mapping decisions: pii_strategy/02_decisions.md D8/D9/D10/D11

Run from the brock-bot repo root:

  python pii_strategy/scripts/classify_to_yaml.py \\
    --select fangraph_resolver_pii \\
    --dbt-project-dir ~/repos/fes-airflow/dags/dbt \\
    --target dev \\
    --dry-run
"""

from __future__ import annotations

import argparse
import sys
from datetime import date
from pathlib import Path

# Make script runnable as both module and script
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from dbt_resolver import list_models, DbtResolverError  # noqa: E402
from mapping import map_semantic_category  # noqa: E402
from snowflake_classify import (  # noqa: E402
    classify_table, parse_classifications, save_classify_run, SnowflakeClassifyError,
)
from yaml_editor import apply_tags_to_yaml, TagUpdate  # noqa: E402


REPO_ROOT = SCRIPT_DIR.parent.parent  # pii_strategy/scripts/ -> pii_strategy/ -> repo root
CLASSIFY_RUNS_DIR = REPO_ROOT / "pii_strategy" / "classify_runs"


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)

    dbt_project_dir = args.dbt_project_dir.resolve()
    if not (dbt_project_dir / "dbt_project.yml").exists():
        print(f"ERROR: no dbt_project.yml at {dbt_project_dir}", file=sys.stderr)
        return 2

    print(f"[classify] resolving dbt selector: {args.select}")
    try:
        models = list_models(args.select, dbt_project_dir, target=args.target)
    except DbtResolverError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if not models:
        print("[classify] no models matched the selector. exiting.")
        return 0
    print(f"[classify] {len(models)} model(s) matched")

    CLASSIFY_RUNS_DIR.mkdir(parents=True, exist_ok=True)
    run_date = date.today().isoformat()
    total_auto = total_review = total_unmapped = total_added = total_updated = total_skipped = 0

    for m in models:
        print(f"\n[classify] === {m.unique_id} -> {m.fqn} ===")
        if not m.yaml_path:
            print(f"  WARN: no schema YAML found for {m.name}; skipping")
            continue
        if not m.database or not m.schema:
            print(f"  WARN: manifest has empty database/schema for {m.name}; skipping")
            continue

        try:
            raw = classify_table(m.fqn, snow_connection=args.snow_connection)
        except SnowflakeClassifyError as e:
            print(f"  ERROR: SYSTEM$CLASSIFY failed: {e}", file=sys.stderr)
            if args.continue_on_error:
                continue
            return 3

        saved = save_classify_run(raw, m.name, CLASSIFY_RUNS_DIR)
        print(f"  saved raw output -> {saved.relative_to(REPO_ROOT)}")

        auto, review = parse_classifications(raw, min_confidence=args.min_confidence)
        print(f"  classifications: {len(auto)} auto-apply, {len(review)} needs-review")

        if args.verbose:
            for r in review:
                print(f"    [REVIEW] {r.column} = {r.semantic_category} (confidence={r.confidence})")

        updates: list[TagUpdate] = []
        for cc in auto:
            fes = map_semantic_category(cc.semantic_category)
            if not fes:
                total_unmapped += 1
                if args.verbose:
                    print(f"    [UNMAPPED] {cc.column} = {cc.semantic_category}")
                continue
            updates.append(TagUpdate(
                column_name=cc.column.lower(),  # YAML uses lowercase; Snowflake returns uppercase
                classification=fes.classification,
                pii_category=fes.pii_category,
                confidence=cc.confidence,
                semantic_category=cc.semantic_category,
            ))

        total_auto += len(auto)
        total_review += len(review)

        if not updates:
            print("  no mapped tags to apply")
            continue

        print(f"  applying {len(updates)} tag(s) to {m.yaml_path.relative_to(dbt_project_dir)}"
              + (" [DRY RUN]" if args.dry_run else ""))
        results, _ = apply_tags_to_yaml(
            m.yaml_path,
            model_name=m.name,
            updates=updates,
            force=args.force,
            run_date=run_date,
            dry_run=args.dry_run,
        )
        for r in results:
            print(f"    [{r.action}] {r.column_name}" + (f"  ({r.detail})" if r.detail else ""))
            if r.action == "added":
                total_added += 1
            elif r.action == "updated":
                total_updated += 1
            else:
                total_skipped += 1

    print("\n[classify] === summary ===")
    print(f"  models processed:    {len(models)}")
    print(f"  classifications:     {total_auto} auto-applied / {total_review} needs-review / {total_unmapped} unmapped")
    print(f"  YAML tags:           {total_added} added, {total_updated} updated, {total_skipped} skipped"
          + (" [DRY RUN - no files written]" if args.dry_run else ""))
    return 0


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--select", required=True,
                   help="dbt selector (e.g., 'fangraph_resolver_pii', 'tag:fangraph', 'fangraph/+')")
    p.add_argument("--dbt-project-dir", type=Path, required=True,
                   help="path to fes-airflow/dags/dbt")
    p.add_argument("--target",
                   help="dbt target (default: user's profiles.yml default)")
    p.add_argument("--min-confidence", choices=["HIGH", "MEDIUM"], default="HIGH",
                   help="auto-apply threshold (default: HIGH)")
    p.add_argument("--force", action="store_true",
                   help="overwrite existing meta.classification (default: skip)")
    p.add_argument("--dry-run", action="store_true",
                   help="don't write YAML files; print diffs instead")
    p.add_argument("--snow-connection",
                   help="snow CLI connection name (default: snow's default)")
    p.add_argument("--continue-on-error", action="store_true",
                   help="if SYSTEM$CLASSIFY fails on one model, continue with the next")
    p.add_argument("--verbose", "-v", action="store_true",
                   help="log MEDIUM-confidence skips and unmapped categories")
    return p.parse_args(argv)


if __name__ == "__main__":
    sys.exit(main())
