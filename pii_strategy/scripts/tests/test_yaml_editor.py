"""Round-trip YAML editor tests."""

import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

from yaml_editor import apply_tags_to_yaml, TagUpdate  # noqa: E402


def _write_tmp(content: str) -> Path:
    f = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
    f.write(textwrap.dedent(content))
    f.close()
    return Path(f.name)


class TestYamlEditor(unittest.TestCase):

    def test_adds_new_column_entry(self):
        yaml_path = _write_tmp("""\
            version: 2
            models:
              - name: dim_customer
                columns:
                  - name: customer_id
                    tests:
                      - unique
        """)
        results, new_text = apply_tags_to_yaml(
            yaml_path,
            "dim_customer",
            [TagUpdate("email", "critical", "email", "HIGH", "EMAIL")],
            run_date="2026-06-10",
        )
        self.assertEqual(results[0].action, "added")
        self.assertIn("email", new_text)
        self.assertIn("classification: critical", new_text)
        self.assertIn("pii_category: email", new_text)
        self.assertIn("auto-tagged 2026-06-10", new_text)

    def test_updates_existing_column(self):
        yaml_path = _write_tmp("""\
            version: 2
            models:
              - name: dim_customer
                columns:
                  - name: email
                    description: customer email
        """)
        results, new_text = apply_tags_to_yaml(
            yaml_path,
            "dim_customer",
            [TagUpdate("email", "critical", "email", "HIGH", "EMAIL")],
            run_date="2026-06-10",
        )
        self.assertEqual(results[0].action, "added")  # had no classification before
        self.assertIn("classification: critical", new_text)
        self.assertIn("description: customer email", new_text)  # preserved

    def test_skips_existing_classification_without_force(self):
        yaml_path = _write_tmp("""\
            version: 2
            models:
              - name: dim_customer
                columns:
                  - name: email
                    meta:
                      classification: highly_confidential
                      pii_category: ip_address
        """)
        results, new_text = apply_tags_to_yaml(
            yaml_path,
            "dim_customer",
            [TagUpdate("email", "critical", "email", "HIGH", "EMAIL")],
            run_date="2026-06-10",
        )
        self.assertEqual(results[0].action, "skipped-existing")
        # Unchanged
        self.assertIn("classification: highly_confidential", new_text)
        self.assertIn("pii_category: ip_address", new_text)

    def test_force_overwrites_existing(self):
        yaml_path = _write_tmp("""\
            version: 2
            models:
              - name: dim_customer
                columns:
                  - name: email
                    meta:
                      classification: highly_confidential
                      pii_category: ip_address
        """)
        results, new_text = apply_tags_to_yaml(
            yaml_path,
            "dim_customer",
            [TagUpdate("email", "critical", "email", "HIGH", "EMAIL")],
            force=True,
            run_date="2026-06-10",
        )
        self.assertEqual(results[0].action, "updated")
        self.assertIn("classification: critical", new_text)
        self.assertIn("pii_category: email", new_text)

    def test_skips_when_model_not_found(self):
        yaml_path = _write_tmp("""\
            version: 2
            models:
              - name: dim_customer
                columns:
                  - name: customer_id
        """)
        results, _ = apply_tags_to_yaml(
            yaml_path,
            "missing_model",
            [TagUpdate("email", "critical", "email", "HIGH", "EMAIL")],
            run_date="2026-06-10",
        )
        self.assertEqual(results[0].action, "skipped-no-model")

    def test_preserves_comments(self):
        yaml_path = _write_tmp("""\
            # top-level comment
            version: 2
            models:
              # model section
              - name: dim_customer
                description: my dim
                columns:
                  - name: customer_id
                    # this column is the PK
                    tests:
                      - unique
        """)
        _, new_text = apply_tags_to_yaml(
            yaml_path,
            "dim_customer",
            [TagUpdate("email", "critical", "email", "HIGH", "EMAIL")],
            run_date="2026-06-10",
        )
        self.assertIn("# top-level comment", new_text)
        self.assertIn("# model section", new_text)
        self.assertIn("# this column is the PK", new_text)

    def test_dry_run_does_not_write(self):
        yaml_path = _write_tmp("""\
            version: 2
            models:
              - name: dim_customer
                columns:
                  - name: customer_id
        """)
        original = yaml_path.read_text()
        results, new_text = apply_tags_to_yaml(
            yaml_path,
            "dim_customer",
            [TagUpdate("email", "critical", "email", "HIGH", "EMAIL")],
            run_date="2026-06-10",
            dry_run=True,
        )
        self.assertEqual(results[0].action, "added")
        # File on disk is unchanged
        self.assertEqual(yaml_path.read_text(), original)
        # But the returned new_text reflects the would-be content
        self.assertIn("classification: critical", new_text)


if __name__ == "__main__":
    unittest.main()
