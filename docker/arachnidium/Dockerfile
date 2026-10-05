FROM python:3.13-bookworm

ARG ARACHNIDIUM_REV=e9bf2fefe55ad6bf4e967ba074a009021dd3007e
ENV BUN_INSTALL=/opt/bun
ENV PATH=/opt/bun/bin:/root/.local/bin:${PATH}
ENV UV_PROJECT_ENVIRONMENT=/opt/arachnidium/.venv

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://bun.sh/install | bash \
    && curl -LsSf https://astral.sh/uv/install.sh | sh

RUN git clone --recursive https://github.com/p2r3/Arachnidium.git /opt/arachnidium \
    && cd /opt/arachnidium \
    && git checkout "${ARACHNIDIUM_REV}" \
    && git submodule update --init --recursive \
    && python - <<'PY'
from pathlib import Path
p = Path('/opt/arachnidium/addon.py')
s = p.read_text()
s = s.replace(
    'import tkinter as tk\nfrom tkinter import ttk\n',
    'try:\n  import tkinter as tk\n  from tkinter import ttk\nexcept ImportError:\n  tk = None\n  ttk = None\n'
)
p.write_text(s)
PY

WORKDIR /opt/arachnidium
RUN uv sync --frozen \
    && cd bun-api \
    && bun install --frozen-lockfile

COPY defaults.json /opt/arachnidium/defaults.json
COPY main-http.py /opt/arachnidium/main-http.py
COPY entrypoint.sh /usr/local/bin/arachnidium-http
RUN chmod 0755 /usr/local/bin/arachnidium-http

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/arachnidium-http"]
