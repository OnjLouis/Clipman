FROM python:3.11-slim

LABEL org.opencontainers.image.title="Clipman Server"
LABEL org.opencontainers.image.description="Self-hosted sync server for Clipman clipboard history databases."
LABEL org.opencontainers.image.source="https://github.com/OnjLouis/Clipman"

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV CLIPMAN_DATA_DIR=/data
ENV CLIPMAN_HOST=0.0.0.0
ENV CLIPMAN_PORT=8080

WORKDIR /app
COPY ClipmanServerLinux/clipman_server.py /app/clipman_server.py
COPY ClipmanServerDocker/docker-entrypoint.sh /usr/local/bin/clipman-server-entrypoint
RUN chmod +x /usr/local/bin/clipman-server-entrypoint

VOLUME ["/data"]
EXPOSE 8080

ENTRYPOINT ["clipman-server-entrypoint"]
