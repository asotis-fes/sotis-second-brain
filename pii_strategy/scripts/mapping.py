"""Snowflake SYSTEM$CLASSIFY semantic_category -> FES (classification, pii_category).

Decision reference: D8 in pii_strategy/02_decisions.md.
Catalog reference: pii_strategy/03_classification_catalog.md.

Two override cases where the FAN Data Classification Catalog is stricter than
Snowflake's default classifier:

1. DATE_OF_BIRTH: Snowflake says QUASI_IDENTIFIER. FAN says Customer DOB is
   Critical. We override to critical.

2. CITY / ADMINISTRATIVE_AREA_1 / COUNTRY / POSTAL_CODE individually:
   Snowflake says QUASI_IDENTIFIER. FAN's "partial address" rule classifies
   any combination of street/city/state/zip without house number as Highly
   Confidential. Each fragment alone is treated as address_partial -> HC.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class ClassificationMapping:
    classification: str  # critical | highly_confidential
    pii_category: str
    note: str = ""


SEMANTIC_TO_FES = {
    # Critical
    "EMAIL":          ClassificationMapping("critical", "email"),
    "NAME":           ClassificationMapping("critical", "name"),
    "PHONE_NUMBER":   ClassificationMapping("critical", "phone"),
    "STREET_ADDRESS": ClassificationMapping("critical", "address"),
    "DATE_OF_BIRTH":  ClassificationMapping(
        "critical", "dob",
        note="FAN-override: Snowflake says QUASI_IDENTIFIER; FAN catalog says DOB is Critical."
    ),

    # Highly Confidential — partial address fragments (FAN override)
    "CITY":                  ClassificationMapping(
        "highly_confidential", "address_partial",
        note="FAN-override: partial address fragment."
    ),
    "ADMINISTRATIVE_AREA_1": ClassificationMapping(
        "highly_confidential", "address_partial",
        note="FAN-override: state field, partial address fragment."
    ),
    "COUNTRY":               ClassificationMapping(
        "highly_confidential", "address_partial",
        note="FAN-override: partial address fragment."
    ),
    "POSTAL_CODE":           ClassificationMapping(
        "highly_confidential", "address_partial",
        note="FAN-override: zip alone, partial address fragment."
    ),

    # Highly Confidential — demographics / financial
    "AGE":    ClassificationMapping(
        "highly_confidential", "age",
        note="Not in FAN catalog explicitly; conservative bucket."
    ),
    "GENDER": ClassificationMapping(
        "highly_confidential", "gender",
        note="Not in FAN catalog explicitly; conservative bucket."
    ),
    "SALARY": ClassificationMapping(
        "highly_confidential", "salary",
        note=("FAN: Employee Salary = HC. Note: AAIA_INCOME_* columns in fangraph "
              "are census-derived income (not employee salary) — engineer should review.")
    ),
}


def map_semantic_category(semantic_category: str) -> ClassificationMapping | None:
    """Return the FES mapping for a Snowflake semantic_category, or None if unmapped."""
    return SEMANTIC_TO_FES.get(semantic_category.upper())
