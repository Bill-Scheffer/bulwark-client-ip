#!/usr/bin/env bash
# End-to-end for 0004 against the BUILT image: the notification badge has its own image. With
# PWA_BADGE_URL set, /api/pwa-icon/192?purpose=badge serves it while the plain URL still serves the
# PWA icon, and the shipped service worker asks for the badge URL. Without it, the badge is the icon.
set -euo pipefail
IMAGE="$1"
cleanup() { docker rm -f e2e-badge e2e-badge-off >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

start() { # name, extra env...
  local name=$1; shift
  docker run -d --name "$name" -e JMAP_SERVER_URL=https://mail.example.test -e SESSION_SECRET="$(openssl rand -hex 32)" \
    -e PWA_ICON_URL=/icon-512x512.png "$@" "$IMAGE" >/dev/null
  for _ in $(seq 1 60); do
    docker exec "$name" node -e 'fetch("http://127.0.0.1:3000/api/health").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' 2>/dev/null && return 0
    sleep 1
  done
  docker logs "$name" | tail -20; echo "::error::$name did not become healthy"; exit 1
}
# sha256 of each URL's body, "status:hash", one per line
hashes() {
  docker exec "$1" node -e '
    const crypto = require("crypto");
    (async () => {
      for (const p of process.argv.slice(1)) {
        const r = await fetch("http://127.0.0.1:3000" + p);
        const b = Buffer.from(await r.arrayBuffer());
        console.log(r.status + ":" + crypto.createHash("sha256").update(b).digest("hex"));
      }
    })()' /api/pwa-icon/192 "/api/pwa-icon/192?purpose=badge" /icon-maskable-dark-512x512.png
}

echo "== with PWA_BADGE_URL: the badge is its own image, the icon is unchanged"
start e2e-badge -e PWA_BADGE_URL=/icon-maskable-dark-512x512.png
mapfile -t on < <(hashes e2e-badge)
echo "icon ${on[0]}  badge ${on[1]}"
[ "${on[0]%%:*}" = 200 ] && [ "${on[1]%%:*}" = 200 ] || { echo "::error::the icon routes did not answer 200"; exit 1; }
[ "${on[0]}" != "${on[1]}" ] || { echo "::error::the badge is the same image as the icon"; exit 1; }

echo "== the shipped service worker asks for the badge URL, in both of its notifications"
sw=$(docker exec e2e-badge node -e 'fetch("http://127.0.0.1:3000/sw.js").then(r=>r.text()).then(t=>process.stdout.write(t))')
n_badge=$(grep -cF 'badge: `${BASE_PATH}/api/pwa-icon/192?purpose=badge`' <<<"$sw" || true)
n_plain=$(grep -cF 'badge: `${BASE_PATH}/api/pwa-icon/192`,' <<<"$sw" || true)
echo "badge lines naming ?purpose=badge: $n_badge; naming the plain icon: $n_plain"
[ "$n_badge" = 2 ] && [ "$n_plain" = 0 ] || { echo "::error::the service worker does not ask for the badge URL"; exit 1; }

echo "== without PWA_BADGE_URL: the badge falls back to the icon"
start e2e-badge-off
mapfile -t off < <(hashes e2e-badge-off)
echo "icon ${off[0]}  badge ${off[1]}"
[ "${off[0]}" = "${off[1]}" ] || { echo "::error::without PWA_BADGE_URL the badge is not the icon"; exit 1; }
[ "${off[0]}" = "${on[0]}" ] || { echo "::error::the icon changed with PWA_BADGE_URL set"; exit 1; }
echo "e2e badge: OK"
