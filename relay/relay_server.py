from __future__ import annotations

import asyncio
import logging
import os
import secrets
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

PAIR_CODE_TTL_SECONDS = int(os.getenv("PAIR_CODE_TTL_SECONDS", "300"))
MAC_DEVICE_TOKEN = os.getenv("MAC_DEVICE_TOKEN", "change-me")
ALLOWED_ORIGINS = {o.strip() for o in os.getenv("ALLOWED_ORIGINS", "").split(",") if o.strip()}
REQUIRE_HTTPS = os.getenv("REQUIRE_HTTPS", "false").lower() == "true"
RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("RATE_LIMIT_WINDOW_SECONDS", "60"))
RATE_LIMIT_CREATE_CODE = int(os.getenv("RATE_LIMIT_CREATE_CODE", "15"))
RATE_LIMIT_CHECK_CODE = int(os.getenv("RATE_LIMIT_CHECK_CODE", "120"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("relay")

app = FastAPI(title="Mac Remote Relay")
app.add_middleware(
    CORSMiddleware,
    allow_origins=sorted(ALLOWED_ORIGINS) if ALLOWED_ORIGINS else ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class CodeCreateResponse(BaseModel):
    code: str
    expires_at: str


class HealthResponse(BaseModel):
    status: str
    active_pairs: int


@dataclass
class PairCode:
    code: str
    created_at: datetime
    expires_at: datetime


class PairSession:
    def __init__(self, code: str):
        self.code = code
        self.mac_ws: WebSocket | None = None
        self.phone_ws: WebSocket | None = None
        self.lock = asyncio.Lock()

    async def bind_mac(self, ws: WebSocket) -> None:
        async with self.lock:
            if self.mac_ws is not None:
                await self.mac_ws.close(code=1012, reason="Replaced by new Mac connection")
            self.mac_ws = ws

    async def bind_phone(self, ws: WebSocket) -> None:
        async with self.lock:
            if self.phone_ws is not None:
                await self.phone_ws.close(code=1012, reason="Replaced by new phone connection")
            self.phone_ws = ws

    async def other(self, ws: WebSocket) -> WebSocket | None:
        if self.mac_ws is ws:
            return self.phone_ws
        if self.phone_ws is ws:
            return self.mac_ws
        return None

    async def remove(self, ws: WebSocket) -> None:
        async with self.lock:
            if self.mac_ws is ws:
                self.mac_ws = None
            if self.phone_ws is ws:
                self.phone_ws = None

    def empty(self) -> bool:
        return self.mac_ws is None and self.phone_ws is None


codes: dict[str, PairCode] = {}
sessions: dict[str, PairSession] = {}
request_log: dict[str, deque[datetime]] = defaultdict(deque)
state_lock = asyncio.Lock()


def _now() -> datetime:
    return datetime.now(UTC)


def _new_code() -> str:
    return "".join(secrets.choice("0123456789") for _ in range(6))


def _client_ip(request: Request) -> str:
    xff = request.headers.get("x-forwarded-for", "").split(",")[0].strip()
    if xff:
        return xff
    if request.client and request.client.host:
        return request.client.host
    return "unknown"


def _is_https(request: Request) -> bool:
    forwarded_proto = request.headers.get("x-forwarded-proto", "")
    return request.url.scheme == "https" or forwarded_proto == "https"


def _enforce_https(request: Request) -> None:
    if REQUIRE_HTTPS and not _is_https(request):
        raise HTTPException(status_code=400, detail="HTTPS required")


def _enforce_origin_header(origin: str | None) -> None:
    if not ALLOWED_ORIGINS:
        return
    if origin is None or origin not in ALLOWED_ORIGINS:
        raise HTTPException(status_code=403, detail="Origin not allowed")


def _rate_limit(key: str, limit: int) -> None:
    now = _now()
    q = request_log[key]
    while q and (now - q[0]).total_seconds() > RATE_LIMIT_WINDOW_SECONDS:
        q.popleft()
    if len(q) >= limit:
        raise HTTPException(status_code=429, detail="Rate limit exceeded")
    q.append(now)


def _require_auth(auth_header: str | None) -> None:
    expected = f"Bearer {MAC_DEVICE_TOKEN}"
    if auth_header != expected:
        raise HTTPException(status_code=401, detail="Unauthorized")


async def _get_or_create_session(code: str) -> PairSession:
    async with state_lock:
        session = sessions.get(code)
        if session is None:
            session = PairSession(code)
            sessions[code] = session
        return session


async def _cleanup_code_and_session(code: str) -> None:
    async with state_lock:
        sessions.pop(code, None)
        codes.pop(code, None)


def _validate_code_exists_and_active(code: str) -> None:
    pair = codes.get(code)
    if pair is None:
        raise HTTPException(status_code=404, detail="Invalid code")
    if pair.expires_at < _now():
        codes.pop(code, None)
        sessions.pop(code, None)
        raise HTTPException(status_code=410, detail="Code expired")


@app.middleware("http")
async def add_security_headers(request: Request, call_next):
    start = _now()
    try:
        response = await call_next(request)
    except HTTPException as exc:
        response = JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})

    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Cache-Control"] = "no-store"
    if REQUIRE_HTTPS:
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"

    elapsed_ms = int((_now() - start).total_seconds() * 1000)
    logger.info("method=%s path=%s status=%s ms=%s", request.method, request.url.path, response.status_code, elapsed_ms)
    return response


@app.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    return HealthResponse(status="ok", active_pairs=len(sessions))


@app.post("/api/codes", response_model=CodeCreateResponse)
async def create_code(
    request: Request,
    authorization: str | None = Header(default=None),
    origin: str | None = Header(default=None),
) -> CodeCreateResponse:
    _enforce_https(request)
    _enforce_origin_header(origin)
    _require_auth(authorization)
    _rate_limit(f"create:{_client_ip(request)}", RATE_LIMIT_CREATE_CODE)

    async with state_lock:
        for code in list(codes.keys()):
            if codes[code].expires_at < _now():
                codes.pop(code, None)
                sessions.pop(code, None)

        code = _new_code()
        while code in codes:
            code = _new_code()

        created_at = _now()
        expires_at = created_at + timedelta(seconds=PAIR_CODE_TTL_SECONDS)
        codes[code] = PairCode(code=code, created_at=created_at, expires_at=expires_at)

    return CodeCreateResponse(code=code, expires_at=expires_at.isoformat())


@app.get("/api/codes/{code}")
async def check_code(request: Request, code: str, origin: str | None = Header(default=None)) -> dict[str, Any]:
    _enforce_https(request)
    _enforce_origin_header(origin)
    _rate_limit(f"check:{_client_ip(request)}", RATE_LIMIT_CHECK_CODE)
    _validate_code_exists_and_active(code)
    pair = codes[code]
    return {
        "code": pair.code,
        "expires_at": pair.expires_at.isoformat(),
        "remaining_seconds": int((pair.expires_at - _now()).total_seconds()),
        "mac_connected": bool(sessions.get(code) and sessions[code].mac_ws),
    }


async def _bridge_messages(session: PairSession, ws: WebSocket, side: str) -> None:
    try:
        while True:
            payload = await ws.receive_json()
            other = await session.other(ws)
            if other is None:
                if side == "phone":
                    await ws.send_json({"type": "status", "message": "Waiting for Mac..."})
                continue
            await other.send_json(payload)
    except WebSocketDisconnect:
        pass
    finally:
        await session.remove(ws)
        other = await session.other(ws)
        if other is not None:
            try:
                await other.send_json({"type": "status", "message": f"{side} disconnected"})
            except Exception:
                pass
        if session.empty():
            await _cleanup_code_and_session(session.code)


def _ws_origin_allowed(origin: str | None) -> bool:
    if not ALLOWED_ORIGINS:
        return True
    return origin in ALLOWED_ORIGINS


@app.websocket("/ws/mac/{code}")
async def ws_mac(websocket: WebSocket, code: str, token: str) -> None:
    if token != MAC_DEVICE_TOKEN:
        await websocket.close(code=1008, reason="Unauthorized")
        return

    try:
        _validate_code_exists_and_active(code)
    except HTTPException:
        await websocket.close(code=1008, reason="Invalid or expired code")
        return

    await websocket.accept()
    session = await _get_or_create_session(code)
    await session.bind_mac(websocket)
    await websocket.send_json({"type": "status", "message": "Mac connected to relay"})
    await _bridge_messages(session, websocket, "mac")


@app.websocket("/ws/phone/{code}")
async def ws_phone(websocket: WebSocket, code: str) -> None:
    origin = websocket.headers.get("origin")
    if not _ws_origin_allowed(origin):
        await websocket.close(code=1008, reason="Origin not allowed")
        return

    try:
        _validate_code_exists_and_active(code)
    except HTTPException:
        await websocket.close(code=1008, reason="Invalid or expired code")
        return

    await websocket.accept()
    session = await _get_or_create_session(code)
    await session.bind_phone(websocket)
    await websocket.send_json({"type": "status", "message": "Phone connected to relay"})
    await _bridge_messages(session, websocket, "phone")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("relay_server:app", host="0.0.0.0", port=8787, reload=False)
