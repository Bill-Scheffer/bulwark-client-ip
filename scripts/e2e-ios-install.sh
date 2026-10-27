#!/usr/bin/env bash
# End-to-end for 0015 against the BUILT image, in demo mode: Safari on an iPhone (WebKit, with the iPhone's user
# agent) gets the Install card with the Add to Home Screen steps; Chrome on Android, which has its own install prompt,
# does not. The client side is e2e-ios-install.mjs, run in Playwright's own image inside the webmail container's
# network, as e2e-mobile-send.sh does. With OUT set to a directory, it also saves what the iPhone sees, for review.
# Usage: [OUT=<dir>] e2e-ios-install.sh <image>
set -euo pipefail
IMAGE="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
PLAYWRIGHT=mcr.microsoft.com/playwright:v1.63.0-noble
cleanup() { docker rm -f e2e-ios-bw >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --name e2e-ios-bw -e DEMO_MODE=true -e JMAP_SERVER_URL=https://mail.example.test \
  -e SESSION_SECRET="$(openssl rand -hex 32)" "$IMAGE" >/dev/null
healthy=
for _ in $(seq 1 60); do
  docker exec e2e-ios-bw node -e 'fetch("http://127.0.0.1:3000/api/health").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' 2>/dev/null && { healthy=1; break; }
  sleep 1
done
[ -n "$healthy" ] || { docker logs e2e-ios-bw | tail -20; echo "::error::the image did not become healthy"; exit 1; }

out=()
if [ -n "${OUT:-}" ]; then mkdir -p "$OUT"; out=(-v "$(cd "$OUT" && pwd):/e2e/out"); fi
docker run --rm --network container:e2e-ios-bw -v "$HERE/e2e-ios-install.mjs:/e2e/e2e.mjs:ro" "${out[@]}" \
  "$PLAYWRIGHT" bash -c 'cd /e2e && npm i --silent --no-audit --no-fund playwright-core@1.63.0 >/dev/null && node e2e.mjs http://localhost:3000' \
  || { docker logs e2e-ios-bw 2>&1 | tail -30; exit 1; }
