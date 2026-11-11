# Linux amd64 userspace for Android builds. The emulator binary published
# for Linux is x86_64, and so are Chromium's host tools (gn, clang).
FROM debian:bookworm

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bzip2 \
    ca-certificates \
    curl \
    git \
    libasound2 \
    libc6 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libglib2.0-0 \
    libglu1-mesa \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libpulse0 \
    libx11-6 \
    libx11-xcb1 \
    libxcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxi6 \
    libxkbcommon0 \
    libxrandr2 \
    libxrender1 \
    libxtst6 \
    openjdk-17-jdk-headless \
    pkg-config \
    python-is-python3 \
    python3 \
    rsync \
    sudo \
    unzip \
    xz-utils \
    zip \
  && rm -rf /var/lib/apt/lists/*

ARG UID=1000
ARG GID=1000
RUN groupadd -o -g "${GID}" webrtc \
  && useradd -o -m -u "${UID}" -g "${GID}" -s /bin/bash webrtc \
  && echo 'webrtc ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/webrtc \
  && chmod 440 /etc/sudoers.d/webrtc

USER webrtc
WORKDIR /tmp
