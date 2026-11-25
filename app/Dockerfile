# Code Buster application image.
#
# Pin to a digest before the live demo:
#   docker pull python:3.13-slim
#   docker inspect --format='{{index .RepoDigests 0}}' python:3.13-slim
# then replace the tag below with python:3.13-slim@sha256:<digest>.
# No digest is written here because an invented one would never pull.
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    APP_PORT=8080

WORKDIR /app

# Dependencies first, so a code-only change reuses this layer.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py ./

# Build metadata. APP_COMMIT is the full git SHA; the page renders it.
ARG APP_VERSION=0.1.0
ARG APP_COMMIT=local
ENV APP_VERSION=${APP_VERSION} \
    APP_COMMIT=${APP_COMMIT}

# Never run as root.
RUN useradd --create-home --uid 10001 buster
USER 10001

EXPOSE 8080

# Container-level check. The ALB target group checks /health too; this one
# makes `docker run` locally fail fast if the app did not come up.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,os,sys; sys.exit(0 if urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"APP_PORT\"]}/health').status==200 else 1)"

CMD ["sh", "-c", "exec uvicorn main:app --host 0.0.0.0 --port ${APP_PORT}"]
