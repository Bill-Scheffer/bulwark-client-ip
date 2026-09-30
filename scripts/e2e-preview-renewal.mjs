// End-to-end: a push preview still names the message after the session's access token expired.
// Runs against the built image and a real Stalwart whose access tokens last 20 s. A real password
// sign-in through the image, the context sync the app makes, then previews across two expiries.
// Usage: node e2e-preview-renewal.mjs <bulwark url> <stalwart internal url> <JMAP_SERVER_URL> <user> <password> <expect>
// <expect> is "renews" for the patched image, "401" for the negative control (the image before the patch).
const [BW, ST, SERVER, USER, PASS, EXPECT] = process.argv.slice(2);
const SUBJECT = 'e2e preview after expiry';
const fail = (msg) => { console.error(`::error::${msg}`); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A cookie jar that keeps names and values only, as the browser would send them back.
function applySetCookies(jar, res) {
  for (const line of res.headers.getSetCookie()) {
    const [pair, ...attrs] = line.split(';');
    const eq = pair.indexOf('=');
    const name = pair.slice(0, eq).trim();
    const value = pair.slice(eq + 1).trim();
    const expired = attrs.some((a) => /^\s*max-age=0\s*$/i.test(a) || /^\s*expires=thu, 01 jan 1970/i.test(a));
    if (expired || value === '') jar.delete(name); else jar.set(name, value);
  }
}
const cookieHeader = (jar) => [...jar].map(([k, v]) => `${k}=${v}`).join('; ');
const setCookieNames = (res) => res.headers.getSetCookie().map((l) => l.split('=')[0]);

function bw(jar, path, init = {}) {
  return fetch(`${BW}${path}`, {
    ...init,
    headers: { 'content-type': 'application/json', 'sec-fetch-site': 'same-origin', cookie: cookieHeader(jar), ...init.headers },
  });
}

async function jmap(auth, calls) {
  const res = await fetch(`${ST}/jmap/`, {
    method: 'POST',
    headers: { authorization: auth, 'content-type': 'application/json' },
    body: JSON.stringify({ using: ['urn:ietf:params:jmap:core', 'urn:ietf:params:jmap:mail'], methodCalls: calls }),
  });
  if (!res.ok) fail(`JMAP ${res.status}`);
  return (await res.json()).methodResponses;
}

// 1. Sign in with a password, as the login screen does: tokens, with the refresh token in a cookie.
const jar = new Map();
const login = await bw(jar, '/api/auth/totp-token-exchange', {
  method: 'POST', body: JSON.stringify({ serverUrl: SERVER, username: USER, password: PASS, slot: 0 }),
});
applySetCookies(jar, login);
const tokens = await login.json();
if (login.status !== 200 || !tokens.access_token) fail(`sign-in answered ${login.status}`);
if (!jar.has('jmap_rt')) fail('sign-in set no refresh token cookie');
console.log(`signed in; token lasts ${tokens.expires_in}s; cookies: ${[...jar.keys()].join(', ')}`);
if (tokens.expires_in > 60) fail(`the access token lasts ${tokens.expires_in}s; the server's lifetime was not shortened`);

// 2. The app syncs its bearer into the server-side context the preview reads.
const bearer = `Bearer ${tokens.access_token}`;
const ctx = await bw(jar, '/api/auth/stalwart-context', {
  method: 'POST', body: JSON.stringify({ serverUrl: SERVER, username: USER, authHeader: bearer, slot: 0 }),
});
applySetCookies(jar, ctx);
if (ctx.status !== 200) fail(`context sync answered ${ctx.status}: ${await ctx.text()}`);

// 3. A message in the Inbox, for the preview to name.
const session = await (await fetch(`${ST}/jmap/session`, { headers: { authorization: bearer } })).json();
const accountId = session.primaryAccounts['urn:ietf:params:jmap:mail'];
const [[, mb]] = await jmap(bearer, [['Mailbox/query', { accountId, filter: { role: 'inbox' } }, 'm']]);
const [[, created]] = await jmap(bearer, [['Email/set', { accountId, create: { e: {
  mailboxIds: { [mb.ids[0]]: true }, subject: SUBJECT, from: [{ email: 'sender@e2e.test' }],
  bodyValues: { t: { value: 'hello' } }, textBody: [{ partId: 't', type: 'text/plain' }],
} } }, 's']]);
if (!created.created?.e) fail(`could not create the message: ${JSON.stringify(created)}`);

async function getPreview(label, j, { update = true } = {}) {
  const res = await bw(j, `/api/push/preview?accountId=${encodeURIComponent(accountId)}`);
  const names = setCookieNames(res);
  const body = await res.json();
  console.log(`${label}: ${res.status} subject=${JSON.stringify(body.email?.subject)} set-cookie=[${names.join(', ')}]`);
  if (update) applySetCookies(j, res);
  return { status: res.status, body, names };
}

// 4. While the token is fresh, the preview works either way.
let r = await getPreview('fresh token', jar);
if (r.status !== 200 || r.body.email?.subject !== SUBJECT) fail('the preview failed with a fresh token');

// Wait out the token's lifetime; with `auth`, also until Stalwart itself refuses that token.
async function expire(auth) {
  console.log(`waiting ${tokens.expires_in}s for the access token to expire`);
  await sleep(tokens.expires_in * 1000);
  if (!auth) return sleep(2000);
  for (let i = 0; i < 40; i++) {
    const res = await fetch(`${ST}/jmap/session`, { headers: { authorization: auth } });
    if (res.status === 401) return;
    await sleep(500);
  }
  fail('the access token still works after its lifetime; the test would measure nothing');
}
await expire(bearer);

// No refresh token (signed out elsewhere): 401, and nothing deleted.
const bare = new Map([...jar].filter(([k]) => !k.startsWith('jmap_rt')));
r = await getPreview('expired, no refresh token', bare, { update: false });
if (r.status !== 401) fail(`expected 401 without a refresh token, got ${r.status}`);
if (r.names.length) fail(`a failed renewal changed cookies: ${r.names.join(', ')}`);

if (EXPECT === '401') {
  r = await getPreview('expired token, image before the patch', jar);
  if (r.status !== 401) fail(`expected the unpatched image to answer 401, got ${r.status}`);
  console.log('negative control: OK (the image before the patch loses the preview after expiry)');
  process.exit(0);
}

// 5. Expired: two previews at once, as one delivery produces. Both must name the message.
const [a, b] = await Promise.all([getPreview('expired, preview A', jar, { update: false }), getPreview('expired, preview B', jar, { update: false })]);
for (const x of [a, b]) {
  if (x.status !== 200 || x.body.email?.subject !== SUBJECT) fail('a preview after expiry did not name the message');
}
if (!a.names.includes('jmap_stalwart_ctx') && !b.names.includes('jmap_stalwart_ctx')) fail('the renewed session was not stored');
// Keep what the browser would: the answer that stored the renewal.
const stored = await getPreview('expired, stored', jar);
if (stored.status !== 200) fail('the preview failed after the renewal');

// 6. A second expiry: the renewal the browser kept must renew again.
await expire();
r = await getPreview('second expiry', jar);
if (r.status !== 200 || r.body.email?.subject !== SUBJECT) fail('the preview failed after a second expiry');
if (!r.names.includes('jmap_stalwart_ctx')) fail('the second expiry did not renew; the check measured nothing');

// 7. An OAuth sign-in (a TOTP account's) keeps only its 30-day refresh token when a push wakes a phone
// whose browser was killed: no context, no cached token. The preview must rebuild the context from it.
const refreshOnly = new Map([...jar].filter(([k]) => k.startsWith('jmap_rt')));
console.log(`OAuth sign-in; the restarted browser sends: ${[...refreshOnly.keys()].join(', ')}`);
r = await getPreview('OAuth sign-in, context dropped', refreshOnly);
if (r.status !== 200 || r.body.email?.subject !== SUBJECT) fail('the preview did not rebuild a dropped OAuth context from the refresh token');
if (!r.names.includes('jmap_stalwart_ctx')) fail('the rebuilt OAuth context was not stored');

// 8. A remembered ("remember me") sign-in is Basic and has no refresh token. A browser restarted in the
// background keeps its 30-day cookie but drops the session-scoped context; the preview must rebuild it.
const remembered = new Map();
const rs = await bw(remembered, '/api/auth/session', {
  method: 'POST', body: JSON.stringify({ serverUrl: SERVER, username: USER, password: PASS, slot: 0 }),
});
applySetCookies(remembered, rs);
if (rs.status !== 200 || !remembered.has('jmap_session')) fail(`remembered sign-in answered ${rs.status}`);
remembered.delete('jmap_stalwart_ctx');
console.log(`remembered sign-in; the restarted browser sends: ${[...remembered.keys()].join(', ')}`);
r = await getPreview('remembered sign-in, context dropped', remembered);
if (r.status !== 200 || r.body.email?.subject !== SUBJECT) fail('the preview did not rebuild a dropped context from the remembered sign-in');
if (!r.names.includes('jmap_stalwart_ctx')) fail('the rebuilt context was not stored');

console.log('preview renewal: OK');
