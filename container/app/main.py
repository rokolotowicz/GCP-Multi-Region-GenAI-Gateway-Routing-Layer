"""
GenAI Gateway — FastAPI proxy in front of Vertex AI.

Request flow:
  1. Receive prompt -> scrub for log safety (keep original for LLM call)
  2. Compute embedding via Vertex AI text-embedding model
  3. Look up Redis: exact-hash hit -> return; else semantic-similarity scan
  4. On miss: call Vertex AI generate. On 429/5xx, fail over to peer region.
  5. Async write-back to Redis (hash key + embedding key)
  6. Log scrubbed metadata (NEVER the raw prompt)
"""
from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from .cache import SemanticCache
from .llm import VertexClient, UpstreamError
from .pii import scrub

# ---------------------------------------------------------------------------
# Config from env (set by Cloud Run via Terraform)
# ---------------------------------------------------------------------------
REDIS_HOST       = os.environ["REDIS_HOST"]
REDIS_PORT       = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_AUTH       = os.environ.get("REDIS_AUTH") 
PRIMARY_REGION   = os.environ["PRIMARY_REGION"]
SECONDARY_REGION = os.environ["SECONDARY_REGION"]
LOCAL_REGION     = os.environ["LOCAL_REGION"]
PROJECT_ID       = os.environ["GOOGLE_CLOUD_PROJECT"]

SIMILARITY_THRESHOLD = float(os.environ.get("SIMILARITY_THRESHOLD", "0.92"))
CACHE_TTL_SECONDS    = int(os.environ.get("CACHE_TTL_SECONDS", "86400"))  # 24h

# ---------------------------------------------------------------------------
# Logging — structured JSON for Cloud Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format='{"severity":"%(levelname)s","time":"%(asctime)s","msg":%(message)s}',
)
log = logging.getLogger("gateway")

# ---------------------------------------------------------------------------
# Lifespan: build clients once at cold-start
# ---------------------------------------------------------------------------
state: dict = {}

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Multi-region geography for generation, single-region for embeddings.
    # us-east1 -> US geo, europe-west1 -> EU geo.
    gen_local = "us" if LOCAL_REGION.startswith("us") else "eu"
    gen_peer  = "eu" if gen_local == "us" else "us"
    embed_peer = SECONDARY_REGION if LOCAL_REGION == PRIMARY_REGION else PRIMARY_REGION

    state["cache"] = SemanticCache(
        host=REDIS_HOST, port=REDIS_PORT, ttl=CACHE_TTL_SECONDS, auth=REDIS_AUTH
    )
    state["llm_local"] = VertexClient(
        project=PROJECT_ID,
        gen_location=gen_local,
        embed_location=LOCAL_REGION,
    )
    state["llm_peer"] = VertexClient(
        project=PROJECT_ID,
        gen_location=gen_peer,
        embed_location=embed_peer,
    )
    log.info('"event":"startup","local_region":"%s","peer_region":"%s","gen_local":"%s","gen_peer":"%s"' % (LOCAL_REGION, embed_peer, gen_local, gen_peer))
    yield
    await state["cache"].close()

app = FastAPI(title="GenAI Gateway", lifespan=lifespan)

# ---------------------------------------------------------------------------
# API contract
# ---------------------------------------------------------------------------
class GenerateRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=8000)
    model: str = Field(default="gemini-3.5-flash")  # caller can request -pro
    max_tokens: int = Field(default=1024, ge=1, le=8192)

class GenerateResponse(BaseModel):
    response: str
    cached: bool
    served_by_region: str
    latency_ms: int

@app.get("/healthz")
async def healthz():
    return {"status": "ok", "region": LOCAL_REGION}

@app.post("/v1/generate", response_model=GenerateResponse)
async def generate(req: GenerateRequest) -> GenerateResponse:
    t0 = time.time()
    cache: SemanticCache = state["cache"]
    llm_local: VertexClient = state["llm_local"]
    llm_peer: VertexClient = state["llm_peer"]

    prompt_hash = hashlib.sha256(req.prompt.encode("utf-8")).hexdigest()

    # ---- 1. Exact-hash cache lookup --------------------------------------
    if hit := await cache.get_exact(prompt_hash):
        _log_request(req, prompt_hash, cached=True, region=LOCAL_REGION, t0=t0)
        return GenerateResponse(
            response=hit, cached=True, served_by_region=LOCAL_REGION,
            latency_ms=int((time.time() - t0) * 1000),
        )

    # ---- 2. Embedding + semantic similarity -------------------------------
    try:
        embedding = await llm_local.embed(req.prompt)
    except UpstreamError:
        embedding = None  # degrade gracefully — skip semantic, go straight to LLM

    if embedding is not None:
        if hit := await cache.get_semantic(embedding, SIMILARITY_THRESHOLD):
            _log_request(req, prompt_hash, cached=True, region=LOCAL_REGION, t0=t0)
            return GenerateResponse(
                response=hit, cached=True, served_by_region=LOCAL_REGION,
                latency_ms=int((time.time() - t0) * 1000),
            )

    # ---- 3. LLM call with circuit-breaker failover ------------------------
    served_by = LOCAL_REGION
    try:
        text = await llm_local.generate(req.prompt, req.model, req.max_tokens)
    except UpstreamError as e:
        log.warning(
            '"event":"failover","reason":"%s","from":"%s","to":"%s"'
            % (e.reason, LOCAL_REGION, llm_peer.region)
        )
        try:
            text = await llm_peer.generate(req.prompt, req.model, req.max_tokens)
            served_by = llm_peer.region
        except UpstreamError as e2:
            log.error('"event":"upstream_failed_both_regions","reason":"%s"' % e2.reason)
            raise HTTPException(status_code=502, detail="Upstream LLM unavailable")

    # ---- 4. Async write-back to cache (fire-and-forget) -------------------
    asyncio.create_task(cache.put(prompt_hash, embedding, text))

    _log_request(req, prompt_hash, cached=False, region=served_by, t0=t0)
    return GenerateResponse(
        response=text, cached=False, served_by_region=served_by,
        latency_ms=int((time.time() - t0) * 1000),
    )

# ---------------------------------------------------------------------------
# Structured logging — PII-scrubbed metadata only
# ---------------------------------------------------------------------------
def _log_request(req: GenerateRequest, h: str, cached: bool, region: str, t0: float):
    scrubbed_preview = scrub(req.prompt)[:80]  # first 80 chars, PII removed
    log.info(
        '"event":"request","hash":"%s","model":"%s","cached":%s,"region":"%s","latency_ms":%d,"preview":"%s"'
        % (h[:12], req.model, str(cached).lower(), region,
           int((time.time() - t0) * 1000), scrubbed_preview.replace('"', "'"))
    )
