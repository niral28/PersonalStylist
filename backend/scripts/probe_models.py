"""Probe which Gemini model IDs work via the Interactions API. Usage: .venv/bin/python scripts/probe_models.py"""

import asyncio
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env"))

from google import genai  # noqa: E402

MODELS = sys.argv[1:] or ["gemini-4-argon", "gemini-3.8-flash", "gemini-3.5-flash-lite"]


async def probe(client, model):
    t = time.time()
    try:
        it = await client.aio.interactions.create(
            model=model,
            input="Reply with the single word OK.",
            generation_config={"thinking_level": "low"},
        )
        return f"{model}: OK ({time.time() - t:.1f}s) -> {it.output_text!r}"
    except Exception as e:
        return f"{model}: FAIL {type(e).__name__}: {str(e)[:300]}"


async def main():
    client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])
    for line in await asyncio.gather(*(probe(client, m) for m in MODELS)):
        print(line)
    if "--list" in os.environ.get("PROBE_FLAGS", ""):
        for m in client.models.list():
            print(m.name)


asyncio.run(main())
