"""Round-trip YAML editor for dbt schema files.

Uses ruamel.yaml to preserve comments, key order, and quoting style. PyYAML
would destroy all of that on every classify run.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq


def make_yaml() -> YAML:
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096  # avoid line wrapping
    yaml.indent(mapping=2, sequence=4, offset=2)
    return yaml


@dataclass
class TagUpdate:
    """One column to tag (or update)."""
    column_name: str
    classification: str
    pii_category: str
    confidence: str        # HIGH/MEDIUM/LOW from Snowflake
    semantic_category: str # raw Snowflake semantic_category (for the trailing comment)


@dataclass
class TagResult:
    """Outcome of attempting to apply a TagUpdate."""
    column_name: str
    action: str            # "added" | "updated" | "skipped-existing" | "skipped-no-model"
    detail: str = ""


def apply_tags_to_yaml(
    yaml_path: Path,
    model_name: str,
    updates: list[TagUpdate],
    *,
    force: bool = False,
    run_date: str | None = None,
    dry_run: bool = False,
) -> tuple[list[TagResult], str | None]:
    """Apply a list of column tag updates to the given model in the given YAML file.

    Returns (results, new_text). If dry_run is True, new_text is the would-be
    file contents but the file is NOT written. Caller decides whether to write.
    """
    yaml = make_yaml()
    text = yaml_path.read_text()
    doc = yaml.load(text)

    target_model = _find_model_entry(doc, model_name)
    if target_model is None:
        return (
            [TagResult(u.column_name, "skipped-no-model", f"model '{model_name}' not found in {yaml_path}") for u in updates],
            None,
        )

    results: list[TagResult] = []
    columns = target_model.get("columns")
    if columns is None:
        columns = CommentedSeq()
        target_model["columns"] = columns

    for update in updates:
        existing = _find_column_entry(columns, update.column_name)
        comment = _build_auto_tag_comment(update, run_date)

        if existing is None:
            new_col = CommentedMap()
            new_col["name"] = update.column_name
            meta = CommentedMap()
            meta["classification"] = update.classification
            meta["pii_category"] = update.pii_category
            new_col["meta"] = meta
            new_col.yaml_set_comment_before_after_key(
                "meta", before=comment, indent=8
            )
            columns.append(new_col)
            results.append(TagResult(update.column_name, "added"))
        else:
            current_meta = existing.get("meta") or {}
            current_classification = current_meta.get("classification")
            if current_classification and not force:
                results.append(TagResult(
                    update.column_name,
                    "skipped-existing",
                    f"already tagged classification={current_classification!r}, use --force to overwrite",
                ))
                continue
            meta = existing.get("meta")
            if meta is None:
                meta = CommentedMap()
                existing["meta"] = meta
            meta["classification"] = update.classification
            meta["pii_category"] = update.pii_category
            existing.yaml_set_comment_before_after_key(
                "meta", before=comment, indent=8
            )
            results.append(TagResult(
                update.column_name,
                "updated" if current_classification else "added",
                f"was {current_classification!r}" if current_classification else "",
            ))

    import io
    buf = io.StringIO()
    yaml.dump(doc, buf)
    new_text = buf.getvalue()
    if not dry_run:
        yaml_path.write_text(new_text)
    return results, new_text


def _find_model_entry(doc, model_name: str):
    """Locate a model dict by name. Handles standard `version: 2 / models: [...]`."""
    if isinstance(doc, dict) and "models" in doc:
        for m in doc["models"]:
            if isinstance(m, dict) and m.get("name") == model_name:
                return m
    # Fall back to flat list at root (less common)
    if isinstance(doc, list):
        for m in doc:
            if isinstance(m, dict) and m.get("name") == model_name:
                return m
    return None


def _find_column_entry(columns, column_name: str):
    for c in columns:
        if isinstance(c, dict) and c.get("name") == column_name:
            return c
    return None


def _build_auto_tag_comment(update: TagUpdate, run_date: str | None) -> str:
    date_part = f" {run_date}" if run_date else ""
    return (
        f"# auto-tagged{date_part} via SYSTEM$CLASSIFY "
        f"(semantic={update.semantic_category}, confidence={update.confidence})"
    )
