#!/usr/bin/env bash
# Create .venv if missing, install requirements, run the API on 0.0.0.0:8000.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x .venv/bin/python ]; then
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 .venv
  else
    python3 -m venv .venv
  fi
fi

if command -v uv >/dev/null 2>&1; then
  uv pip install --python .venv/bin/python -q -r requirements.txt
else
  .venv/bin/pip install -q -r requirements.txt
fi

[ -f .env ] || echo "warning: backend/.env missing — copy .env.example and set GEMINI_API_KEY" >&2

exec .venv/bin/uvicorn main:app --host 0.0.0.0 --port "${PORT:-8000}" "$@"
