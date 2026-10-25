#!/usr/bin/env bash
# End-to-end smoke test against a running backend (real Gemini calls).
#   ./scripts/smoke_test.sh                 # all checks
#   SKIP_INGEST=1 ./scripts/smoke_test.sh   # reuse current closet (saves quota)
#   BASE=https://tunnel.example ./scripts/smoke_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."

BASE="${BASE:-http://localhost:8000}"
PY=.venv/bin/python
SAMPLES=samples
OUT=$(mktemp -d)
RUN_ID=$(date +%s)
pass=0; fail=0

ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }
jget() { $PY -c "import json,sys; d=json.load(open('$1')); print($2)" 2>/dev/null; }

echo "== health"
curl -sf "$BASE/health" > "$OUT/health.json" && [ "$(jget "$OUT/health.json" "d['ok']")" = "True" ] \
  && ok "/health browser=$(jget "$OUT/health.json" "d['browser']") extension=$(jget "$OUT/health.json" "d['extension_connected']")" \
  || bad "/health"

echo "== onboarding"
curl -sf -X POST "$BASE/onboarding" -H 'Content-Type: application/json' \
  -d '{"name":"Smoke","top_size":"M","pant_size":"32x32","shoe_size":"10","fit_preference":"menswear","budget":"under $250"}' > "$OUT/onb.json" \
  && [ "$(jget "$OUT/onb.json" "d['top_size']")" = "M" ] && ok "POST /onboarding" || bad "POST /onboarding"
curl -sf "$BASE/onboarding" > "$OUT/onb2.json" && [ "$(jget "$OUT/onb2.json" "d['budget']")" = 'under $250' ] \
  && ok "GET /onboarding" || bad "GET /onboarding"

echo "== selfie"
curl -sf -X POST "$BASE/selfie" -F "file=@$SAMPLES/selfie.jpg" > "$OUT/selfie.json" \
  && SURL=$(jget "$OUT/selfie.json" "d['selfie_url']") && [ -n "$SURL" ] \
  && curl -sf -o /dev/null "$BASE$SURL" && ok "POST /selfie -> $SURL" || bad "POST /selfie"

if [ -z "${SKIP_INGEST:-}" ]; then
  echo "== ingest (concurrent; real Gemini calls, may take minutes on a busy key)"
  for n in outfit1 outfit2 outfit3; do
    curl -s -X POST "$BASE/ingest" -F "file=@$SAMPLES/$n.jpg" -F "asset_id=smoke-$n-$RUN_ID" -F source=photo > "$OUT/ing_$n.json" &
  done
  curl -s -X POST "$BASE/ingest" -F "file=@$SAMPLES/screenshot1.jpg" -F "asset_id=smoke-shot-$RUN_ID" -F source=screenshot > "$OUT/ing_shot.json" &
  wait
  for f in "$OUT"/ing_*.json; do
    n=$(jget "$f" "len(d['items'])"); r=$(jget "$f" "d.get('reason')")
    [ -n "$n" ] && [ "$n" -gt 0 ] && ok "ingest $(basename "$f") -> $n items ($(jget "$f" "', '.join(i['name']+'/'+i['signal'] for i in d['items'])"))" \
      || bad "ingest $(basename "$f") -> ${n:-?} items, reason=$r"
  done
  # idempotency
  curl -s -X POST "$BASE/ingest" -F "file=@$SAMPLES/outfit2.jpg" -F "asset_id=smoke-outfit2-$RUN_ID" -F source=photo > "$OUT/ing_again.json"
  [ "$(jget "$OUT/ing_again.json" "[i['id'] for i in d['items']]")" = "$(jget "$OUT/ing_outfit2.json" "[i['id'] for i in d['items']]")" ] \
    && ok "ingest idempotent per asset_id" || bad "ingest idempotency"
fi

echo "== closet"
curl -sf "$BASE/closet" > "$OUT/closet.json" && N=$(jget "$OUT/closet.json" "len(d['items'])") && [ "$N" -gt 0 ] \
  && ok "GET /closet -> $N items" || bad "GET /closet"
CROP=$(jget "$OUT/closet.json" "d['items'][0]['crop_url']")
[ -n "$CROP" ] && curl -sf -o /dev/null "$BASE$CROP" && ok "crop served ($CROP)" || bad "crop served"

echo "== profile/rebuild (Argon high thinking; can be slow)"
curl -s -X POST "$BASE/profile/rebuild" > "$OUT/profile.json"
S=$(jget "$OUT/profile.json" "d['summary'][:90]")
[ -n "$S" ] && ok "POST /profile/rebuild: $S… (evidence=$(jget "$OUT/profile.json" "len(d['evidence'])"))" || bad "POST /profile/rebuild: $(head -c 200 "$OUT/profile.json")"
curl -sf "$BASE/profile" > "$OUT/profile2.json" && [ -n "$(jget "$OUT/profile2.json" "d['updated_at']")" ] && ok "GET /profile" || bad "GET /profile"

echo "== chat (SSE)"
curl -sN -m "${CHAT_TIMEOUT:-400}" -X POST "$BASE/chat" -H 'Content-Type: application/json' \
  -d '{"message":"find me a jacket I would like"}' > "$OUT/chat.txt"
$PY - "$OUT/chat.txt" <<'EOF'
import json, sys
for line in open(sys.argv[1]):
    if not line.startswith("data: "):
        continue
    e = json.loads(line[6:]); t = e["type"]
    if t == "candidate":
        c = e["candidate"]; print(f"    candidate: {c['title']} | {c.get('price')} | {c['url'][:80]} | img={bool(c.get('image_url'))}")
    elif t == "tool":
        print(f"    tool: {e['name']} {json.dumps(e['args'])[:100]}")
    elif t in ("message", "error", "done"):
        print(f"    {t}: {json.dumps({k: v for k, v in e.items() if k != 'type'})[:160]}")
EOF
NC=$(grep -c '"type": "candidate"' "$OUT/chat.txt")
grep -q '"type": "done"' "$OUT/chat.txt" && ok "SSE stream completed with done" || bad "SSE done event missing"
[ "$NC" -gt 0 ] && ok "chat produced $NC candidate(s)" || bad "chat produced 0 candidates"
CID=$(grep '"type": "candidate"' "$OUT/chat.txt" | head -1 | sed 's/^data: //' | $PY -c "import json,sys; print(json.load(sys.stdin)['candidate']['id'])" 2>/dev/null)

echo "== feedback"
if [ -n "$CID" ]; then
  curl -s -X POST "$BASE/feedback" -H 'Content-Type: application/json' \
    -d "{\"candidate_id\":\"$CID\",\"verdict\":\"dislike\",\"reason\":\"too shiny, prefer matte fabrics\"}" > "$OUT/fb.json"
  [ "$(jget "$OUT/fb.json" "d['ok']")" = "True" ] && ok "POST /feedback (avoid now: $(jget "$OUT/fb.json" "(d.get('profile') or {}).get('avoid')"))" || bad "POST /feedback"
else
  bad "POST /feedback skipped (no candidate id)"
fi

echo
echo "passed=$pass failed=$fail (artifacts in $OUT)"
[ "$fail" -eq 0 ]
