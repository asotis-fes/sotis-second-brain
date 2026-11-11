"""Run SYSTEM$CLASSIFY against a Snowflake table via the `snow` CLI."""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ColumnClassification:
    """Parsed classification for a single column."""
    column: str
    confidence: str             # HIGH | MEDIUM | LOW
    privacy_category: str       # IDENTIFIER | QUASI_IDENTIFIER | SENSITIVE
    semantic_category: str      # EMAIL | NAME | ...
    coverage: float


class SnowflakeClassifyError(RuntimeError):
    pass


def classify_table(fqn: str, snow_connection: str | None = None) -> dict:
    """Run CALL SYSTEM$CLASSIFY('<fqn>', NULL) and return the parsed JSON.

    Raises SnowflakeClassifyError if the snow CLI fails or output is unparseable.
    """
    sql = f"CALL SYSTEM$CLASSIFY('{fqn}', NULL)"
    cmd = ["snow", "sql", "-q", sql, "--format", "json"]
    if snow_connection:
        cmd.extend(["--connection", snow_connection])

    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SnowflakeClassifyError(
            f"snow sql failed for {fqn}\n"
            f"stdout: {proc.stdout}\n"
            f"stderr: {proc.stderr}"
        )

    out = proc.stdout.strip()
    if not out:
        raise SnowflakeClassifyError(f"empty output from snow sql for {fqn}")

    try:
        rows = json.loads(out)
    except json.JSONDecodeError as e:
        raise SnowflakeClassifyError(f"could not parse snow sql JSON output for {fqn}: {e}\nraw: {out[:500]}")

    # snow --format json returns a list with one row; the SYSTEM$CLASSIFY output
    # is in a column named after the function call. Extract it.
    if not rows:
        raise SnowflakeClassifyError(f"snow sql returned no rows for {fqn}")
    first_row = rows[0]
    # The column name varies; grab the only value.
    if len(first_row) != 1:
        raise SnowflakeClassifyError(f"unexpected row shape from snow sql for {fqn}: {list(first_row.keys())}")
    raw = next(iter(first_row.values()))

    # The value is itself a JSON string in some Snowflake CLI versions; in
    # others it's already parsed.
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except json.JSONDecodeError as e:
            raise SnowflakeClassifyError(f"could not parse CLASSIFY result JSON for {fqn}: {e}\nraw: {raw[:500]}")
    return raw


def parse_classifications(
    classify_json: dict,
    min_confidence: str = "HIGH",
) -> tuple[list[ColumnClassification], list[ColumnClassification]]:
    """Split the SYSTEM$CLASSIFY result into (auto-applicable, needs-review).

    Auto-applicable: confidence meets or exceeds the threshold.
    Needs-review: classified but below threshold (e.g. MEDIUM when threshold=HIGH).
    Unclassified columns (no `recommendation` key) are not returned.
    """
    confidence_rank = {"LOW": 0, "MEDIUM": 1, "HIGH": 2}
    threshold = confidence_rank.get(min_confidence.upper(), 2)

    auto: list[ColumnClassification] = []
    review: list[ColumnClassification] = []

    result = classify_json.get("classification_result", {})
    for col_name, col_data in result.items():
        rec = col_data.get("recommendation")
        if not rec:
            continue
        conf = (rec.get("confidence") or "").upper()
        rank = confidence_rank.get(conf, -1)
        if rank < 0:
            continue
        cc = ColumnClassification(
            column=col_name,
            confidence=conf,
            privacy_category=(rec.get("privacy_category") or "").upper(),
            semantic_category=(rec.get("semantic_category") or "").upper(),
            coverage=float(rec.get("coverage", 0.0)),
        )
        if rank >= threshold:
            auto.append(cc)
        else:
            review.append(cc)

    return auto, review


def save_classify_run(classify_json: dict, model_name: str, output_dir: Path) -> Path:
    """Persist the raw classify output to output_dir for audit/debugging."""
    from datetime import datetime
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    path = output_dir / f"{model_name}_{stamp}.json"
    path.write_text(json.dumps(classify_json, indent=2))
    return path
