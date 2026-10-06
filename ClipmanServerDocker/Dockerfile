ARG BUILDPLATFORM
FROM --platform=$BUILDPLATFORM golang:1.26.8 AS browser
WORKDIR /source
COPY ClipmanCli/ /source/ClipmanCli/
COPY ClipmanServer/ /source/ClipmanServer/
COPY ClipmanServerLinux/clipman_server.py /source/ClipmanServerLinux/clipman_server.py
COPY ClipmanAndroid/app/src/main/res/drawable-nodpi/clipman_app_icon.png /source/ClipmanAndroid/app/src/main/res/drawable-nodpi/clipman_app_icon.png
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
    && python3 ClipmanServer/build_web.py --output /browser --server-output /clipman_server.py

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
COPY --from=browser /clipman_server.py /app/clipman_server.py
COPY --from=browser /browser/ /app/web/
COPY ClipmanServerDocker/docker-entrypoint.sh /usr/local/bin/clipman-server-entrypoint
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl \
    && rm -rf /var/lib/apt/lists/* \
    && chmod +x /usr/local/bin/clipman-server-entrypoint

VOLUME ["/data"]
EXPOSE 8080

ENTRYPOINT ["clipman-server-entrypoint"]
