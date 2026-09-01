FROM node:22-alpine@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2 AS web-builder
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

FROM python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf
WORKDIR /app
COPY requirements.lock .
RUN python -m pip install --no-cache-dir --require-hashes -r requirements.lock
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache
RUN groupadd --gid 10001 hausklar \
    && useradd --uid 10001 --gid hausklar --create-home --shell /usr/sbin/nologin hausklar \
    && mkdir -p /app/data /app/fitness-worker-exchange \
    && chown -R hausklar:hausklar /app
COPY --chown=hausklar:hausklar app/ app/
COPY --chown=hausklar:hausklar --from=web-builder /web/dist/ app/web/
USER 10001:10001
EXPOSE 8001
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8001/api/healthcheck', timeout=3).read()"]
CMD ["sh", "-c", "umask 077; exec uvicorn app.main:app --host 0.0.0.0 --port 8001 --no-access-log"]
