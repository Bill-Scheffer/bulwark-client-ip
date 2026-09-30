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

## Push previews after the session expires

[`patches/0003-push-preview-renews-expired-session.patch`](patches/0003-push-preview-renews-expired-session.patch).
When a push arrives, the service worker asks `/api/push/preview` for the new message's sender and
subject. That route calls the JMAP server with the credential saved in the session. For a password or
OAuth sign-in the credential is an OAuth access token, and only the **open app** renews it. Stalwart's
tokens last an hour, so an hour after the app was last open every notification reads
"You have new mail": the preview gets a 401 and the worker falls back to generic text.

With the patch, when that credential is a `Bearer` token and the JMAP server answers 401, the route
spends the session's refresh token (the exchange `PUT /api/auth/token` already makes for the app, now
one shared function in `lib/oauth/refresh-slot.ts`), retries, and stores the new token and session
only once the retry has worked. Three rules keep it safe:

- Two previews for one delivery share **one** refresh, keyed by the refresh token.
- A failed refresh here **deletes nothing**. The preview answers 401 as before, and the app's own
  renewal decides what the failure means.
- A `Basic` credential never triggers a refresh.

## The notification badge

[`patches/0004-notification-badge.patch`](patches/0004-notification-badge.patch). A notification
carries two images: the icon, and the badge Android shows in the status bar. Bulwark used the PWA
icon for both. Android draws the badge from its alpha channel alone, so an icon with an opaque
background (which a maskable icon must have, and the manifest offers the PWA icon as maskable) shows
as a solid square. `PWA_BADGE_URL` names a separate image, a transparent silhouette; the service
worker asks for `/api/pwa-icon/192?purpose=badge`, which serves it, and falls back to the PWA icon
when it is unset. [`scripts/e2e-badge.sh`](scripts/e2e-badge.sh) checks the built image: with it set
the badge is its own image and the icon is unchanged, the shipped service worker asks for the badge
URL, and without it the badge is the icon. Against `clientip.4` it fails.

## Verified

The workflow fails unless the patch changes exactly its three files; it runs the patch's 15 unit
tests and the typecheck; and it runs [`scripts/e2e.sh`](scripts/e2e.sh) against the **built image**
(a stub stands in for the JMAP server): the pre-check must reach the internal URL carrying the
visitor's IP, and the same image without the variables must not reach it at all. Only then is the
image pushed.

For 0003, the workflow also runs the preview and token routes' suites, and
[`scripts/e2e-preview-renewal.sh`](scripts/e2e-preview-renewal.sh): a real Stalwart with 20-second
access tokens and the built image. A real password sign-in and the app's session sync, then previews:
across an expiry (two at once), across a second expiry with the cookies the first renewal stored, and
without a refresh token (401, and no cookie changed). The script's negative control (`401`) run
against the image before this patch (`clientip.3`) reproduces the failure: 200 while the token is
fresh, 401 after.

Upstream's full suite passes with the patches applied except tests that fail on unpatched 1.11.2
too: `health-route` and `idn` when 0001 was measured, and `health-route` and `birthday-calendar` (on a
Node 22 host) when 0003 was.

Image: `ghcr.io/bill-scheffer/bulwark-client-ip:<bulwark tag>-clientip.N`. Pin it by digest.

## When this goes away

When upstream ships an equivalent, use the upstream image again and archive this repository. The
change is offered upstream.

## Licence

Bulwark is licensed under the AGPL-3.0; this build is offered with its complete corresponding
source: upstream's tagged release plus the patch above, which is the whole of this repository.
