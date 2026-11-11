"""Lock the FAN-override cases and the standard mappings in tests."""

import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

from mapping import map_semantic_category, SEMANTIC_TO_FES  # noqa: E402


class TestMapping(unittest.TestCase):

    def test_email_is_critical(self):
        m = map_semantic_category("EMAIL")
        self.assertEqual(m.classification, "critical")
        self.assertEqual(m.pii_category, "email")

    def test_dob_override_to_critical(self):
        """FAN override: Snowflake says QUASI; FAN says Critical."""
        m = map_semantic_category("DATE_OF_BIRTH")
        self.assertEqual(m.classification, "critical")
        self.assertEqual(m.pii_category, "dob")
        self.assertIn("FAN-override", m.note)

    def test_city_override_to_partial_address_hc(self):
        """FAN override: partial address fragments are HC."""
        m = map_semantic_category("CITY")
        self.assertEqual(m.classification, "highly_confidential")
        self.assertEqual(m.pii_category, "address_partial")

    def test_state_country_zip_all_partial_address(self):
        """All four partial-address fragments map to the same (HC, address_partial)."""
        for cat in ("CITY", "ADMINISTRATIVE_AREA_1", "COUNTRY", "POSTAL_CODE"):
            m = map_semantic_category(cat)
            self.assertEqual(m.classification, "highly_confidential", cat)
            self.assertEqual(m.pii_category, "address_partial", cat)

    def test_street_address_stays_critical(self):
        """Full street address (with house number) stays Critical, NOT partial."""
        m = map_semantic_category("STREET_ADDRESS")
        self.assertEqual(m.classification, "critical")
        self.assertEqual(m.pii_category, "address")

    def test_age_and_gender_hc(self):
        for cat in ("AGE", "GENDER"):
            m = map_semantic_category(cat)
            self.assertEqual(m.classification, "highly_confidential", cat)

    def test_unknown_category_returns_none(self):
        self.assertIsNone(map_semantic_category("MYSTERY_TYPE"))

    def test_case_insensitive(self):
        self.assertIsNotNone(map_semantic_category("email"))
        self.assertIsNotNone(map_semantic_category("Email"))

    def test_all_mappings_have_valid_classification(self):
        for cat, mapping in SEMANTIC_TO_FES.items():
            self.assertIn(mapping.classification, ("critical", "highly_confidential"), cat)
            self.assertTrue(mapping.pii_category, cat)


if __name__ == "__main__":
    unittest.main()
