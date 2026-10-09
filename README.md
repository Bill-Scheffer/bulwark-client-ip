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

## Why a preview failed

[`patches/0005-push-preview-says-why.patch`](patches/0005-push-preview-says-why.patch). The preview
route answered 401 on several paths without a word, so a generic notification could not be traced:
no session context at all, an expired token with no refresh token, a renewed token the server then
refused, a session that would not open, a probe that threw. Each now logs one warning with the slot
and reason, never a value; the no-session one lists the NAMES of the cookies that arrived.

## Remembered sign-ins

[`patches/0006-push-preview-restores-remembered-session.patch`](patches/0006-push-preview-restores-remembered-session.patch).
0005's first real warning named the cause: `push preview found no session context`, with only
`jmap_session` among the cookies. A "remember me" sign-in is Basic: its credentials sit in that 30-day
cookie, and the context the server routes read is a browser-session cookie. When a push wakes a phone
and its browser comes back from being killed in the background, the session cookie is gone and the
remembered one is not, so the preview answered 401 and the notification was generic. Opening the app
fixed it for a while because the app's own restore (`GET /api/auth/session`) rebuilds the context.
The preview now does the same, through one helper both routes use
(`restoreStalwartAuthContextFromSession`). Nothing new persists: it reads a cookie that already does.
The renewal e2e's last step signs in with "remember me", drops the context cookie, and needs the
preview to answer 200 and store a fresh context; against `clientip.6` it fails there.

## OAuth sign-ins after a restart

[`patches/0007-push-preview-restores-oauth-session.patch`](patches/0007-push-preview-restores-oauth-session.patch).
The same restart leaves an OAuth sign-in (what an account with TOTP gets) with only its 30-day refresh
token: no context, no cached access token, no remembered sign-in. The preview now renews from the
refresh token (0003's exchange), opens the session with the new token, and only then stores the new
token and a rebuilt context (server from the refresh token's own server entry, username from the JMAP
session). The e2e keeps only the refresh-token cookie and needs a 200 preview; against `clientip.7` it
fails there.

## No stability banner on the Files page

[`patches/0008-files-no-stability-banner.patch`](patches/0008-files-no-stability-banner.patch).
Upstream's Files page always shows "Large file uploads can cause server instability…". The risk it
describes is Stalwart on RocksDB (the admin text says so); MainThrive's Stalwart is PostgreSQL + R2,
where a file's bytes go to R2 like a mail attachment's (measured: a 25 MiB file added 48 kB to
Postgres). Stalwart bounds each upload (25 MiB per WebDAV request and per file) and each account (4
requests at once, about 80 MiB of memory per 25 MiB upload in flight). Nothing yet bounds uploads
server-wide, the same as for mail attachments; that is a scaling item with a measured budget, not
something a banner can fix, so the banner goes. The workflow refuses a build whose Files page still
renders it.

## Files upload errors say why (`0009`, `clientip.10`)

[`patches/0009-files-upload-errors-say-why.patch`](patches/0009-files-upload-errors-say-why.patch).
The Files page uploads through JMAP (blob upload, then `FileNode/set`), and the client already throws
the server's description; the page discarded it and showed "Failed to upload file" for everything.
With MainThrive's Stalwart (stalwart-r2-patch 0004) a refused file now reads, for example, "Failed to
upload file: The file contains malware.", "...: The file could not be scanned for malware; try again
later." or "...: The file is larger than the 25 MB limit." No new translation key: the reason is the
server's, appended to the existing message. The workflow refuses a build where either upload handler
drops it.

## Sign-ins survive an outage (`0010`, `clientip.11`)

[`patches/0010-restore-keeps-session-through-outage.patch`](patches/0010-restore-keeps-session-through-outage.patch).
On a page load the app restores each remembered account, and any error it did not recognise as an
outage removed the account and deleted its remembered sign-in: the user saw "session expired" and had
to type the password again. It recognised a network failure and a 5xx, but not the two errors a
server outage behind a load balancer also produces: a request that timed out (30 s), and a fetch that
failed while a second probe got through, which the client reports as `CORS_ERROR`. MainThrive's
node-loss drill (2026-10-04) signed a user out exactly this way during a refresh. Both now keep the
account, marked "Server unreachable", and it reconnects when the server answers. A real rejection
(401) still signs out. The cost: a PERMANENT CORS misconfiguration now also keeps the session, so the
user sees a stuck "Server unreachable" state instead of the sign-in screen (which never fixed it
either). No credential is exposed by that: the remembered sign-in stays in its cookie as before. `stores/__tests__/auth-store-restore-outage.test.ts`
fails on unpatched 1.11.2 for exactly the two new cases and passes its three controls (a network
failure, a 502, a real rejection).

## Two-step sign-ins keep their account security (`0011`, `clientip.12`)

[`patches/0011-token-session-keeps-account-security.patch`](patches/0011-token-session-keeps-account-security.patch).
A sign-in with a two-step code goes through Stalwart's token login, so the session is a token
(`authMode: 'oauth'`) session. Upstream's Settings → Security showed such a session no Change Password,
no Display Name and no Two-Factor Authentication: a user who turned two-step on could no longer change
their password or turn two-step off. Instead it showed Email Client Setup (a "JMAP Username" for JMAP
clients) and Link Mobile App (a QR code for upstream's own mobile app), neither of which MainThrive
offers. Measured on a throwaway of MainThrive's Stalwart (v0.16.25 build) with a bearer token minted the
way `totp-token-exchange` mints one: the display name, a password change (with the current code, which
the form already sends) and turning two-step off and on again all succeed.

The patch shows the three sections to every session, and removes the two others. One more thing makes
a password change work for a token session: Stalwart revokes the session's access **and** refresh
tokens when the password changes, so the session would end on its next request. After the change it now
signs in again through `totp-token-exchange` with the new password and the code the change was
confirmed with (Stalwart accepted that code a second time within its window, measured), as
`updateBasicPassword` already does for a password session. If that sign-in is refused, the session ends
as before and the user signs in again. `stores/__tests__/auth-store-token-password.test.ts`,
`components/settings/__tests__/account-security-token-session.test.tsx` and one new assertion in
`stores/__tests__/account-security-store.test.ts`: five fail on unpatched 1.11.2, and the password
session's own render case passes on both.

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
Node 22 host) when 0003 was, and the same two when 0011 was (4862 passed; both fail identically with
0011 reverted).

Image: `ghcr.io/bill-scheffer/bulwark-client-ip:<bulwark tag>-clientip.N`. Pin it by digest.

## When this goes away

When upstream ships an equivalent, use the upstream image again and archive this repository. The
change is offered upstream.

## Licence

Bulwark is licensed under the AGPL-3.0; this build is offered with its complete corresponding
source: upstream's tagged release plus the patch above, which is the whole of this repository.
