# VitalRoute reference receiver image.
#
# Standard-library-only Python server: no pip dependencies, no network
# access at build time beyond the base image, one non-root runtime user.
FROM python:3.12-slim

# No .pyc writes: the container runs with a read-only root filesystem.
ENV PYTHONDONTWRITEBYTECODE=1

RUN groupadd --gid 64000 vitalroute \
 && useradd --uid 64000 --gid 64000 --system --shell /usr/sbin/nologin vitalroute \
 && mkdir -p /var/lib/vitalroute \
 && chown vitalroute:vitalroute /var/lib/vitalroute

WORKDIR /app
COPY receiver.py storage.py validation.py ./

USER vitalroute
EXPOSE 8787

# VITALROUTE_HOST=0.0.0.0 is set by the compose file: the container must
# listen on all interfaces inside its namespace, and the *host* publish
# (127.0.0.1:<port>) is what keeps the backend private.
CMD ["python3", "receiver.py"]
