FROM python:3.12-slim

# Health checks are defined where the container runs (the load balancer on
# AWS, Docker Compose locally). The same image is also the worker, which has
# no web server, so an image-level HEALTHCHECK would mark it unhealthy.
#checkov:skip=CKV_DOCKER_2:Health checks are set by the ALB and Compose; the image is shared by web and worker.

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Apply the latest Debian security fixes. The base image is rebuilt only
# every few weeks, so it often lags behind published patches.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --upgrade pip \
    && pip install -r requirements.txt

COPY app ./app

# Run as a non-root user.
RUN useradd --create-home --uid 1000 docflow \
    && mkdir -p /data/uploads \
    && chown -R docflow:docflow /app /data
USER docflow

# On AWS the root filesystem is read-only. /tmp is a separate scratch volume;
# declaring it here makes ECS copy the image's /tmp (world-writable) into it,
# so the non-root user can write there.
VOLUME ["/tmp"]

EXPOSE 8000

# Same image runs the web server (default) or the worker (command override in compose).
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
