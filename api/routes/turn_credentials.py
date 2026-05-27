"""TURN credentials endpoint for time-limited WebRTC authentication.

Two backends are supported:

1. **Local coturn shared-secret** (draft-uberti-behave-turn-rest-00).
   Credentials are minted in-process via HMAC-SHA1 against `TURN_SECRET`.
   Requires running a coturn server reachable by both browser and backend.

2. **Cloudflare Realtime TURN**. When `CLOUDFLARE_TURN_KEY_ID` and
   `CLOUDFLARE_TURN_API_TOKEN` are set, credentials are minted by calling
   Cloudflare's `generate-ice-servers` API. Use this when the deploy is
   behind an HTTPS-only proxy (Lightning Studios, Render, Fly, etc.) that
   doesn't pass UDP through to a self-hosted coturn.

Cloudflare wins when both are set.
"""

import base64
import hashlib
import hmac
import time
from typing import List, Optional

import httpx
from fastapi import APIRouter, Depends, HTTPException
from loguru import logger
from pydantic import BaseModel

from api.constants import (
    CLOUDFLARE_TURN_API_TOKEN,
    CLOUDFLARE_TURN_KEY_ID,
    ENVIRONMENT,
    TURN_CREDENTIAL_TTL,
    TURN_HOST,
    TURN_PORT,
    TURN_SECRET,
    TURN_TLS_PORT,
)
from api.db.models import UserModel
from api.enums import Environment
from api.services.auth.depends import get_user

router = APIRouter(prefix="/turn", tags=["turn"])

CLOUDFLARE_TURN_API_URL = (
    "https://rtc.live.cloudflare.com/v1/turn/keys/{key_id}/credentials/generate-ice-servers"
)


class TurnCredentialsResponse(BaseModel):
    """Response model for TURN credentials."""

    username: str
    password: str
    ttl: int
    uris: List[str]


class TurnConfigResponse(BaseModel):
    """Response model for TURN configuration status."""

    enabled: bool
    host: Optional[str] = None


def turn_configured() -> bool:
    """True if either Cloudflare TURN or local coturn shared-secret is set up.

    `/health` and the public-embed endpoint use this to decide whether to
    advertise TURN as available.
    """
    return bool(CLOUDFLARE_TURN_KEY_ID and CLOUDFLARE_TURN_API_TOKEN) or bool(TURN_SECRET)


async def _cloudflare_turn_credentials(ttl: int) -> dict:
    """Mint short-lived ICE-server credentials from Cloudflare Realtime TURN.

    Cloudflare's response is an ARRAY of ICE-server objects, e.g.::

        {"iceServers": [
            {"urls": ["stun:stun.cloudflare.com:3478", ...]},
            {"urls": ["turn:turn.cloudflare.com:3478?transport=udp", ...],
             "username": "...", "credential": "..."}
        ]}

    STUN entries have urls only; the TURN entry has the credentials at
    the same level. We flatten urls across all entries and pick up the
    first non-empty username/credential we encounter.
    """
    url = CLOUDFLARE_TURN_API_URL.format(key_id=CLOUDFLARE_TURN_KEY_ID)
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            url,
            headers={
                "Authorization": f"Bearer {CLOUDFLARE_TURN_API_TOKEN}",
                "Content-Type": "application/json",
            },
            json={"ttl": ttl},
        )
        resp.raise_for_status()
        body = resp.json()

    ice_servers = body.get("iceServers")
    if not isinstance(ice_servers, list) or not ice_servers:
        raise RuntimeError(f"Cloudflare returned unexpected payload: {body!r}")

    all_urls: list[str] = []
    username = ""
    credential = ""
    for srv in ice_servers:
        urls = srv.get("urls") or []
        if isinstance(urls, str):
            urls = [urls]
        all_urls.extend(urls)
        if srv.get("username") and not username:
            username = srv["username"]
        if srv.get("credential") and not credential:
            credential = srv["credential"]

    if not all_urls or not username or not credential:
        raise RuntimeError(f"Cloudflare returned unexpected payload: {body!r}")

    return {
        "username": username,
        "password": credential,
        "ttl": ttl,
        "uris": all_urls,
    }


def _hmac_turn_credentials(user_id: str, ttl: int) -> dict:
    """Local coturn use-auth-secret credentials. Unchanged from original."""
    if not TURN_SECRET:
        raise ValueError("TURN_SECRET is not configured")

    expiration = int(time.time()) + ttl
    username = f"{expiration}:{user_id}"
    password = base64.b64encode(
        hmac.new(
            TURN_SECRET.encode("utf-8"),
            username.encode("utf-8"),
            hashlib.sha1,
        ).digest()
    ).decode("utf-8")

    uris = []
    if ENVIRONMENT == Environment.LOCAL.value:
        uris.extend(
            [
                f"turn:{TURN_HOST}:{TURN_PORT}?transport=tcp",
                f"turn:{TURN_HOST}:{TURN_PORT}",
            ]
        )
    else:
        uris.extend(
            [
                f"turn:{TURN_HOST}:{TURN_PORT}",
                f"turn:{TURN_HOST}:{TURN_PORT}?transport=tcp",
            ]
        )
    if TURN_TLS_PORT:
        uris.extend(
            [
                f"turns:{TURN_HOST}:{TURN_TLS_PORT}",
                f"turns:{TURN_HOST}:{TURN_TLS_PORT}?transport=tcp",
            ]
        )

    return {
        "username": username,
        "password": password,
        "ttl": ttl,
        "uris": uris,
    }


async def generate_turn_credentials(user_id: str, ttl: int = TURN_CREDENTIAL_TTL) -> dict:
    """Mint TURN credentials. Cloudflare path wins if configured.

    Args:
        user_id: Identifier for the credential (used only by the HMAC path
            for auditing; Cloudflare uses its own opaque username).
        ttl: Lifetime of the credential in seconds.

    Returns:
        Dict with username, password, ttl, uris — same shape regardless of backend.
    """
    if CLOUDFLARE_TURN_KEY_ID and CLOUDFLARE_TURN_API_TOKEN:
        try:
            return await _cloudflare_turn_credentials(ttl)
        except Exception as e:
            logger.error(f"Cloudflare TURN credential generation failed: {e!r}")
            # Fall back to HMAC if it's configured AND Cloudflare is broken.
            # If neither works, surface the original Cloudflare error.
            if TURN_SECRET:
                logger.warning("Falling back to local coturn HMAC credentials")
                return _hmac_turn_credentials(user_id, ttl)
            raise

    return _hmac_turn_credentials(user_id, ttl)


@router.get("/credentials", response_model=TurnCredentialsResponse)
async def get_turn_credentials(
    user: UserModel = Depends(get_user),
) -> TurnCredentialsResponse:
    """Get time-limited TURN credentials for WebRTC connections."""
    if not turn_configured():
        logger.warning("TURN credentials requested but no TURN backend is configured")
        raise HTTPException(
            status_code=503,
            detail="TURN server not configured",
        )

    try:
        credentials = await generate_turn_credentials(str(user.id))
        logger.debug(f"Generated TURN credentials for user {user.id}")
        return TurnCredentialsResponse(**credentials)
    except Exception as e:
        logger.error(f"Failed to generate TURN credentials: {e}")
        raise HTTPException(
            status_code=500,
            detail="Failed to generate TURN credentials",
        )
