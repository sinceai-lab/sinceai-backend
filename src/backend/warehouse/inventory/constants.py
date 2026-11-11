"""Load method constants from the package's factors.py into the ref schema.

The file is parsed, not imported or retyped: its values stay the single source
of truth, there is nothing to mistype, and no package code is executed.
"""
from __future__ import annotations

import ast
from pathlib import Path

# factors.py builds MARKET_GRID with a comprehension, so this one value can't be
# read as a literal. Other markets reuse the national grid factors.
EXPORT_EU_GRID_T_PER_MWH = 0.230

NCV_KEYS = {"lng": ("lng_t", "t"), "lpg": ("lpg_t", "t"),
            "light_fuel_oil": ("lfo_l", "l"), "diesel": ("diesel_l", "l")}


def read_literals(path: Path) -> dict:
    values = {}
    for node in ast.parse(path.read_text(encoding="utf-8")).body:
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            try:
                values[node.targets[0].id] = ast.literal_eval(node.value)
            except ValueError:
                continue
    return values


def insert(con, table: str, columns: str, rows: list[tuple]) -> None:
    con.execute(f"CREATE TABLE ref.{table} ({columns})")
    marks = ", ".join("?" * len(rows[0]))
    con.executemany(f"INSERT INTO ref.{table} VALUES ({marks})", rows)


def load_constants(con, path: Path) -> None:
    c = read_literals(path)
    con.execute("CREATE SCHEMA ref; CREATE SCHEMA clean; CREATE SCHEMA dq; CREATE SCHEMA inv;")

    years = sorted(c["GRID_FI_LB"])
    insert(con, "electricity_factor", "country VARCHAR, year INTEGER, location_t_per_mwh DOUBLE, residual_t_per_mwh DOUBLE",
           [("FI", y, c["GRID_FI_LB"][y], c["RESIDUAL_FI"][y]) for y in years]
           + [("SE", y, c["GRID_SE_LB"][y], c["RESIDUAL_SE"][y]) for y in years])
    insert(con, "market_grid", "market VARCHAR, year INTEGER, t_per_mwh DOUBLE",
           [("FI", y, c["GRID_FI_LB"][y]) for y in years]
           + [("SE", y, c["GRID_SE_LB"][y]) for y in years]
           + [("EXPORT_EU", y, EXPORT_EU_GRID_T_PER_MWH) for y in years])
    insert(con, "heat_location_factor", "year INTEGER, t_per_mwh DOUBLE", list(c["HEAT_LB_EF"].items()))
    insert(con, "fuel", "carrier VARCHAR, fossil_t_per_mwh DOUBLE, biogenic_t_per_mwh DOUBLE, wtt_ef_id VARCHAR",
           [(k, v, c["FUEL_BIOGENIC_T_PER_MWH"].get(k, 0.0), c["FUEL_WTT"].get(k))
            for k, v in c["FUEL_EF_T_PER_MWH"].items()])
    insert(con, "ncv", "carrier VARCHAR, unit VARCHAR, mwh_per_unit DOUBLE",
           [(k, unit, c["NCV"][key]) for k, (key, unit) in NCV_KEYS.items()])
    insert(con, "refrigerant_gwp", "refrigerant VARCHAR, gwp DOUBLE", list(c["REFRIGERANT_GWP"].items()))
    insert(con, "fx", "currency VARCHAR, per_eur DOUBLE", list(c["FX_PER_EUR"].items()))
    insert(con, "crop", "crop VARCHAR, residue_n_per_t DOUBLE, kwh_per_t DOUBLE",
           [(k, c["RESIDUE_N_PER_T"][k], v["kwh_t"]) for k, v in c["MGMT_NORMS"].items()])
    insert(con, "product_group", "product_group VARCHAR, use_kwh_per_kg DOUBLE, plastic_kg_per_t DOUBLE, board_kg_per_t DOUBLE",
           [(k, v, *c["PACK_KG_PER_T"][k]) for k, v in c["USE_PHASE_KWH_PER_KG"].items()])
    insert(con, "scalar", "name VARCHAR, value DOUBLE",
           [*c["FARM_EF"].items(), ("eol_plastic_t_per_t", c["EOL_PLASTIC_EF_T"]),
            ("eol_board_t_per_t", c["EOL_BOARD_EF_T"])])
    con.execute("CREATE MACRO k(n) AS (SELECT value FROM ref.scalar WHERE name = n)")
    con.execute("""
        CREATE MACRO ef(id) AS (SELECT kgco2e_per_unit FROM raw.emission_factor_library WHERE ef_id = id)
    """)
