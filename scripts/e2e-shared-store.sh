#!/usr/bin/env bash
# End-to-end for 0016: two instances of the BUILT image behind no shared volume agree on a user's
# settings and on a pairing code, through upstream's shared store (#1066) on a real PostgreSQL over TLS
# verified against its CA, with a real Stalwart for the sign-in. The client side is e2e-shared-store.mjs.
# Throwaway containers and credentials, removed on exit.
# Usage: e2e-shared-store.sh <image> [shared|separate|upgrade]
#   shared:   SHARED_STORE=postgres on both instances; also checks a wrong CA is refused, loudly, and
#             that the instance holding it stays out of service rather than falling back to its own files.
#   separate: the negative control, both instances WITHOUT SHARED_STORE: each keeps its own settings and
#             its own codes, which is what two pods would do without 0016.
#   upgrade:  the image production runs today (1.11.2-clientip.19, whose 0016 kept settings in the table
#             bulwark_settings) saves a user's settings first; then both instances of this image must load
#             them, byte for byte, from the same database, and keep the old rows under another name.
set -euo pipefail
IMAGE="$1"
EXPECT="${2:-shared}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STALWART=stalwartlabs/stalwart:v0.16.24
CLI=stalwartlabs/cli:1.0.13
PG=postgres:18.4
# What production runs before this upgrade (MainThrive infra/k8s/mail/bulwark.yaml), for the upgrade mode.
OLD_IMAGE=ghcr.io/bill-scheffer/bulwark-client-ip:1.11.2-clientip.19@sha256:9b269be419a60ed34d8610737aa23b45353e781a8b7acfa28de99e92c403a530
NET=e2e-shared
ADMIN_PW="$(openssl rand -hex 16)"
USER_PW="$(openssl rand -hex 16)"
PG_PW="$(openssl rand -hex 16)"
SECRET="$(openssl rand -hex 32)"
DATA=""
NAMES="e2e-ss-stalwart e2e-ss-pg e2e-ss-bw1 e2e-ss-bw2 e2e-ss-bwbad e2e-ss-old"
cleanup() { docker rm -f $NAMES >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; [ -z "$DATA" ] || rm -rf "$DATA" 2>/dev/null || true; }
trap cleanup EXIT
cleanup
DATA="$(mktemp -d)"
mkdir -p "$DATA/etc" "$DATA/data" "$DATA/tls" "$DATA/out"
echo '{"@type":"RocksDb","path":"/var/lib/stalwart/"}' > "$DATA/etc/config.json"
chmod -R 777 "$DATA/etc" "$DATA/data"
docker network create "$NET" >/dev/null

# A private CA and a server certificate for the database's name, as CNPG serves; and a second CA
# that signed nothing, for the refusal.
(
  cd "$DATA/tls"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=e2e-ca -keyout ca.key -out ca.crt 2>/dev/null
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=e2e-other-ca -keyout other.key -out other-ca.crt 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj /CN=e2e-pg -keyout server.key -out server.csr 2>/dev/null
  printf 'subjectAltName=DNS:e2e-pg\n' > san.ext
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile san.ext -out server.crt 2>/dev/null
  chmod 644 ca.crt other-ca.crt
)

docker run -d --name e2e-ss-pg --network "$NET" --network-alias e2e-pg \
  -e POSTGRES_USER=bulwark -e POSTGRES_PASSWORD="$PG_PW" -e POSTGRES_DB=bulwark "$PG" >/dev/null
# Over TCP: the image's first-start init runs a temporary server on the socket only, which a socket check mistakes for ready.
pg_up=
for _ in $(seq 1 60); do docker exec e2e-ss-pg pg_isready -h 127.0.0.1 -U bulwark -d bulwark >/dev/null 2>&1 && { pg_up=1; break; }; sleep 1; done
[ -n "$pg_up" ] || { docker logs e2e-ss-pg | tail -20; echo "::error::the database did not start"; exit 1; }
docker cp "$DATA/tls/server.crt" e2e-ss-pg:/var/lib/postgresql/server.crt
docker cp "$DATA/tls/server.key" e2e-ss-pg:/var/lib/postgresql/server.key
docker exec -u root e2e-ss-pg sh -c 'chown postgres /var/lib/postgresql/server.* && chmod 600 /var/lib/postgresql/server.key'
docker exec e2e-ss-pg psql -qU bulwark -d bulwark -c "ALTER SYSTEM SET ssl = on" \
  -c "ALTER SYSTEM SET ssl_cert_file = '/var/lib/postgresql/server.crt'" \
  -c "ALTER SYSTEM SET ssl_key_file = '/var/lib/postgresql/server.key'" -c "SELECT pg_reload_conf()" >/dev/null
sleep 1
[ "$(docker exec e2e-ss-pg psql -tAU bulwark -d bulwark -c 'SHOW ssl')" = on ] || { echo "::error::the database did not turn TLS on"; exit 1; }

docker run -d --name e2e-ss-stalwart --hostname mail.e2e.test --network "$NET" --network-alias e2e-stalwart \
  -e STALWART_RECOVERY_ADMIN="admin:$ADMIN_PW" \
  -v "$DATA/etc:/etc/stalwart" -v "$DATA/data:/var/lib/stalwart" "$STALWART" >/dev/null
cli() { docker run --rm --network "$NET" -e STALWART_URL=http://e2e-stalwart:8080 -e STALWART_USER=admin \
  -e STALWART_PASSWORD="$ADMIN_PW" "$CLI" --no-color "$@"; }
for _ in $(seq 1 60); do
  docker run --rm --network "$NET" node:24-alpine node -e 'fetch("http://e2e-stalwart:8080/healthz/ready").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' 2>/dev/null && break
  sleep 1
done
domain=$(cli create Domain --json '{"name":"e2e.test","dkimManagement":{"@type":"Manual"},"dnsManagement":{"@type":"Manual"}}' | awk '/Created Domain/ {print $3}')
cli create Account/User --json "{\"name\":\"u\",\"domainId\":\"$domain\",\"credentials\":{\"0\":{\"@type\":\"Password\",\"secret\":\"$USER_PW\"}}}"

# The same environment on every instance, as one Deployment's pods have; only the store differs by mode.
# OAUTH_CLIENT_ID: minting a pairing code needs it (getRequiredConfig); the password sign-in falls back to the same id.
bulwark() {
  local name="$1" ca="$2" image="${3:-$IMAGE}"
  local store=()
  if [ "$EXPECT" != separate ]; then
    store=(-e SHARED_STORE=postgres -e PGHOST=e2e-pg -e PGDATABASE=bulwark -e PGUSER=bulwark -e PGPASSWORD="$PG_PW"
           -e PGSSLROOTCERT=/tls/ca.crt -v "$DATA/tls/$ca:/tls/ca.crt:ro")
  fi
  docker run -d --name "$name" --network "$NET" --network-alias "$name" \
    -e JMAP_SERVER_URL=https://mail.e2e.test -e JMAP_SERVER_INTERNAL_URL=http://e2e-stalwart:8080 \
    -e JMAP_FORWARD_CLIENT_IP=true -e STALWART_FEATURES=true -e COOKIE_SECURE=false \
    -e SETTINGS_SYNC_ENABLED=true -e SESSION_SECRET="$SECRET" -e OAUTH_CLIENT_ID=bulwark-webmail "${store[@]}" "$image" >/dev/null
}
probe() { # name path -> HTTP status
  docker exec -e P="$2" "$1" node -e 'fetch("http://127.0.0.1:3000"+process.env.P).then(r=>console.log(r.status)).catch(()=>console.log(0))'
}
healthy() { # name [path]: live, then (by default) ready, which with a shared store means booted and the store answers
  local path="${2:-/api/ready}"
  for _ in $(seq 1 90); do
    [ "$(probe "$1" "$path")" = 200 ] && return 0
    sleep 1
  done
  docker logs "$1" | tail -20; echo "::error::$1 did not answer 200 on $path"; exit 1
}
client() { # mode -> runs e2e-shared-store.mjs in that mode
  docker run --rm --network "$NET" -u "$(id -u)" -v "$HERE/e2e-shared-store.mjs:/e2e.mjs:ro" -v "$DATA/out:/out" node:24-alpine \
    node /e2e.mjs http://e2e-ss-bw1:3000 http://e2e-ss-bw2:3000 http://e2e-ss-bwbad:3000 http://e2e-stalwart:8080 \
    https://mail.e2e.test u@e2e.test "$USER_PW" "$SECRET" "$1" http://e2e-ss-old:3000 \
    || { for n in e2e-ss-old e2e-ss-bw1 e2e-ss-bw2; do echo "--- $n"; docker logs "$n" 2>&1 | tail -20; done; exit 1; }
}
psql() { docker exec e2e-ss-pg psql -tAU bulwark -d bulwark -c "$1"; }

if [ "$EXPECT" = upgrade ]; then
  # Today's image, on the same database, saves the user's settings into its own table first.
  bulwark e2e-ss-old ca.crt "$OLD_IMAGE"
  healthy e2e-ss-old /api/health
  # It connects after it starts serving, so the line comes a moment after the first 200.
  for _ in $(seq 1 30); do docker logs e2e-ss-old 2>&1 | grep -q 'Shared store: ready (postgres)' && break; sleep 1; done
  docker logs e2e-ss-old 2>&1 | grep -q 'Shared store: ready (postgres)' || { docker logs e2e-ss-old 2>&1 | tail -20; echo "::error::the old image did not report its store ready"; exit 1; }
  client seed-old
  [ "$(psql 'SELECT count(*) FROM bulwark_settings')" = 1 ] || { echo "::error::the old image left no settings row"; exit 1; }
  old_blob=$(psql "SELECT md5(blob) FROM bulwark_settings")
  docker rm -f e2e-ss-old >/dev/null
  echo "the old image saved one settings row (md5 $old_blob) and stopped"
fi

bulwark e2e-ss-bw1 ca.crt
bulwark e2e-ss-bw2 ca.crt
healthy e2e-ss-bw1
healthy e2e-ss-bw2

if [ "$EXPECT" != separate ]; then
  for n in e2e-ss-bw1 e2e-ss-bw2; do
    docker logs "$n" 2>&1 | grep -q 'Using a shared store.*postgres://bulwark@e2e-pg/bulwark' \
      && docker logs "$n" 2>&1 | grep -q 'Shared store ready' \
      || { docker logs "$n" 2>&1 | tail -20; echo "::error::$n did not report the postgres shared store ready"; exit 1; }
  done
  echo "both instances: Shared store ready (postgres://bulwark@e2e-pg/bulwark), over TLS verified against the database's CA"
fi

if [ "$EXPECT" = upgrade ]; then
  [ "$(psql "SELECT to_regclass('bulwark_settings') IS NULL AND to_regclass('bulwark_settings_before_1_21') IS NOT NULL")" = t ] \
    || { echo "::error::the old settings table was not kept under its new name"; exit 1; }
  [ "$(psql "SELECT md5(blob) FROM bulwark_settings_before_1_21")" = "$old_blob" ] || { echo "::error::the kept old row changed"; exit 1; }
  [ "$(psql "SELECT md5(data) FROM bulwark_store_docs WHERE coll = 'settings'")" = "$old_blob" ] \
    || { echo "::error::the carried-over settings document is not the old row's bytes"; exit 1; }
  echo "carried over: the settings document has the old row's bytes, and the old table is kept as bulwark_settings_before_1_21"
  client upgrade
  echo "OK (upgrade)"
  exit 0
fi

if [ "$EXPECT" = shared ]; then
  # A CA that did not sign the database's certificate: the instance waits for its store, says so, and stays out of
  # service (ready 503, the app 503) rather than falling back to its own files.
  bulwark e2e-ss-bwbad other-ca.crt
  healthy e2e-ss-bwbad /api/health
  sleep 8
  [ "$(probe e2e-ss-bwbad /api/ready)" = 503 ] || { echo "::error::an instance with the wrong CA reports ready"; exit 1; }
  docker logs e2e-ss-bwbad 2>&1 | grep -q 'Waiting for the shared store' \
    || { docker logs e2e-ss-bwbad 2>&1 | tail -20; echo "::error::an instance with the wrong CA did not say it is waiting for its store"; exit 1; }
  echo "an instance trusting another CA: waiting for its shared store, not ready, as it should"
fi

client "$EXPECT"

if [ "$EXPECT" = shared ]; then
  # What the database holds: one settings document, and no pairing code or token in clear anywhere in the store.
  n=$(psql "SELECT count(*) FROM bulwark_store_docs WHERE coll = 'settings'")
  echo "settings documents: $n"
  [ "$n" = 1 ] || { echo "::error::expected one settings document, got $n"; exit 1; }
  # The code and the token the client got (written to a file, never printed): neither appears anywhere in the store.
  code=$(cat "$DATA/out/code"); token=$(cat "$DATA/out/token")
  [ ${#code} -ge 16 ] && [ ${#token} -ge 16 ] || { echo "::error::the client left no code or token to look for"; exit 1; }
  clear=$(psql "SELECT (SELECT count(*) FROM bulwark_store_kv WHERE position('$code' in key || value) > 0 OR position('$token' in value) > 0)
    + (SELECT count(*) FROM bulwark_store_docs WHERE position(convert_to('$code', 'UTF8') in data) > 0 OR position(convert_to('$token', 'UTF8') in data) > 0)")
  [ "$clear" = 0 ] || { echo "::error::the store holds the pairing code or the token in clear ($clear rows)"; exit 1; }
  echo "neither the pairing code nor the token is in the store in clear"
fi
echo "OK ($EXPECT)"
