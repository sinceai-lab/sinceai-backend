"""Build the warehouse: `uv run apetit-warehouse`."""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from .build import build

BACKEND_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_SOURCE = BACKEND_ROOT.parent / "APETIT_CLIMATE_NATURE_NAVIGATOR_2026"
DEFAULT_DB = BACKEND_ROOT / "data" / "apetit.duckdb"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=os.environ.get("APETIT_SOURCE_DIR", DEFAULT_SOURCE),
                        help="unzipped package folder (env: APETIT_SOURCE_DIR)")
    parser.add_argument("--db", type=Path, default=os.environ.get("APETIT_DB_PATH", DEFAULT_DB),
                        help="database file to write (env: APETIT_DB_PATH)")
    args = parser.parse_args()
    sys.exit(0 if build(Path(args.source).resolve(), Path(args.db).resolve()) else 1)


if __name__ == "__main__":
    main()
