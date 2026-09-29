#!/usr/bin/env bash
# End-to-end proof against the BUILT image, which unit tests cannot give: that the wrapper survives
# Next.js's own fetch patching in the standalone server. A stub stands in for the JMAP server and
# records what reaches it; a real sign-in pre-check is sent through the image.
set -euo pipefail
IMAGE="$1"
cleanup() { docker rm -f e2e-echo e2e-bw e2e-bw-off >/dev/null 2>&1 || true; docker network rm e2e >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker network create e2e >/dev/null
docker run -d --name e2e-echo --network e2e node:24-alpine node -e '
  require("http").createServer((q, s) => {
    console.log(JSON.stringify({ method: q.method, url: q.url, xff: q.headers["x-forwarded-for"] || null, auth: !!q.headers.authorization }));
    s.writeHead(401, { "content-type": "application/json" }); s.end("{}");
  }).listen(8080)' >/dev/null

start() { # name, extra env...
  local name=$1; shift
  docker run -d --name "$name" --network e2e -e JMAP_SERVER_URL=https://mail.example.test \
    -e SESSION_SECRET="$(openssl rand -hex 32)" "$@" "$IMAGE" >/dev/null
  for _ in $(seq 1 60); do
    docker exec "$name" node -e 'fetch("http://127.0.0.1:3000/api/health").then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))' 2>/dev/null && return 0
    sleep 1
  done
  docker logs "$name" | tail -20; echo "::error::$name did not become healthy"; exit 1
}
verify() { # name [xff] -> the route's JSON answer; xff defaults to 203.0.113.9, "none" sends no header
  local xff=${2:-203.0.113.9}
  docker exec -e XFF="$xff" "$1" node -e '
    const h = { "content-type": "application/json", "sec-fetch-site": "same-origin" };
    if (process.env.XFF !== "none") h["x-forwarded-for"] = process.env.XFF;
    fetch("http://127.0.0.1:3000/api/auth/verify", { method: "POST",
      headers: h,
      body: JSON.stringify({ serverUrl: "https://mail.example.test", username: "u@example.test", password: "wrong" }) })
    .then(r => r.text()).then(t => console.log(t))'
}

echo "== patched, opted in"
start e2e-bw -e JMAP_SERVER_INTERNAL_URL=http://e2e-echo:8080 -e JMAP_FORWARD_CLIENT_IP=true
docker logs e2e-bw 2>&1 | grep -F "[jmap-upstream]" || { echo "::error::wrapper did not report installing"; exit 1; }
answer=$(verify e2e-bw); echo "verify -> $answer"
sleep 1
seen=$(docker logs e2e-echo 2>&1)
echo "stub saw: $seen"
echo "$answer" | grep -q '"unauthorized"' || { echo "::error::expected unauthorized from the stub's 401"; exit 1; }
echo "$seen" | grep -q '"url":"/.well-known/jmap"' || { echo "::error::the request did not reach the internal URL"; exit 1; }
echo "$seen" | grep -q '"xff":"203.0.113.9"' || { echo "::error::the visitor IP was not forwarded"; exit 1; }
echo "$seen" | grep -q '"auth":true' || { echo "::error::Authorization was not passed through"; exit 1; }

echo "== fails closed: no visitor IP, or an internal one, must reach the stub as 192.0.2.1, never nothing"
for xff in none 10.42.0.9; do
  n0=$(docker logs e2e-echo 2>&1 | wc -l)
  answer=$(verify e2e-bw "$xff"); echo "verify (xff=$xff) -> $answer"
  sleep 1
  last=$(docker logs e2e-echo 2>&1 | tail -n +$((n0+1)))
  echo "stub saw: $last"
  echo "$last" | grep -q '"xff":"192.0.2.1"' || { echo "::error::xff=$xff did not become the 192.0.2.1 sentinel"; exit 1; }
done

echo "== negative control: same image, NOT opted in, must not touch the stub"
before=$(docker logs e2e-echo 2>&1 | wc -l)
start e2e-bw-off
docker logs e2e-bw-off 2>&1 | grep -F "[jmap-upstream]" && { echo "::error::wrapper installed without opting in"; exit 1; }
answer=$(verify e2e-bw-off); echo "verify -> $answer"
sleep 1
after=$(docker logs e2e-echo 2>&1 | wc -l)
[ "$before" = "$after" ] || { echo "::error::the stub was reached without opting in"; exit 1; }
echo "e2e: OK"
