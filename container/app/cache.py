"""
Hybrid cache:
  * Exact:    SHA-256(prompt) -> response       (O(1) GET)
  * Semantic: scan most-recent N embeddings, cosine-sim threshold

Works on Memorystore BASIC (no RediSearch). The recent-N scan trades a small
amount of CPU for portability across tiers — fine for a gateway that's usually
RAM-bound, not CPU-bound. If you upgrade to Redis 7.2 with the search module
(or migrate to MemoryDB / Vertex Vector Search), swap this for a real ANN call.
"""
from __future__ import annotations

import json
import math
import time
from typing import Optional

import redis.asyncio as redis

# Key layout
EXACT_PREFIX  = "exact:"     # exact:<sha256> -> response text
EMBED_LIST    = "embeds"     # LIST of JSON {hash, embedding, ts}
RECENT_WINDOW = 200          # how many recent embeddings to scan

class SemanticCache:
    def __init__(self, host: str, port: int, ttl: int, auth: str | None = None):
        self.client = redis.Redis(
            host=host,
            port=port,
            password=auth,
            ssl=True,
            ssl_cert_reqs=None,
            decode_responses=True,
        )
        self.ttl = ttl

    async def close(self):
        await self.client.aclose()

    # ---- Exact ------------------------------------------------------------
    async def get_exact(self, prompt_hash: str) -> Optional[str]:
        return await self.client.get(EXACT_PREFIX + prompt_hash)

    # ---- Semantic ---------------------------------------------------------
    async def get_semantic(self, embedding: list[float], threshold: float) -> Optional[str]:
        entries = await self.client.lrange(EMBED_LIST, 0, RECENT_WINDOW - 1)
        best_sim, best_hash = -1.0, None
        for raw in entries:
            row = json.loads(raw)
            sim = _cosine(embedding, row["embedding"])
            if sim > best_sim:
                best_sim, best_hash = sim, row["hash"]
        if best_sim >= threshold and best_hash:
            return await self.client.get(EXACT_PREFIX + best_hash)
        return None

    # ---- Write-back -------------------------------------------------------
    async def put(self, prompt_hash: str, embedding: Optional[list[float]], response: str):
        pipe = self.client.pipeline()
        pipe.set(EXACT_PREFIX + prompt_hash, response, ex=self.ttl)
        if embedding is not None:
            row = json.dumps({"hash": prompt_hash, "embedding": embedding, "ts": time.time()})
            pipe.lpush(EMBED_LIST, row)
            pipe.ltrim(EMBED_LIST, 0, RECENT_WINDOW - 1)  # bounded memory
        await pipe.execute()


def _cosine(a: list[float], b: list[float]) -> float:
    if len(a) != len(b):
        return -1.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else -1.0
