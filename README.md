# bulwark-client-ip

[Bulwark](https://github.com/bulwarkmail/webmail) built from its own release source (**1.21.2**) with eight small
changes for MainThrive's webmail. The first, and the reason this repository exists, makes a mail server behind it see
each visitor's real IP address on server-side requests.

| Patch | What it does | Upstream main checked (1d9b3cd41, 2026-11-18) |
|---|---|---|
| `0001` | server-side JMAP requests go to a private URL and carry the visitor's IP, failing closed | not there: upstream forwards the address on some routes since 1.16, but sends nothing when it has none |
| `0002` | the push relay is a build argument (ours), never the hosted one | not there: the Dockerfile still passes no relay argument |
| `0004` | the notification badge has its own image | not there: `#1516` is the app-icon unread badge, a different thing |
| `0005` | the push preview says why it answered 401 | not there: those 401s are still silent |
| `0007` | the preview rebuilds a two-step sign-in whose browser restarted | not there: upstream rebuilds a remembered Basic sign-in only |
| `0015` | the Install card shows iPhone and iPad Safari the Add to Home Screen steps | not there: the card still waits for `beforeinstallprompt` |
| `0016` | upstream's shared store on PostgreSQL | not there: the store is still local or Redis |
| `0017` | no "Link mobile app" card | MainThrive's own choice, not an upstream gap |

## Retired patches (MainThrive MAI-1442, at 1.21.2)

Each was checked against upstream's source at 1.21.2 before it was dropped, and the behaviour it gave is in an
end-to-end check below where one applies.

| Patch | Upstream now | Where |
|---|---|---|
| `0003` push preview renews an expired token | the preview renews with the slot's refresh token, one redemption shared per process, deleting nothing on a refusal | `#1509`, `lib/stalwart/push-token-renewal.ts`; `e2e-preview-renewal.sh` steps 4-6 |
| `0006` push preview restores a remembered sign-in | `readPushAuthContext` rebuilds it from the 30-day cookie | `lib/stalwart/push-auth-context.ts`; `e2e-preview-renewal.sh` step 8 |
| `0008` no Files stability banner | the banner is gone | `d07939fc0` (1.14) |
| `0009` Files upload errors say why | the toast carries the server's reason, and each refused file is reported | `components/files/files-app.tsx` `failureReason` |
| `0010` a sign-in survives an outage | the restore treats a timeout and `CORS_ERROR` as an outage | `#1167` (1.14), the same test file name |
| `0011` two-step sign-ins keep their account security | a password plus two-step sign-in is a password session and shows Change Password and Two-step | `#1432`, `lib/auth/password-session.ts` |
| `0012` the authenticator entry is named after this webmail | a branded `APP_NAME` is the TOTP issuer | `#1160`, `lib/totp-issuer.ts` |
| `0013` a send on a phone returns to the list | every send path returns a phone to the list | 1.14; `e2e-mobile-send.sh` kept as the check |
| `0014` a password change asks for the next code | upstream signs a token session out after a password change instead; the next sign-in takes a fresh code, which Stalwart's one-time codes need | `#1432`. MainThrive chose upstream's behaviour (MAI-1442) |

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


⚠️ Since 1.16 upstream also sets `X-Forwarded-For` on its sign-in, preview and DAV calls (`lib/auth/client-address.ts`).
0001 replaces whatever a caller set, so the value is still the one it derives, and there is never a second. Upstream
sends nothing for a loopback or unknown address, so the mail server would count that against this pod's own address;
0001 sends `192.0.2.1` there. Stalwart 1.0 reads the header only with `Http.clientIpSource = xForwardedFor` and
`forwardedHops = 1`, and answers 400 to a loopback address, which 0001 never sends.

## The push relay (`0002`)

[`patches/0002-push-relay-build-arg.patch`](patches/0002-push-relay-build-arg.patch). Upstream reads
`NEXT_PUBLIC_PUSH_RELAY_URL` at build time (`lib/push-relays.ts`), but its Dockerfile never passes it, so an image
always offers the hosted relay. The patch adds the build argument, and this build sets it to our relay. Since 1.20 the
hosted relay's host name also sits in upstream's lists of outside hosts, which name it and never call it, so
`scripts/e2e.sh` checks that no built file holds the hosted relay's URL.

## The notification badge (`0004`)

[`patches/0004-notification-badge.patch`](patches/0004-notification-badge.patch). A notification carries two images:
the icon, and the badge Android shows in the status bar. Bulwark uses the PWA icon for both. Android draws the badge
from its alpha channel alone, so an icon with an opaque background (which a maskable icon must have) shows as a solid
square. `PWA_BADGE_URL` names a separate image, a transparent silhouette; the service worker asks for
`/api/pwa-icon/192?purpose=badge`, which serves it, and falls back to the PWA icon when it is unset. 1.21's service
worker shows four kinds of notification (new mail, its fallback, the silent re-show Safari needs, and the mailto focus),
and all four ask for the badge. [`scripts/e2e-badge.sh`](scripts/e2e-badge.sh) checks the built image: with it set the
badge is its own image and the icon is unchanged, the shipped service worker names the badge URL four times and the
plain icon never, and without it the badge is the icon.

## Why a preview failed (`0005`)

[`patches/0005-push-preview-says-why.patch`](patches/0005-push-preview-says-why.patch). The preview answers 401, and
the phone shows "You have new mail", on paths that log nothing: no session for the account the push names, no session
context at all, and a session the mail server would not open. Each now logs one warning, never a value: the slot and
status, or the names of the cookies that came. Upstream already logs a failed renewal.

## Two-step sign-ins after a restart (`0007`)

[`patches/0007-push-preview-restores-oauth-session.patch`](patches/0007-push-preview-restores-oauth-session.patch). A
password plus two-step sign-in runs on tokens. When a push wakes a phone whose browser was killed in the background,
its refresh token, sign-in stamp and server cookie are still there (they persist), but the context cookie ended with
the browser session, and upstream rebuilds only a remembered Basic sign-in, so the notification was generic. For one
login at most (the one the push names, by the account its stamp records, or the only one there is), the preview now
renews from the refresh token under the same rules upstream's own renewal applies (`renewPushAuthHeader`: the stamp,
the maximum session length, limits only a page enforces, the issuing server), keeps the rotated tokens, opens the
session, and only then writes the rebuilt context. It sends nothing to the mail server that upstream's renewal does not.
`e2e-preview-renewal.sh` step 7 keeps only the cookies a browser keeps across a restart and needs a 200; its
`no-0007` mode runs the same image without 0007 and needs that step, and only that step, to fail.

## The Install card on an iPhone (`0015`)

[`patches/0015-ios-safari-install-steps.patch`](patches/0015-ios-safari-install-steps.patch). The Install card appears
when the browser fires `beforeinstallprompt`, and Safari on an iPhone or iPad never does. In iOS Safari, and only while
the page is not already open from the Home Screen, the card shows the steps instead of an Install button, once the user
has signed in: Share (from ⋯ on an iPhone, at the top on an iPad), Add to Home Screen, then Add, leaving Open as Web App
on where Safari shows it. The first step's arrow bounces toward Safari's toolbar. It follows upstream's own rules for
the card: "Not now" holds it back for a week, an organisation that turned the install prompt off gets none,
and it stays out of the way while a message is being written. Don't remind me again is a button like Not now
(MainThrive MAI-1181). `components/__tests__/pwa-install-prompt-ios.test.tsx` fails on every case against upstream's
component; [`scripts/e2e-ios-install.sh`](scripts/e2e-ios-install.sh) checks the built image in WebKit as an iPhone and
Chrome as an Android phone.

## Upstream's shared store on PostgreSQL (`0016`)

[`patches/0016-shared-store-postgres.patch`](patches/0016-shared-store-postgres.patch). Since 1.20 upstream keeps every
piece of server state that several instances must agree on behind one interface (`lib/shared-store`, `#1066`): synced
settings, pairing and mobile hand-off codes, the device-wipe registry, the stale-credential refusal budget, login
limits, the scheduler lease. Its backends are local files and memory, or one Redis URL. The patch adds a third,
`lib/shared-store/postgres.ts`, selected by `SHARED_STORE=postgres` and connecting with the standard `PG*` variables;
nothing upstream calls changes.

| Table (`bulwark_store_…`) | Holds |
|---|---|
| `kv` | short-lived values, with an expiry by the database's clock |
| `counters` | fixed-window limits, by the caller's clock, as upstream's limiters count |
| `docs` | durable documents (settings among them), with a version that changes on every write |
| `logs` | append-only logs, one writer's lines in order and a batch never split |
| `leases`, `epochs`, `replicas` | coordination: who runs the background jobs, which area changed, which instances are alive |

Every check-then-write is one statement or one transaction, as each is one Lua script for Redis. TLS is verified:
against `PGSSLROOTCERT` when set (CloudNativePG's CA), else the system's CAs; `PGSSLMODE=disable` is for tests. ⛔ **It
fails closed**: an unreachable database is upstream's `StoreUnavailableError`, never a fallback to local files, and an
instance that cannot reach it at start waits, logging `Waiting for the shared store`, and is not ready (`/api/ready`
503) until it can. Each instance logs `Using a shared store` with `postgres://<user>@<host>/<db>` and `Shared store ready`.
The only dependency added is `pg` (8.23.1, with `@types/pg`).

⭐ **On its first start it carries over what the earlier 0016 kept.** That patch stored each settings blob in
`bulwark_settings`, under the same id upstream's settings use (`sha256` of `user:server`) and in the same bytes. The new
store copies each row into a `settings` document, then renames the old table `bulwark_settings_before_1_21`, under the
same advisory lock as the schema, so the copy runs once and the old rows stay as they were. The earlier pairing codes
lived minutes and are not carried over.

`lib/shared-store/__tests__/postgres-store.test.ts` runs upstream's own store contract (`contract.ts`, the one the
Redis backend is held to, with three instances standing in for replicas) against a real PostgreSQL, plus the
carry-over, and the build runs it; with any of the locks, the absent-only insert or the per-writer log order taken
out, a contract case fails. [`scripts/e2e-shared-store.sh`](scripts/e2e-shared-store.sh) runs the built image with a
real Stalwart and a real PostgreSQL over TLS with a private CA. `shared`: a save on each instance is what the other
loads, a pairing code minted on one redeems on the other once, an instance trusting another CA stays out of service
and answers 503, and neither the code nor the token is in the store in clear. `separate`, the store off, is the
negative control. `upgrade`: the image production ran before (`1.11.2-clientip.19`) saves a user's settings; both
instances of this one then load them, the document is the old row byte for byte, and the old table is kept
(MainThrive MAI-1406, MAI-1442).

## No "Link mobile app" (`0017`)

[`patches/0017-no-link-mobile-app.patch`](patches/0017-no-link-mobile-app.patch). Settings > Security offers a QR code
that pairs Bulwark's own phone app. MainThrive neither documents nor supports that app, so the card is not shown, on
either layout of the page. Mail apps are set up from upstream's Email client setup card, which stays. Upstream's
`link-device-section.test.tsx` cases that rendered the card now check it is absent (MainThrive MAI-1442).

## Verified

The workflow fails unless the patches change exactly their files and each patch's own line is in place; it runs the
patches' tests and the suites they touch, upstream's store contract against a real PostgreSQL, and the typecheck; then
it builds the image and runs every end-to-end check above against it, [`scripts/e2e.sh`](scripts/e2e.sh) first (a stub
stands in for the JMAP server: the pre-check reaches the internal URL with the visitor's IP, or `192.0.2.1`, and the
same image without the variables does not reach it). Only then is the image pushed.

Image: `ghcr.io/bill-scheffer/bulwark-client-ip:<bulwark tag>-clientip.N`. Pin it by digest.

## Builds, tags and testing a change before it merges

| What runs `build` | Checks | Pushes |
|---|---|---|
| A pull request to `main` | every check: patches, assertions, tests, the image build, every end-to-end check | **nothing**, and it never logs in to the registry |
| A push to `main`, or a dispatch on `main` | the same | the **release tag**: `<VERSION>`, e.g. `1.21.2-clientip.20` |
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

Each patch goes when upstream ships an equivalent: check upstream main before carrying one to a new release, as the
table at the top records. When none is left, use the upstream image again and archive this repository.

## Licence

Bulwark is licensed under the AGPL-3.0; this build is offered with its complete corresponding source: upstream's
tagged release plus the patches above, which are the whole of this repository.
