"""GHG inventory built on the raw layer: repair the feeds, then calculate.

Schemas:
  ref    method constants, parsed from the package's factors.py
  clean  raw records with raw and corrected values side by side
  dq     dq.issue: one row per detected data-quality issue
  inv    inv.contribution: one row per source record and emission line.
         Every total is an aggregate of that table, so each number can be
         followed back to its records, factors and corrections.

Detection rules never read the tasks schema. Dev labels and dev inventories are
used only afterwards, to measure the result (inv.validation).
"""
from __future__ import annotations

from pathlib import Path

from .constants import load_constants

SQL_DIR = Path(__file__).parent / "sql"


def build_inventory(con, root: Path) -> None:
    load_constants(con, root / "tools/ccn_tools/factors.py")
    for path in sorted(SQL_DIR.glob("*.sql")):
        con.execute(path.read_text(encoding="utf-8"))
