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
