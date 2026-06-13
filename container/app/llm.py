"""
Thin async wrapper around Vertex AI using the modern google-genai SDK.

Topology note: Vertex AI segments models across two endpoint types:
  - Single-region (us-east1, europe-west1): older models like text-embedding-004,
    custom-deployed models, and anything requiring physical region pinning.
  - Multi-region (us, eu): Google's newer SaaS-managed Gemini models
    (2.5+, 3.x), where Google's infrastructure pools capacity across regions
    within a geography. URL form: aiplatform.{us|eu}.rep.googleapis.com.

To serve both classes from one VertexClient, we instantiate two genai.Client
objects per region — one targeting the multi-region endpoint for generation,
one targeting the single-region endpoint for embeddings. The google-genai SDK
handles URL construction for both topologies internally.
"""
from __future__ import annotations

import asyncio

from google import genai
from google.genai.errors import APIError

EMBED_MODEL = "text-embedding-004"   # single-region only


class UpstreamError(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


class VertexClient:
    def __init__(self, project: str, gen_location: str, embed_location: str):
        # `region` is the geographic identity used in failover logs.
        self.region = gen_location
        self.gen_location = gen_location
        self.embed_location = embed_location

        # Two thread-safe, per-instance clients — no global state.
        self.gen_client = genai.Client(
            vertexai=True, project=project, location=gen_location
        )
        self.embed_client = genai.Client(
            vertexai=True, project=project, location=embed_location
        )

    # ---- Embeddings (single-region endpoint) ------------------------------
    async def embed(self, text: str) -> list[float]:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, self._embed_sync, text)

    def _embed_sync(self, text: str) -> list[float]:
        try:
            resp = self.embed_client.models.embed_content(
                model=EMBED_MODEL,
                contents=text,
            )
            return list(resp.embeddings[0].values)
        except APIError as e:
            if e.code == 429:
                raise UpstreamError("embed_429")
            if e.code == 503:
                raise UpstreamError("embed_503")
            raise UpstreamError(f"embed_error_code_{e.code}")
        except Exception as e:  # noqa: BLE001
            raise UpstreamError(f"embed_error:{type(e).__name__}")

    # ---- Generation (multi-region endpoint) -------------------------------
    async def generate(self, prompt: str, model_name: str, max_tokens: int) -> str:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            None, self._generate_sync, prompt, model_name, max_tokens
        )

    def _generate_sync(self, prompt: str, model_name: str, max_tokens: int) -> str:
        try:
            resp = self.gen_client.models.generate_content(
                model=model_name,
                contents=prompt,
                config={"max_output_tokens": max_tokens},
            )
            return resp.text
        except APIError as e:
            if e.code == 429:
                raise UpstreamError("generate_429")
            if e.code == 503:
                raise UpstreamError("generate_503")
            if e.code == 500:
                raise UpstreamError("generate_500")
            if e.code == 404:
                raise UpstreamError(f"generate_404:{model_name}")
            raise UpstreamError(f"generate_error_code_{e.code}")
        except Exception as e:  # noqa: BLE001
            raise UpstreamError(f"generate_error:{type(e).__name__}")