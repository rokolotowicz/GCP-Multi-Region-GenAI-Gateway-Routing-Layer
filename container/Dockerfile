# syntax=docker/dockerfile:1.7
# ---------- Build stage ------------------------------------------------------
FROM python:3.12-slim AS build

ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /install
COPY requirements.txt .
RUN pip install --prefix=/install/deps -r requirements.txt

# ---------- Runtime stage ----------------------------------------------------
FROM python:3.12-slim

# Non-root user
RUN groupadd -r app && useradd -r -g app -u 10001 app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app:/deps/lib/python3.12/site-packages \
    PATH=/deps/bin:$PATH \
    PORT=8080

WORKDIR /app
COPY --from=build /install/deps /deps
COPY app /app/app

USER app
EXPOSE 8080

# Cloud Run sets $PORT; uvicorn binds to it. Single worker — Cloud Run scales horizontally.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --workers 1 --loop uvloop"]
