# bulwark-client-ip

[Bulwark](https://github.com/bulwarkmail/webmail) built from its own release source with **one**
change, so that a mail server behind it sees each visitor's real IP address on server-side requests.

## The problem

Bulwark's server calls the JMAP server on a visitor's behalf: the login pre-check
(`/api/auth/verify`), the session route, calendar and WebDAV discovery, push previews. Those calls
come from the webmail server's own address and carry nothing about the visitor. The JMAP server's
authentication limiter (Stalwart's auto-ban) then counts **every visitor's wrong password against one
shared address**. Past its threshold it bans that address, and webmail sign-in stops working for
everyone. Upstream's `lib/auth/verify-budget.ts` describes exactly this and caps the pre-check (5 per
client, 30 overall, per 15 minutes); that softens it, but 30 per 15 minutes is still far above a
typical daily ban threshold, and the session route has no budget.

## The change

[`patches/0001-forward-client-ip-to-jmap.patch`](patches/0001-forward-client-ip-to-jmap.patch):
`lib/server/jmap-upstream-fetch.ts`, installed from `instrumentation.node.ts`, wraps the server's
`fetch` **only for requests whose origin is `JMAP_SERVER_URL`'s**, and only when opted in:

| Variable | Effect |
|---|---|
| `JMAP_SERVER_INTERNAL_URL` | send those requests to this private base URL instead (e.g. `http://stalwart:8080`) |
| `JMAP_FORWARD_CLIENT_IP=true` | add `X-Forwarded-For: <visitor IP>`, derived exactly as Bulwark's `getClientIP()` (`TRUSTED_PROXY_DEPTH`); anything that is not a literal IP is never forwarded, and a caller-supplied value is always replaced |

⛔ **It fails closed.** A request sent to the internal URL always carries an `X-Forwarded-For`, and never an internal address: when no public visitor IP is known (no request context, a malformed header, an address in `10.0.0.0/8` or loopback, or forwarding off) it carries `192.0.2.1` (TEST-NET-1). Omitting the header would make the JMAP server fall back to the socket peer, this app's own private address, and a check that trusts private addresses (an API key restricted to the pod network) would pass for a request from outside.

Nothing else is touched: other destinations, and user-chosen custom endpoints (which use a separate,
guarded fetch path), are unchanged. Unset, the image behaves exactly like upstream. ⚠️ The JMAP server
must trust `X-Forwarded-For` from this app (Stalwart: `useXForwarded`) and be reachable only by peers
that cannot forge it.

## Verified

The workflow fails unless the patch changes exactly its three files; it runs the patch's 15 unit
tests and the typecheck; and it runs [`scripts/e2e.sh`](scripts/e2e.sh) against the **built image**
(a stub stands in for the JMAP server): the pre-check must reach the internal URL carrying the
visitor's IP, and the same image without the variables must not reach it at all. Only then is the
image pushed. Upstream's full suite passes with the patch applied except two tests that fail on
unpatched 1.11.2 too (`health-route`, `idn`).

Image: `ghcr.io/bill-scheffer/bulwark-client-ip:<bulwark tag>-clientip.N`. Pin it by digest.

## When this goes away

When upstream ships an equivalent, use the upstream image again and archive this repository. The
change is offered upstream.

## Licence

Bulwark is licensed under the AGPL-3.0; this build is offered with its complete corresponding
source: upstream's tagged release plus the patch above, which is the whole of this repository.
