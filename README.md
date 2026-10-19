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

The patch shows the three sections to every session, and no longer shows the two others (their
components stay in the source, unrendered, to keep the patch small).

A password change needs one more thing in a token session: Stalwart revokes the session's access **and**
refresh tokens when the password changes. `keepTokenSessionThrough` runs the change, then signs in again
through `totp-token-exchange` with the new password and the code the change was confirmed with (Stalwart
accepted that code a second time within its window, measured), as `updateBasicPassword` already does for a
password session. From before the change is sent until that sign-in lands, it holds the account's token
refresh: a request that meets the revoked token in between (a push reconnect, a poll) waits for the new
token, where a refresh would have spent the revoked refresh token, been refused, and signed the user out
at once. If the new sign-in is refused, the session ends there as an expired one, and the user signs in
again with the new password. A sign-out during it is respected, as in `refreshAccessToken`.

`stores/__tests__/auth-store-token-password.test.ts` (the sign-in, the held refresh, a refused sign-in, a
refused change, a password session), `components/settings/__tests__/account-security-token-session.test.tsx`
(both session kinds render and load the sections) and one new assertion in
`stores/__tests__/account-security-store.test.ts`. On unpatched 1.11.2 the token-session cases fail.

**Known limits, accepted at review.**
- **Code reuse.** ~~The re-sign-in reuses the confirming code.~~ Superseded by `0014`, below: MainThrive's
  Stalwart now refuses a code a second time, so the re-sign-in asks for the next one.
- **The push preview.** Its server-side token renewal (`/api/push/preview`) cannot see the client's hold. A
  preview that renewed the session in the same second as the change can put the revoked tokens back in the
  slot, and the next refresh then ends the session as expired.
- **The global single-flight.** During the hold it can hand the new token to a non-active account's client,
  as upstream's own single-flight already can.
- **A failed response.** A change whose response fails on the network after the server applied it is treated
  as refused, and the session ends at the next refresh.

## The authenticator entry is named after this webmail (`0012`, `clientip.13`)

[`patches/0012-totp-issuer-is-app-name.patch`](patches/0012-totp-issuer-is-app-name.patch).
Settings → Security builds the two-step enrolment's `otpauth://` URL in the browser, and upstream hardcodes its
issuer as `'Stalwart'`. An authenticator app names the entry after the issuer, so every user who turned two-step
on found an entry called "Stalwart" (MainThrive MAI-936, MAI-947). Stalwart takes the URL as given, so no server
setting can change it.

The patch passes the deployment's own name, `appName` from `/api/config` (the `APP_NAME` variable; MainThrive sets
"MainThrive Mail"), and falls back to upstream's default app name, "Webmail", if the config has not loaded. An
entry already enrolled keeps its old name until the user renames it or enrols again: the issuer is only in the URL.

`components/settings/__tests__/account-security-totp-issuer.test.tsx` turns two-step on in the rendered page and
decodes the URL it shows, as an authenticator app reads it. With the hardcoded issuer put back, all three cases
fail.

## A send on a phone returns to the list (`0013`, `clientip.14`)

[`patches/0013-mobile-send-returns-to-list.patch`](patches/0013-mobile-send-returns-to-list.patch).
On a phone the list, the reading pane and the composer are separate screens, and opening the composer switches to the
reading pane's screen. After a send, upstream closed the composer and left that screen up. For a new message composed
from the list there is nothing on it to read, so the user landed on its empty state, "No conversation selected",
instead of the folder they came from (MainThrive MAI-1010, reported from the installed PWA). Upstream 1.11.2 does this
with none of these patches applied. Upstream already returned to the list after sending a draft that was open on that
screen; nothing else did.

After a send, and after scheduling one, a phone with no message or conversation open goes back to the list. A reply
sent from an open message still returns to that message.

[`scripts/e2e-mobile-send.sh`](scripts/e2e-mobile-send.sh) runs the built image in demo mode (`DEMO_MODE=true`,
fixture data, no mail server) and drives it in a 390 × 844 touch browser: sign in to the demo, compose and send from
the inbox, and the list must be on screen; open a message, reply and send, and the message must still be on screen.
Against upstream 1.11.2 the first half fails. The scheduled-send path shares the fix but is not exercised by the e2e.

## A password change asks for the next code (`0014`, `clientip.15`)

[`patches/0014-password-change-asks-for-the-next-code.patch`](patches/0014-password-change-asks-for-the-next-code.patch).
`0011` kept a two-step session signed in through a password change by signing in again with the new password and the
code the change was confirmed with. MainThrive's Stalwart now accepts a code once (stalwart-r2-patch `0012`, MainThrive
MAI-997, RFC 6238 § 5.2), so that sign-in is refused and the session would end. So once the change is applied, the form
asks for the next code ("Password changed. Stay signed in?"): the user waits for the authenticator to show a new code,
up to 30 seconds, and types it (the button waits for six digits). A refused code (the same one again, or a typo) is
asked for again, saying why, up to three codes, after which the session ends as an expired one, as before `0011`.
"Sign out", or leaving the page while it asks, signs out (not reported as expired). If the user signs out or switches
account while it asks, nothing more happens to that session. Token refreshes
stay held while it asks, so a request in the meantime waits rather than spending the revoked token. A session without
two-step signs in again with the new password alone, as before.

`stores/__tests__/auth-store-token-password.test.ts` (the next code asked for after the change, a refused code asked
for again with a request waiting through it, at most three codes, declining, an account switch while it asks,
another failure, no two-step),
`components/settings/__tests__/account-security-next-code.test.tsx` (the prompt shows after the change, passes on a
six-digit code only, says when one was refused, and passes on nothing when declined, left, or the account changes) and one changed assertion in
`stores/__tests__/account-security-store.test.ts`. With `0014` reverted, the cases that ask for a code fail.

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

## Builds, tags and testing a change before it merges

| What runs `build` | Checks | Pushes |
|---|---|---|
| A pull request to `main` | every check: patches, assertions, tests, the image build, every end-to-end check | **nothing**, and it never logs in to the registry |
| A push to `main`, or a dispatch on `main` | the same | the **release tag**: `<VERSION>`, e.g. `1.11.2-clientip.13` |
| A dispatch from any other branch | the same | **`branch-<short sha>`** only, never the release tag |

`build` is the required check on `main`, so a pull request merges only once it is green.

To run a change on the cluster before it merges (a throwaway or a window test), push the branch, then:

```bash
gh workflow run build.yml -R Bill-Scheffer/bulwark-client-ip --ref <branch>
gh run watch -R Bill-Scheffer/bulwark-client-ip "$(gh run list -R Bill-Scheffer/bulwark-client-ip -w build -b <branch> -L 1 --json databaseId --jq '.[0].databaseId')"
```

The run's summary names the tag and the digest. Pin the image **by digest**
(`ghcr.io/bill-scheffer/bulwark-client-ip@sha256:…`), never by the `branch-` tag, and replace it with the release
digest once the change merges and `main` publishes it. A branch image is never released: only `main` publishes a
release tag, and only once. A tag that already exists is never re-pushed, so a change to what is built must bump
`VERSION`. The build fails a pull request that changes `patches/`, a value in `env:` or a step up to and
including the image build without the bump, and the digest you pin keeps its tag (MainThrive MAI-1021).

A digest pinned without a tag of its own, such as one pinned before that, is protected by tagging it
`pinned-<first 12 hex>`. The workflow copies the manifest as-is and never moves a tag:

```bash
gh workflow run protect-digest.yml -R Bill-Scheffer/bulwark-client-ip -f digest=sha256:<64 hex>
```

## When this goes away

When upstream ships an equivalent, use the upstream image again and archive this repository. The
change is offered upstream.

## Licence

Bulwark is licensed under the AGPL-3.0; this build is offered with its complete corresponding
source: upstream's tagged release plus the patch above, which is the whole of this repository.
