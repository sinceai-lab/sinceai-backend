import os
import secrets

from fastapi import APIRouter, Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware

ALLOWED_ORIGINS = [
    "https://app.empanadas.travel",
    "http://localhost:3000",
]


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


app.include_router(api)
