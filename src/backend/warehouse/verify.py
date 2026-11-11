"""Post-load checks, recorded in meta.check_result.

`fail` blocks the build: the load itself is wrong. `info` never blocks: orphan
keys can be planted data-quality issues, which belong to the analysis, not the load.
"""
from __future__ import annotations

import csv
import json
from datetime import date
from pathlib import Path

from .inventory.checks import inventory_checks

# (name, child table, child column, parent key query)
REFERENCES = [
    ("erp.material_id", "erp_purchase_lines_2021_2025", "material_id", "SELECT material_id FROM raw.materials"),
    ("erp.supplier_id", "erp_purchase_lines_2021_2025", "supplier_id",
     "SELECT supplier_id FROM raw.suppliers UNION SELECT farm_id FROM raw.farm_registry"),
    ("parcels.farm_id", "parcels", "farm_id", "SELECT farm_id FROM raw.farm_registry"),
    ("parcels.catchment_id", "parcels", "catchment_id", "SELECT catchment_id FROM raw.catchments"),
    ("crop_history.parcel_id", "parcel_crop_history_and_plan", "parcel_id", "SELECT parcel_id FROM raw.parcels"),
    ("farm_survey.farm_id", "farm_survey_fi", "farm_id", "SELECT farm_id FROM raw.farm_registry"),
    ("foodhills.odlar_id", "foodhills_odlingsdata_se", "odlar_id", "SELECT farm_id FROM raw.farm_registry"),
    ("shipments.ef_id", "shipments", "ef_id", "SELECT ef_id FROM raw.emission_factor_library"),
    ("weather_monthly.cell_id", "weather_monthly_1991_2060", "cell_id", "SELECT cell_id FROM raw.climate_grid_cells"),
]


def same_cell(text: str, value) -> bool:
    """Compare a CSV cell parsed by Python's csv module with the loaded value."""
    if value is None:
        return text == ""
    if isinstance(value, bool):
        return text.lower() == str(value).lower()
    if isinstance(value, int | float):
        return float(text) == float(value)
    if isinstance(value, date):
        return text == value.isoformat()
    return text == value


def compare_csv(con, path: Path, schema: str, table: str) -> tuple[int, int, str]:
    """Return (cells compared, cells differing, first difference)."""
    with path.open(encoding="utf-8-sig", newline="") as handle:
        first_line = handle.readline()
        handle.seek(0)
        delimiter = ";" if first_line.count(";") > first_line.count(",") else ","
        reader = csv.reader(handle, delimiter=delimiter)
        header = next(reader)
        columns = ", ".join(f'"{c}"' for c in header)
        result = con.execute(f'SELECT {columns} FROM {schema}."{table}" ORDER BY _source_row')

        cells = diffs = 0
        first = ""
        for number, row in enumerate(reader, start=1):
            loaded = result.fetchone()
            if loaded is None:
                return cells, diffs + 1, f"table ends before file row {number}"
            for name, text, value in zip(header, row, loaded, strict=True):
                cells += 1
                if not same_cell(text, value):
                    diffs += 1
                    first = first or f"row {number} {name}: file={text!r} db={value!r}"
        if result.fetchone() is not None:
            return cells, diffs + 1, "table has more rows than the file"
    return cells, diffs, first


def run_checks(con, root: Path, manifest: dict[str, str]) -> int:
    """Run every check and return the number of failures."""
    failures = 0

    def record(name, target, ok, expected="", actual="", detail="", status=None):
        nonlocal failures
        status = status or ("pass" if ok else "fail")
        failures += status == "fail"
        if status == "fail":
            print(f"  FAIL {name} {target}: expected {expected}, got {actual} {detail}")
        con.execute("INSERT INTO meta.check_result VALUES (?, ?, ?, ?, ?, ?)",
                    [name, target, status, str(expected), str(actual), detail])

    files = con.execute(
        "SELECT path, format, schema_name, table_name, sha256, manifest_sha256 FROM meta.source_file"
    ).fetchall()
    loaded = {f[0] for f in files}

    for path, _, _, _, digest, expected in files:
        record("sha256_matches_manifest", path, digest == expected, expected, digest)

    in_scope = {p for p in manifest if p.startswith(("data/", "tasks/"))}
    missing = sorted(in_scope - loaded)
    record("all_manifest_files_loaded", "package", not missing, 0, len(missing), ", ".join(missing))

    for path, fmt, schema, table, *_ in files:
        if fmt == "csv":
            cells, diffs, first = compare_csv(con, root / path, schema, table)
            record("csv_cells_match_file", path, diffs == 0, f"{cells} cells equal", f"{diffs} differ", first)

    for path, table, expected in con.execute("""
        SELECT d.source_path, s.table_name, d.expected_rows
        FROM meta.dictionary_table d JOIN meta.source_file s ON s.path = d.source_path
        WHERE d.expected_rows IS NOT NULL
    """).fetchall():
        actual = con.execute(f'SELECT count(*) FROM raw."{table}"').fetchone()[0]
        record("rows_match_dictionary", path, actual == expected, expected, actual)

    undocumented = con.execute("""
        SELECT d.source_path, d.column_name FROM meta.data_dictionary d
        JOIN meta.source_file s ON s.path = d.source_path
        LEFT JOIN duckdb_columns() c ON c.schema_name = s.schema_name
             AND c.table_name = s.table_name AND c.column_name = d.column_name
        WHERE c.column_name IS NULL
    """).fetchall()
    record("dictionary_columns_exist", "package", not undocumented, 0, len(undocumented), str(undocumented[:5]))

    parquet = "data/04_climate/weather_daily_1991_2060.parquet"
    expected = con.execute(
        "SELECT sum(row_group_num_rows) FROM (SELECT DISTINCT row_group_id, row_group_num_rows "
        f"FROM parquet_metadata('{root / parquet}'))"
    ).fetchone()[0]
    actual = con.execute("SELECT count(*) FROM raw.weather_daily_1991_2060").fetchone()[0]
    record("rows_match_parquet_metadata", parquet, actual == expected, expected, actual)

    for name, key in (("parcels", "parcel_id"), ("catchments", "catchment_id")):
        rel = f"data/06_nature/{name}.geojson"
        features = json.loads((root / rel).read_text(encoding="utf-8"))["features"]
        keys = [f["properties"][key] for f in features]
        points = sum(len(ring) for f in features for ring in f["geometry"]["coordinates"])
        db_keys, db_points = zip(*con.execute(
            f'SELECT {key}, ST_NPoints(geom) FROM raw.{name}_geojson ORDER BY _source_row').fetchall())
        record("geojson_features_match_file", rel, keys == list(db_keys), len(keys), len(db_keys))
        record("geojson_vertices_match_file", rel, points == sum(db_points), points, sum(db_points))

    differing = con.execute("""
        SELECT count(*) FROM (
            SELECT parcel_id, farm_id, area_ha, catchment_id FROM raw.parcels
            EXCEPT SELECT parcel_id, farm_id, area_ha, catchment_id FROM raw.parcels_geojson)
    """).fetchone()[0]
    record("parcels_csv_matches_geojson", "raw.parcels", differing == 0, 0, differing)

    for rel, value, period_start in con.execute(
        "SELECT _source_file, pcf_excluding_biogenic, reference_period_start_utc FROM raw.supplier_pcfs"
    ).fetchall():
        pcf = json.loads((root / rel).read_text(encoding="utf-8"))["pcf"]
        actual = (value, period_start.isoformat() + "Z")
        expected = (float(pcf["pCfExcludingBiogenic"]), pcf["referencePeriodStart"])
        record("pcf_matches_file", rel, actual == expected, expected, actual)

    unparsed = con.execute("""
        SELECT count(*) FROM stg.foodhills_growers
        WHERE irrigated IS NULL OR area_ha IS NULL OR delivered_t IS NULL
    """).fetchone()[0]
    record("foodhills_view_parses", "stg.foodhills_growers", unparsed == 0, 0, unparsed)

    for name, table, column, parents in REFERENCES:
        orphans = con.execute(f"""
            SELECT count(*), count(DISTINCT c."{column}") FROM raw."{table}" c
            ANTI JOIN ({parents}) p(key) ON c."{column}" = p.key
            WHERE c."{column}" IS NOT NULL
        """).fetchone()
        record("orphan_keys", name, True, 0, orphans[0], f"{orphans[1]} distinct values",
               status="info")

    inventory_checks(con, root, manifest, record)

    summary = con.execute(
        "SELECT status, count(*) FROM meta.check_result GROUP BY 1 ORDER BY 1").fetchall()
    print("  " + ", ".join(f"{count} {status}" for status, count in summary))
    return failures
