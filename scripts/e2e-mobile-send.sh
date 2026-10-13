#!/usr/bin/env bash
# End-to-end for 0013 against the BUILT image, in demo mode (fixture data, no mail server): in a
# phone-sized browser, a new message sent from the list lands back on the list, not on the empty
# reading pane, and a reply sent from an open message stays on that message. The client side is
# e2e-mobile-send.mjs, run in Playwright's own image inside the webmail container's network, so the
# page is served from localhost (a secure context, as in production over HTTPS).
# Usage: e2e-mobile-send.sh <image>
set -euo pipefail
IMAGE="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
PLAYWRIGHT=mcr.microsoft.com/playwright:v1.63.0-noble
cleanup() { docker rm -f e2e-ms-bw >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --name e2e-ms-bw -e DEMO_MODE=true -e JMAP_SERVER_URL=https://mail.example.test \
  -e SESSION_SECRET="$(openssl rand -hex 32)" "$IMAGE" >/dev/null
healthy=
for _ in $(seq 1 60); do
  docker exec e2e-ms-bw node -e 'fetch("http://127.0.0.1:3000/api/health").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' 2>/dev/null && { healthy=1; break; }
  sleep 1
done
[ -n "$healthy" ] || { docker logs e2e-ms-bw | tail -20; echo "::error::the image did not become healthy"; exit 1; }

docker run --rm --network container:e2e-ms-bw -v "$HERE/e2e-mobile-send.mjs:/e2e/e2e.mjs:ro" \
  "$PLAYWRIGHT" bash -c 'cd /e2e && npm i --silent --no-audit --no-fund playwright-core@1.63.0 >/dev/null && node e2e.mjs http://localhost:3000' \
  || { docker logs e2e-ms-bw 2>&1 | tail -30; exit 1; }
