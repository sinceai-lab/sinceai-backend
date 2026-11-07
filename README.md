# sinceai-backend

The API. Python + FastAPI. It runs on a laptop and Cloudflare Tunnel makes it public.

- Live: https://api.empanadas.travel
- Check it's up: https://api.empanadas.travel/health
- Frontend repo: [sinceai-frontend](https://github.com/sinceai-lab/sinceai-frontend)

## Run it locally

**1. Create `.env` in this folder:**

```
API_TOKEN=ask-jere-for-this
```

**2. Start it:**

```bash
uv run --env-file .env uvicorn backend.app:app --port 8000 --reload
```

**3. Check it:** open http://localhost:8000/health. You should see `{"status":"ok"}`.

That's it. API docs are at http://localhost:8000/docs.

## Build the database

The Apetit data package loads into a DuckDB file at `data/apetit.duckdb`. It isn't committed, so build it after cloning:

```bash
uv run apetit-warehouse
```

This takes a few seconds. It expects the package next to this repo at `../APETIT_CLIMATE_NATURE_NAVIGATOR_2026`. To use other paths, pass `--source` and `--db`, or set `APETIT_SOURCE_DIR` and `APETIT_DB_PATH`. The first build needs internet access to download DuckDB's spatial extension.

| Schema | What's in it |
|---|---|
| `raw` | One table per source file, **not cleaned**. The planted data errors are still there, on purpose. Also `supplier_pcfs` (all 44 PCF files), `documents` (markdown docs) and `ApetitGroup_sample_data` (the workbook, one row per cell). |
| `stg` | `foodhills_growers`: the Swedish file with English names and real numbers. Format changes only. |
| `tasks` | Dev answer keys, questions and submission templates. Don't give a data-quality agent access to this schema, because it holds the labels. |
| `meta` | `source_file` (hashes), `data_dictionary` (column descriptions), `check_result`, `load_run`. |

Every `raw` table from a data file has `_source_file` and `_source_row` (the data row in the file, starting at 1, not counting the header), so any number can be traced to its record:

```python
import duckdb

con = duckdb.connect("data/apetit.duckdb", read_only=True)
con.sql("""
    SELECT doc_no, line_no, quantity, uom, _source_file, _source_row
    FROM raw.erp_purchase_lines_2021_2025
    WHERE year(posting_date) = 2025
""").show()
```

Good to know:

- Open the file with `read_only=True` from the API. Rebuilding is safe while the API runs, but it keeps reading the old file until it reconnects.
- Run `LOAD spatial` before using `ST_*` functions on `geom`. Coordinates are x = longitude, y = latitude.
- The build compares every CSV cell with the source file and checks hashes against `MANIFEST.json`. If a check fails, the existing database stays in place and the failed build is left at `data/apetit.duckdb.tmp`.
- To load a new file type, add a loader in `src/backend/warehouse/build.py`. The build stops on any file it can't load, so nothing gets skipped silently.
- The database contains Apetit's workbook, which is not CC BY. Don't publish the database file.

## Add a route

Open `src/backend/app.py` and put it on `api`:

```python
@api.get("/things")
def things() -> list[str]:
    return ["empanada"]
```

Routes on `api` start with `/api` and need the token.

## Add a package

```bash
uv add some-package
```

## Put the API online

Only works on Jere's laptop, because the tunnel credentials live there.

Run these in two terminals:

```bash
uv run --env-file .env uvicorn backend.app:app --port 8000
```

```bash
cloudflared tunnel --config tunnel.yml run
```

Keep the laptop awake:

```bash
caffeinate -dis
```

**If either process stops, or the laptop sleeps, the site loses its API.**

## When things break

| Problem | Fix |
|---|---|
| `uv` hangs or fails on a private index | Add `--no-config` right after `uv`, like `uv --no-config run ...` |
| `401` | The token is wrong or missing. Compare your `.env` with the frontend's. |
| `503` | `API_TOKEN` isn't set. Check `.env`. |
| CORS error in the browser | Add your site's address to `ALLOWED_ORIGINS` in `src/backend/app.py`. |
| `api.empanadas.travel` won't load | Check both processes are running, then check the laptop is awake. |

## Don't forget

- Never commit `.env`.
- The token is **not** secret. It's in the frontend's public JavaScript.
- Before adding LLM routes: set a spending cap on the LLM key and add a rate limit.
