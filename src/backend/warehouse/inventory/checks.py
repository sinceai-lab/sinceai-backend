"""Inventory checks, recorded in meta.check_result alongside the load checks."""
from __future__ import annotations

import hashlib
from pathlib import Path

from . import SQL_DIR

# Dev truths are known exactly, so a line this far off means the pipeline broke.
MAX_DEV_ERROR_PCT = 5
# Market-based electricity is a small remainder after GoOs, so a percentage means little
# there: 3 % on one estimated month is +30 % on the line. 25 t is 0.01 % of the inventory.
MAX_DEV_ERROR_T = 25
# Published figures are a guide, not a truth: the synthetic company tracks them loosely.
SCOPE1_PUBLISHED_TOLERANCE_PCT = 10
FACTORS_PATH = "tools/ccn_tools/factors.py"
# Row counts that must survive the joins from clean tables to inv.contribution.
ROW_COVERAGE = [
    ("erp_lines", """SELECT count(*) FROM clean.erp e JOIN raw.materials m ON m.material_id = e.material_id_clean
                     WHERE NOT e.is_duplicate AND m.default_ef_id <> 'FARM'""",
     "SELECT count(*) FROM inv.contribution WHERE record_key LIKE 'erp:%'"),
    ("fuel_use", "SELECT count(*) FROM inv.fuel_use WHERE year BETWEEN 2021 AND 2025",
     "SELECT count(*) FROM inv.contribution WHERE category = 'stationary_and_mobile_combustion'"),
    ("refrigerants", "SELECT count(*) FROM clean.refrigerant WHERE year BETWEEN 2021 AND 2025",
     "SELECT count(*) FROM inv.contribution WHERE category = 'fugitive_refrigerants'"),
    ("shipments", "SELECT count(*) FROM clean.shipment WHERE year BETWEEN 2021 AND 2025",
     "SELECT count(*) FROM inv.contribution WHERE record_key LIKE 'ship:%'"),
    ("waste", "SELECT count(*) FROM clean.waste WHERE year BETWEEN 2021 AND 2025",
     "SELECT count(*) FROM inv.contribution WHERE record_key LIKE 'waste:%'"),
    ("farm_deliveries", """SELECT sum(qty_kg) FROM clean.erp e JOIN ref.contract_crop c ON c.material_id = e.material_id_clean
                           WHERE NOT e.is_duplicate""",
     "SELECT sum(delivered_kg) FROM inv.farm_crop_year"),
]


def inventory_checks(con, root: Path, manifest: dict[str, str], record) -> None:
    digest = hashlib.sha256((root / FACTORS_PATH).read_bytes()).hexdigest()
    record("sha256_matches_manifest", FACTORS_PATH, digest == manifest.get(FACTORS_PATH), manifest.get(FACTORS_PATH), digest)

    # Rules must not see the labels, or dev accuracy would prove nothing.
    leaks = [p.name for p in SQL_DIR.glob("*.sql")
             if p.name != "50_summary.sql" and "tasks." in p.read_text(encoding="utf-8")]
    record("rules_do_not_read_labels", "inventory/sql", not leaks, 0, len(leaks), ", ".join(leaks))

    for name, source, loaded in ROW_COVERAGE:
        expected = con.execute(source).fetchone()[0]
        actual = con.execute(loaded).fetchone()[0]
        record("no_rows_lost", name, abs(expected - actual) < 1e-6, expected, actual)

    bad = con.execute("SELECT count(*) FROM inv.contribution WHERE tco2e IS NULL OR isnan(tco2e)").fetchone()[0]
    record("contributions_have_values", "inv.contribution", bad == 0, 0, bad)

    untraced = con.execute("""
        SELECT count(*) FROM inv.contribution c
        WHERE c.source_file IS NULL
          AND c.record_key NOT IN (SELECT record_key FROM dq.issue WHERE action = 'estimated')
          AND c.record_key NOT LIKE 'farm:%'
    """).fetchone()[0]
    record("contributions_are_traceable", "inv.contribution", untraced == 0, 0, untraced)

    missing = con.execute("SELECT count(*) FROM inv.a2_submission WHERE tco2e IS NULL").fetchone()[0]
    record("a2_template_complete", "inv.a2_submission", missing == 0, 0, missing)

    for year, scope, category, truth, value, error in con.execute(
        "SELECT year, scope, category, truth_tco2e, tco2e, error_pct FROM inv.validation"
    ).fetchall():
        ok = value is not None and (abs(error) <= MAX_DEV_ERROR_PCT or abs(value - truth) <= MAX_DEV_ERROR_T)
        record("dev_truth_within_tolerance", f"{year}:{scope}:{category}", ok, round(truth, 2), value and round(value, 2))

    for year, published, value, error in con.execute(
        "SELECT year, published_scope1, scope1, error_pct FROM inv.published_comparison"
    ).fetchall():
        ok = abs(error) <= SCOPE1_PUBLISHED_TOLERANCE_PCT
        record("scope1_near_published", str(year), ok, published, round(value, 1))
