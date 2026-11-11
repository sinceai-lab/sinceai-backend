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
- Open it read-only in DBeaver too. A read-write connection locks the file, and every other process then fails to open it, even read-only. After a rebuild, reconnect to see the new data.
- Run `LOAD spatial` before using `ST_*` functions on `geom`. Coordinates are x = longitude, y = latitude.
- The build compares every CSV cell with the source file and checks hashes against `MANIFEST.json`. If a check fails, the existing database stays in place and the failed build is left at `data/apetit.duckdb.tmp`.
- To load a new file type, add a loader in `src/backend/warehouse/build.py`. The build stops on any file it can't load, so nothing gets skipped silently.
- The database contains Apetit's workbook, which is not CC BY. Don't publish the database file.

## The GHG inventory

The same build calculates the inventory for 2021–2025 and writes `data/A2_inventory_2025_submission.csv`. The method is the package's `docs/METHODOLOGY.md`.

| Schema | What's in it |
|---|---|
| `ref` | Method constants, parsed from the package's `factors.py`. |
| `clean` | Raw records with raw and corrected values side by side. |
| `dq` | `dq.issue`: every detected problem, with its rule, old and new value, and `review_status`. |
| `inv` | `inv.contribution`: one row per source record and emission line. `inv.summary` is the inventory, `inv.farm_crop_year` is the farm footprints, and `inv.validation` compares results with the dev truths. |

Every total is a sum of `inv.contribution`, so any number can be followed to its records, factors and corrections:

```sql
SELECT c.record_key, c.activity, c.activity_unit, c.factor_ref, c.tco2e,
       c.source_file, c.source_row, i.rule_id, i.observed, i.applied
FROM inv.contribution c
LEFT JOIN dq.issue i USING (record_key)
WHERE c.year = 2025 AND c.category = 'fugitive_refrigerants'
ORDER BY c.tco2e DESC;
```

Good to know:

- Everything is a **draft until an expert approves it**. `dq.issue.review_status` starts as `pending`, and nothing updates it yet.
- Rows with `action = 'estimated'` are judgement calls, not arithmetic. Review those first.
- To change a rule, edit `src/backend/warehouse/inventory/sql/`. The `clean` table holds the logic and `dq.issue` is derived from it.
- Rules must never read the `tasks` schema, or dev accuracy proves nothing. A check enforces this.
- A build fails if a line drifts from the 2023–2024 truths (over 5 % and 25 t), if Scope 1 is over 10 % from the published figure, or if records go missing on the way to `inv.contribution`.
- Organic soil is the main estimate. The parcel rule in `30_farm.sql` was chosen by looking at the 2023–2024 results, so those years flatter it.
- Commuting at Bjuv follows the method (survey mean x year-end headcount), which counts a full year for a site in scope for one month. It's about 11 t too high.

## Add a route

Open `src/backend/app.py` and put it on `api`:

```python
@api.get("/things")
def things() -> list[str]:
    return ["empanada"]
```

Routes on `api` start with `/api` and need the token.

## Live predictions

Two read-only `/api` routes relay the model-inference service. Point at it with `INFERENCE_URL` in `.env` (default `http://127.0.0.1:8600`).

| Route | What it does |
|---|---|
| `GET /api/live/predictions` | Passes `cell_id`, `parcel_id`, `farm_id`, `crop`, `year`, `latest` (default `true`) and `limit` to the service's `/predictions` and returns its JSON as is. |
| `GET /api/live/health` | The service's `/health`, without file paths or URLs. |

If the service is down, both return `503` with `{"detail": "inference service unavailable"}`. Upstream errors keep their status code.

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
