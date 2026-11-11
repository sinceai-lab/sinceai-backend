import os
import secrets

import httpx
from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

ALLOWED_ORIGINS = [
    "https://app.empanadas.travel",
    "http://localhost:3000",
]
INFERENCE_URL = os.environ.get("INFERENCE_URL", "http://127.0.0.1:8600").rstrip("/")
INFERENCE_TIMEOUT = httpx.Timeout(5.0, connect=2.0)


def require_token(authorization: str | None = Header(default=None)) -> None:
    """Reject requests without the shared token. Fails closed if it isn't configured."""
    expected = os.environ.get("API_TOKEN")
    if not expected:
        raise HTTPException(status_code=503, detail="API_TOKEN is not configured")
    if not authorization or not secrets.compare_digest(
        authorization.encode(), f"Bearer {expected}".encode()
    ):
        raise HTTPException(status_code=401, detail="Invalid or missing token")


app = FastAPI(title="sinceai-backend")
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["*"],
    allow_headers=["Authorization", "Content-Type"],
)

api = APIRouter(prefix="/api", dependencies=[Depends(require_token)])


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@api.api_route("/hello", methods=["GET", "PUT"])
def hello() -> dict[str, str]:
    return {"message": "Hello, world!"}


@api.get("/hello/{name}")
def hello_name(name: str) -> dict[str, str]:
    return {"message": f"Hello, {name}!"}


def inference_get(path: str, params: dict | None = None) -> dict:
    """GET a fixed path on the inference service; maps failures to 503 or the upstream status."""
    try:
        r = httpx.get(f"{INFERENCE_URL}{path}", params=params, timeout=INFERENCE_TIMEOUT)
    except httpx.HTTPError:
        raise HTTPException(status_code=503, detail="inference service unavailable")
    if r.status_code >= 400:
        raise HTTPException(status_code=r.status_code, detail=f"inference service returned {r.status_code}")
    try:
        return r.json()
    except ValueError:
        raise HTTPException(status_code=502, detail="inference service returned invalid JSON")


@api.get("/live/predictions")
def live_predictions(
    cell_id: str | None = None,
    parcel_id: str | None = None,
    farm_id: str | None = None,
    crop: str | None = None,
    year: int | None = None,
    latest: bool = True,
    limit: int | None = Query(default=None, ge=1, le=100000),
) -> dict:
    params = {"cell_id": cell_id, "parcel_id": parcel_id, "farm_id": farm_id, "crop": crop, "year": year, "limit": limit}
    params = {k: v for k, v in params.items() if v is not None}
    params["latest"] = str(latest).lower()
    return inference_get("/predictions", params)


@api.get("/live/health")
def live_health() -> dict:
    h = inference_get("/health")
    if not isinstance(h, dict):
        raise HTTPException(status_code=502, detail="inference service returned invalid JSON")
    models, wb = h.get("models") or {}, h.get("writeback") or {}
    return {
        "status": h.get("status"),
        "started_at": h.get("started_at"),
        "models": {"version": models.get("version"), "crops": models.get("crops")},
        "counters": h.get("counters"),
        "last_notification": h.get("last_notification"),
        # last_error can embed the broker URL, so only expose whether one exists
        "writeback": {
            "enabled": wb.get("enabled"),
            "pending": wb.get("pending"),
            "has_error": bool(wb.get("last_error")),
        },
    }


app.include_router(api)
