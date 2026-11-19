#!/usr/bin/env bash
# End-to-end for push previews (upstream #1509, and 0007): a push preview still names the message after the session's access token
# expired. A real Stalwart (access tokens shortened to 70 s) and the BUILT image; the client side is
# e2e-preview-renewal.mjs. Throwaway containers and credentials, removed on exit.
# Usage: e2e-preview-renewal.sh <image> [renews|no-0007]   (no-0007: the negative control, the image without 0007)
set -euo pipefail
IMAGE="$1"
EXPECT="${2:-renews}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STALWART=stalwartlabs/stalwart:v0.16.24
CLI=stalwartlabs/cli:1.0.13
NET=e2e-renewal
ADMIN_PW="$(openssl rand -hex 16)"
USER_PW="$(openssl rand -hex 16)"
DATA=""
cleanup() { docker rm -f e2e-rn-stalwart e2e-rn-bw >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; [ -z "$DATA" ] || rm -rf "$DATA" 2>/dev/null || true; }
trap cleanup EXIT
cleanup
DATA="$(mktemp -d)"
mkdir -p "$DATA/etc" "$DATA/data"
echo '{"@type":"RocksDb","path":"/var/lib/stalwart/"}' > "$DATA/etc/config.json"
chmod -R 777 "$DATA"
docker network create "$NET" >/dev/null

# Stalwart names its OAuth endpoints after its hostname; Bulwark reaches it through the internal
# URL (patch 0001), exactly as in production.
docker run -d --name e2e-rn-stalwart --hostname mail.e2e.test --network "$NET" --network-alias e2e-stalwart \
  -e STALWART_RECOVERY_ADMIN="admin:$ADMIN_PW" \
  -v "$DATA/etc:/etc/stalwart" -v "$DATA/data:/var/lib/stalwart" "$STALWART" >/dev/null
cli() { docker run --rm --network "$NET" -e STALWART_URL=http://e2e-stalwart:8080 -e STALWART_USER=admin \
  -e STALWART_PASSWORD="$ADMIN_PW" "$CLI" --no-color "$@"; }
stalwart_ready() {
  for _ in $(seq 1 60); do
    docker run --rm --network "$NET" node:24-alpine node -e 'fetch("http://e2e-stalwart:8080/healthz/ready").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' 2>/dev/null && return 0
    sleep 1
  done
  echo "::error::Stalwart did not become ready"; exit 1
}
stalwart_ready
# 70 s: longer than upstream's REDEMPTION_KEPT_MS (60 s, lib/oauth/slot-renewal.ts), which hands a renewal to every
# request still carrying the refresh token it spent. With 20 s tokens the second expiry got the first renewal's
# token, already expired; production's last an hour.
cli update OidcProvider singleton --field accessTokenExpiry=70000
# The token lifetime takes effect only after a restart.
docker restart e2e-rn-stalwart >/dev/null
stalwart_ready
domain=$(cli create Domain --json '{"name":"e2e.test","dkimManagement":{"@type":"Manual"},"dnsManagement":{"@type":"Manual"}}' | awk '/Created Domain/ {print $3}')
cli create Account/User --json "{\"name\":\"u\",\"domainId\":\"$domain\",\"credentials\":{\"0\":{\"@type\":\"Password\",\"secret\":\"$USER_PW\"}}}"

docker run -d --name e2e-rn-bw --network "$NET" --network-alias e2e-bw \
  -e JMAP_SERVER_URL=https://mail.e2e.test -e JMAP_SERVER_INTERNAL_URL=http://e2e-stalwart:8080 \
  -e JMAP_FORWARD_CLIENT_IP=true -e STALWART_FEATURES=true -e COOKIE_SECURE=false \
  -e SESSION_SECRET="$(openssl rand -hex 32)" "$IMAGE" >/dev/null
healthy=
for _ in $(seq 1 60); do
  docker exec e2e-rn-bw node -e 'fetch("http://127.0.0.1:3000/api/health").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' 2>/dev/null && { healthy=1; break; }
  sleep 1
done
[ -n "$healthy" ] || { docker logs e2e-rn-bw | tail -20; echo "::error::the image did not become healthy"; exit 1; }

docker run --rm --network "$NET" -v "$HERE/e2e-preview-renewal.mjs:/e2e.mjs:ro" node:24-alpine \
  node /e2e.mjs http://e2e-bw:3000 http://e2e-stalwart:8080 https://mail.e2e.test u@e2e.test "$USER_PW" "$EXPECT" \
  || { docker logs e2e-rn-bw 2>&1 | tail -30; exit 1; }
