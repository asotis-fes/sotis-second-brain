"""Resolve a dbt selector to the set of models we'll classify, including the
YAML file each model is documented in."""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ModelInfo:
    """A dbt model resolved from `dbt ls`, with its YAML location."""
    name: str
    unique_id: str
    database: str
    schema: str
    alias: str
    sql_path: Path
    yaml_path: Path | None  # None if the model has no schema YAML entry

    @property
    def fqn(self) -> str:
        return f"{self.database}.{self.schema}.{self.alias}"


class DbtResolverError(RuntimeError):
    pass


def list_models(selector: str, dbt_project_dir: Path, target: str | None = None) -> list[ModelInfo]:
    """Invoke `dbt ls --select <selector>` and return ModelInfo for each match.

    Uses --output json which produces one JSON object per line.
    """
    cmd = [
        "dbt", "ls",
        "--select", selector,
        "--resource-type", "model",
        "--output", "json",
        "--output-keys", "name,unique_id,original_file_path,patch_path,alias,config",
    ]
    if target:
        cmd.extend(["--target", target])

    proc = subprocess.run(
        cmd,
        cwd=str(dbt_project_dir),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise DbtResolverError(
            f"dbt ls failed with exit code {proc.returncode}\n"
            f"stdout: {proc.stdout}\n"
            f"stderr: {proc.stderr}"
        )

    models: list[ModelInfo] = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        config = entry.get("config", {}) or {}
        sql_rel = entry.get("original_file_path") or ""
        sql_path = (dbt_project_dir / sql_rel).resolve()

        patch_rel = entry.get("patch_path")
        yaml_path: Path | None = None
        if patch_rel:
            # patch_path comes back as "<project>://<rel>" — strip the prefix
            if "://" in patch_rel:
                _, rel = patch_rel.split("://", 1)
            else:
                rel = patch_rel
            yaml_path = (dbt_project_dir / rel).resolve()
        if yaml_path is None or not yaml_path.exists():
            yaml_path = _find_yaml_for_model(entry["name"], sql_path)

        models.append(ModelInfo(
            name=entry["name"],
            unique_id=entry["unique_id"],
            database=config.get("database", ""),
            schema=config.get("schema", ""),
            alias=entry.get("alias") or entry["name"],
            sql_path=sql_path,
            yaml_path=yaml_path,
        ))
    return models


def _find_yaml_for_model(model_name: str, sql_path: Path) -> Path | None:
    """Fallback YAML lookup when patch_path is missing or stale.

    Walks from the SQL file's directory up toward the dbt project root,
    looking for any *.yml/*.yaml that contains a `name: <model_name>` entry.
    """
    needle = f"name: {model_name}"
    search_dir = sql_path.parent
    for _ in range(8):  # cap walk-up depth
        for pattern in ("*.yml", "*.yaml"):
            for yml in search_dir.glob(pattern):
                try:
                    text = yml.read_text()
                except (OSError, UnicodeDecodeError):
                    continue
                if needle in text:
                    return yml
        if search_dir.parent == search_dir:
            break
        search_dir = search_dir.parent
    return None
