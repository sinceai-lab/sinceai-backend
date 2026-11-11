"""Load the participant package into DuckDB.

Layers:
  raw    one table per source file, nothing cleaned. The feeds contain planted
         errors that tasks A1/A2 must find, so they are kept exactly as delivered.
         Every row carries _source_file and _source_row (1-based data row).
  stg    format-only views (no corrections).
  tasks  dev answer keys, questions and submission templates, kept apart from
         raw so a data-quality agent can be pointed at raw without seeing labels.
  meta   load runs, file hashes, data dictionary and check results.

The build writes to a temp file and only replaces the live database if every
check passes, so a failed run never leaves a broken or half-built database.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import uuid
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath

import duckdb
import openpyxl

from .inventory import build_inventory
from .verify import run_checks

SOURCE_DIRS = ("data", "tasks")
EXTRA_DOCUMENTS = ("START_HERE.md",)
IGNORED_FILES = {".DS_Store"}

# Numeric-looking identifiers: they must stay text to match shipments.ref_doc
# and the erp:{doc_no}:{line_no} record keys.
CSV_TYPES = {
    "erp_purchase_lines_2021_2025": {"doc_no": "VARCHAR", "reference_doc": "VARCHAR"},
}
CSV_DELIMITERS = {"foodhills_odlingsdata_se": ";"}

META_DDL = """
CREATE SCHEMA raw; CREATE SCHEMA stg; CREATE SCHEMA tasks; CREATE SCHEMA meta;
CREATE TABLE meta.load_run (
    run_id VARCHAR, package VARCHAR, package_version VARCHAR, duckdb_version VARCHAR,
    source_root VARCHAR, started_at_utc TIMESTAMP, finished_at_utc TIMESTAMP);
CREATE TABLE meta.source_file (
    path VARCHAR PRIMARY KEY, format VARCHAR, schema_name VARCHAR, table_name VARCHAR,
    bytes BIGINT, sha256 VARCHAR, manifest_sha256 VARCHAR, rows_loaded BIGINT);
CREATE TABLE meta.data_dictionary (
    source_path VARCHAR, column_name VARCHAR, dictionary_type VARCHAR,
    example VARCHAR, description VARCHAR);
CREATE TABLE meta.dictionary_table (
    source_path VARCHAR PRIMARY KEY, description VARCHAR, expected_rows BIGINT);
CREATE TABLE meta.check_result (
    check_name VARCHAR, target VARCHAR, status VARCHAR,
    expected VARCHAR, actual VARCHAR, detail VARCHAR);
"""


def lit(value: str | Path) -> str:
    """Quote a value as a SQL string literal."""
    return "'" + str(value).replace("'", "''") + "'"


def utc_now() -> datetime:
    return datetime.now(UTC).replace(tzinfo=None)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def target_table(rel: str) -> tuple[str, str]:
    path = PurePosixPath(rel)
    stem = path.stem.lower() if rel.startswith("tasks/") else path.stem
    if rel.startswith("tasks/templates/"):
        return "tasks", f"template_{stem}"
    if rel.startswith("tasks/"):
        return "tasks", stem
    if path.suffix == ".geojson":
        return "raw", f"{stem}_geojson"
    return "raw", stem


def register(con, root: Path, rel: str, fmt: str, schema: str, table: str, rows: int, manifest: dict) -> None:
    path = root / rel
    con.execute(
        "INSERT INTO meta.source_file VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [rel, fmt, schema, table, path.stat().st_size, sha256(path), manifest.get(rel), rows],
    )


def row_count(con, schema: str, table: str) -> int:
    return con.execute(f'SELECT count(*) FROM {schema}."{table}"').fetchone()[0]


def load_csv(con, root: Path, rel: str, schema: str, table: str) -> None:
    options = ["sample_size=-1"]
    if table in CSV_TYPES:
        pairs = ", ".join(f"{lit(c)}: {lit(t)}" for c, t in CSV_TYPES[table].items())
        options.append(f"types={{{pairs}}}")
    if table in CSV_DELIMITERS:
        options.append(f"delim={lit(CSV_DELIMITERS[table])}")
    con.execute(f"""
        CREATE TABLE {schema}."{table}" AS
        SELECT *, {lit(rel)} AS _source_file, row_number() OVER () AS _source_row
        FROM read_csv({lit(root / rel)}, {', '.join(options)})
    """)


def load_parquet(con, root: Path, rel: str, schema: str, table: str) -> None:
    con.execute(f"""
        CREATE TABLE {schema}."{table}" AS
        SELECT * EXCLUDE (file_row_number), {lit(rel)} AS _source_file,
               file_row_number + 1 AS _source_row
        FROM read_parquet({lit(root / rel)}, file_row_number=true)
    """)


def load_geojson(con, root: Path, rel: str, schema: str, table: str) -> None:
    con.execute(f"""
        CREATE TABLE {schema}."{table}" AS
        SELECT *, {lit(rel)} AS _source_file, row_number() OVER () AS _source_row
        FROM ST_Read({lit(root / rel)})
    """)


def load_workbook(con, root: Path, rel: str, schema: str, table: str) -> None:
    """The sheets are free-form report layouts, so they load as a long cell table."""
    values = openpyxl.load_workbook(root / rel, data_only=True)
    formulas = openpyxl.load_workbook(root / rel, data_only=False)
    con.execute(f"""
        CREATE TABLE {schema}."{table}" (
            sheet VARCHAR, cell VARCHAR, row_no INTEGER, col_no INTEGER,
            value_text VARCHAR, value_num DOUBLE, formula VARCHAR, _source_file VARCHAR)
    """)
    rows = []
    for sheet in formulas:
        for line in sheet.iter_rows():
            for cell in line:
                if cell.value is None:
                    continue
                value = values[sheet.title][cell.coordinate].value
                is_number = isinstance(value, int | float) and not isinstance(value, bool)
                formula = cell.value if cell.data_type == "f" else None
                rows.append((sheet.title, cell.coordinate, cell.row, cell.column,
                             None if value is None else str(value),
                             float(value) if is_number else None, formula, rel))
    con.executemany(f'INSERT INTO {schema}."{table}" VALUES (?, ?, ?, ?, ?, ?, ?, ?)', rows)


def load_supplier_pcfs(con, root: Path, rels: list[str]) -> None:
    """One row per PACT file. Headline fields are columns; doc keeps the whole file."""
    prefix = str(root) + "/"
    files = ", ".join(lit(root / rel) for rel in rels)
    pcf = "(doc->>'$.pcf.{}')"
    con.execute(f"""
        CREATE TABLE raw.supplier_pcfs AS
        WITH src AS (
            SELECT replace(filename, {lit(prefix)}, '') AS _source_file,
                   parse_filename(filename, true) AS stem, content::JSON AS doc
            FROM read_text([{files}])
        )
        SELECT split_part(stem, '_', 1) AS supplier_id,
               split_part(stem, '_', 2) AS material_id,
               split_part(stem, '_', 3)::INTEGER AS year,
               doc->>'$.id' AS pcf_id,
               doc->>'$.status' AS status,
               (doc->>'$.created')::TIMESTAMP AS created_utc,
               doc->>'$.productDescription' AS product_description,
               {pcf.format('declaredUnit')} AS declared_unit,
               {pcf.format('unitaryProductAmount')}::DOUBLE AS unitary_product_amount,
               {pcf.format('pCfExcludingBiogenic')}::DOUBLE AS pcf_excluding_biogenic,
               {pcf.format('pCfIncludingBiogenic')}::DOUBLE AS pcf_including_biogenic,
               {pcf.format('fossilGhgEmissions')}::DOUBLE AS fossil_ghg_emissions,
               {pcf.format('dLucGhgEmissions')}::DOUBLE AS dluc_ghg_emissions,
               {pcf.format('landManagementGhgEmissions')}::DOUBLE AS land_management_ghg_emissions,
               {pcf.format('referencePeriodStart')}::TIMESTAMP AS reference_period_start_utc,
               {pcf.format('referencePeriodEnd')}::TIMESTAMP AS reference_period_end_utc,
               {pcf.format('geographyCountry')} AS geography_country,
               {pcf.format('primaryDataShare')}::DOUBLE AS primary_data_share,
               doc,
               _source_file,
               1 AS _source_row
        FROM src ORDER BY _source_file
    """)


def load_documents(con, root: Path, rels: list[str]) -> None:
    prefix = str(root) + "/"
    files = ", ".join(lit(root / rel) for rel in rels)
    con.execute(f"""
        CREATE TABLE raw.documents AS
        SELECT replace(filename, {lit(prefix)}, '') AS path, content
        FROM read_text([{files}]) ORDER BY path
    """)


def load_data_dictionary(con, root: Path) -> None:
    """Parse DATA_DICTIONARY.md so column meanings are queryable next to the data."""
    text = (root / "docs/DATA_DICTIONARY.md").read_text(encoding="utf-8")
    sections = re.split(r"^## `([^`]+)`\s*$", text, flags=re.M)[1:]
    for name, body in zip(sections[::2], sections[1::2]):
        path = f"data/{name}"
        rows = re.search(r"^Rows: ([\d,]+)", body, flags=re.M)
        description = body.strip().split("\n", 1)[0]
        con.execute("INSERT INTO meta.dictionary_table VALUES (?, ?, ?)",
                    [path, description, int(rows.group(1).replace(",", "")) if rows else None])
        for line in body.splitlines():
            match = re.match(r"\| `([^`]+)` \| (.*?) \| (.*?) \| (.*) \|$", line)
            if match:
                con.execute("INSERT INTO meta.data_dictionary VALUES (?, ?, ?, ?, ?)",
                            [path, *match.groups()])


def create_staging(con) -> None:
    """Foodhills ships with Swedish headers and decimal commas; this is format only."""
    con.execute("""
        CREATE VIEW stg.foodhills_growers AS
        SELECT odlar_id AS farm_id,
               "skördeår" AS year,
               "gröda" AS crop_sv,
               replace(areal_ha, ',', '.')::DOUBLE AS area_ha,
               replace("levererad_mängd_ton", ',', '.')::DOUBLE AS delivered_t,
               "kvävegiva_kg_ha" AS n_kg_ha,
               diesel_l_ha,
               CASE bevattnad WHEN 'ja' THEN true WHEN 'nej' THEN false END AS irrigated,
               _source_file, _source_row
        FROM raw.foodhills_odlingsdata_se
    """)


def source_files(root: Path) -> list[str]:
    found = []
    for folder in SOURCE_DIRS:
        for path in sorted((root / folder).rglob("*")):
            if path.is_file() and path.name not in IGNORED_FILES:
                found.append(path.relative_to(root).as_posix())
    return found


def load_all(con, root: Path, manifest: dict[str, str]) -> None:
    loaders = {".csv": ("csv", load_csv), ".parquet": ("parquet", load_parquet),
               ".geojson": ("geojson", load_geojson), ".xlsx": ("xlsx", load_workbook)}
    pcfs, documents = [], [*EXTRA_DOCUMENTS]
    documents += sorted(p.relative_to(root).as_posix() for p in (root / "docs").glob("*.md"))

    for rel in source_files(root):
        suffix = PurePosixPath(rel).suffix
        if suffix == ".json" and "/supplier_pcfs/" in rel:
            pcfs.append(rel)
        elif suffix == ".md":
            documents.append(rel)
        elif suffix in loaders:
            fmt, loader = loaders[suffix]
            schema, table = target_table(rel)
            loader(con, root, rel, schema, table)
            register(con, root, rel, fmt, schema, table, row_count(con, schema, table), manifest)
            print(f"  {schema}.{table}: {row_count(con, schema, table):,} rows")
        else:
            raise ValueError(f"No loader for {rel}. Add one so the file is not silently skipped.")

    load_supplier_pcfs(con, root, pcfs)
    load_documents(con, root, documents)
    for rel in pcfs:
        register(con, root, rel, "json", "raw", "supplier_pcfs", 1, manifest)
    for rel in documents:
        register(con, root, rel, "md", "raw", "documents", 1, manifest)
    print(f"  raw.supplier_pcfs: {len(pcfs)} rows")
    print(f"  raw.documents: {len(documents)} rows")


def build(root: Path, db_path: Path) -> bool:
    """Build the database. Returns True if it passed its checks and went live."""
    started = utc_now()
    package = json.loads((root / "MANIFEST.json").read_text(encoding="utf-8"))
    manifest = {f["path"]: f["sha256"] for f in package["files"]}

    db_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = db_path.with_name(db_path.name + ".tmp")
    tmp.unlink(missing_ok=True)

    # One thread keeps read_csv in file order, which makes _source_row exact.
    con = duckdb.connect(tmp, config={"threads": 1})
    try:
        con.execute("INSTALL spatial; LOAD spatial;")
        con.execute(META_DDL)
        print(f"Loading {root}")
        load_all(con, root, manifest)
        load_data_dictionary(con, root)
        create_staging(con)
        build_inventory(con, root)

        print("Checking")
        failures = run_checks(con, root, manifest)
        con.execute(
            "INSERT INTO meta.load_run VALUES (?, ?, ?, ?, ?, ?, ?)",
            [str(uuid.uuid4()), package["package"], package["version"], duckdb.__version__,
             str(root), started, utc_now()],
        )
        if not failures:
            submission = db_path.with_name("A2_inventory_2025_submission.csv")
            con.execute(f"COPY (SELECT * FROM inv.a2_submission) TO {lit(submission)} (HEADER)")
    finally:
        con.close()

    if failures:
        print(f"FAILED: {failures} check(s) failed. Live database left unchanged; "
              f"inspect meta.check_result in {tmp}")
        return False
    os.replace(tmp, db_path)
    print(f"Built {db_path} ({db_path.stat().st_size / 1e6:.0f} MB)")
    return True
