// End-to-end for 0016, the client side of e2e-shared-store.sh: one user signed in to two instances
// of the built image, with a real Stalwart and (shared) a real PostgreSQL.
//   1. Settings: a save on each instance is what the OTHER instance loads.
//   2. Pairing: a code minted on instance 1 redeems on instance 2, once, and never again on either.
//   3. (shared) An instance whose store refused the database's certificate answers 503, not "no settings".
//   seed-old: sign in on today's image (1.11.2-clientip.19) and save a marker; upgrade: both instances of this
//   image load that marker, then agree on a new save.
// Usage: node e2e-shared-store.mjs <bw1> <bw2> <bw-bad-ca> <stalwart internal url> <JMAP_SERVER_URL> <user> <password> <SESSION_SECRET> <shared|separate|seed-old|upgrade> <old>
const [BW1, BW2, BWBAD, ST, SERVER, USER, PASS, SECRET, EXPECT, OLD] = process.argv.slice(2);
const SHARED = EXPECT === 'shared';
const fail = (msg) => { console.error(`::error::${msg}`); process.exit(1); };

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
function call(base, jar, path, init = {}) {
  return fetch(`${base}${path}`, {
    ...init,
    headers: { 'content-type': 'application/json', 'sec-fetch-site': 'same-origin', cookie: cookieHeader(jar), ...init.headers },
  });
}

// 1. Sign in on instance 1 with a password, as the login screen does, and sync the context the
// settings route checks. The cookies are AES-GCM under the shared SESSION_SECRET, so instance 2
// accepts them as they are: that part needs no store, which is why sessions need no stickiness.
const jar = new Map();
const FIRST = EXPECT === 'seed-old' ? OLD : BW1;
const login = await call(FIRST, jar, '/api/auth/totp-token-exchange', {
  method: 'POST', body: JSON.stringify({ serverUrl: SERVER, username: USER, password: PASS, slot: 0 }),
});
applySetCookies(jar, login);
const tokens = await login.json();
if (login.status !== 200 || !tokens.access_token) fail(`sign-in answered ${login.status}`);
const ctx = await call(FIRST, jar, '/api/auth/stalwart-context', {
  method: 'POST', body: JSON.stringify({ serverUrl: SERVER, username: USER, authHeader: `Bearer ${tokens.access_token}`, slot: 0 }),
});
applySetCookies(jar, ctx);
if (ctx.status !== 200) fail(`context sync answered ${ctx.status}: ${await ctx.text()}`);
console.log(`signed in on ${FIRST}; cookies: ${[...jar.keys()].join(', ')}`);

// 2. Settings: each instance saves a different value, and each must load the other's.
async function save(base, value) {
  const res = await call(base, jar, '/api/settings', {
    method: 'POST', body: JSON.stringify({ username: USER, serverUrl: SERVER, settings: { e2eMarker: value } }),
  });
  return res.status;
}
async function load(base) {
  const res = await call(base, jar, '/api/settings', { headers: { 'x-settings-username': USER, 'x-settings-server': SERVER } });
  return { status: res.status, settings: res.status === 200 ? (await res.json()).settings : null };
}
if (EXPECT === 'seed-old') {
  if (await save(OLD, 'from-1.11') !== 200) fail('the old image: settings save failed');
  const back = await load(OLD);
  if (back.settings?.e2eMarker !== 'from-1.11') fail(`the old image did not load its own save: ${JSON.stringify(back)}`);
  console.log('the old image saved and loaded its marker');
  process.exit(0);
}
if (EXPECT === 'upgrade') {
  // The same user, its cookies minted by this image under the same SESSION_SECRET: both instances must load what
  // the old image saved, which the first start carried over.
  for (const [name, base] of [['instance 1', BW1], ['instance 2', BW2]]) {
    const got = await load(base);
    console.log(`${name} loads after the upgrade: ${got.status} ${JSON.stringify(got.settings)}`);
    if (got.status !== 200 || got.settings?.e2eMarker !== 'from-1.11') fail(`${name} lost the settings the old image saved`);
  }
  if (await save(BW2, 'after-upgrade') !== 200) fail('instance 2: a save after the upgrade failed');
  if ((await load(BW1)).settings?.e2eMarker !== 'after-upgrade') fail('instance 1 did not load the save instance 2 made after the upgrade');
  console.log('e2e-shared-store: OK (upgrade)');
  process.exit(0);
}
if (await save(BW1, 'from-1') !== 200) fail('instance 1: settings save failed');
const on2 = await load(BW2);
console.log(`saved on 1, loaded on 2: ${on2.status} ${JSON.stringify(on2.settings)}`);
if (await save(BW2, 'from-2') !== 200) fail('instance 2: settings save failed');
const on1 = await load(BW1);
console.log(`saved on 2, loaded on 1: ${on1.status} ${JSON.stringify(on1.settings)}`);
if (SHARED) {
  if (on2.settings?.e2eMarker !== 'from-1') fail('instance 2 did not load what instance 1 saved');
  if (on1.settings?.e2eMarker !== 'from-2') fail('instance 1 did not load what instance 2 saved');
} else {
  // Before 0016: each instance has only its own file.
  if (on2.settings !== null) fail(`separate: instance 2 loaded ${JSON.stringify(on2.settings)}, expected nothing`);
  if (on1.settings?.e2eMarker !== 'from-1') fail('separate: instance 1 lost its own save');
}

// 3. Pairing. Minting a code needs a step-up: the password again, sent here as the Link mobile app section would
// (lib/auth/pair-grant.ts). The code is shown on the desktop and redeemed by the phone.
const minted = await call(BW1, jar, '/api/auth/pair/create', {
  method: 'POST', body: JSON.stringify({ slot: 0, password: PASS, webmail_base: BW1 }),
});
applySetCookies(jar, minted);
const mintBody = await minted.json();
if (minted.status !== 200 || typeof mintBody.pairing_code !== 'string' || !mintBody.pairing_code) fail(`pair create on 1 answered ${minted.status}: ${JSON.stringify(Object.keys(mintBody))}`);
console.log('minted a pairing code on instance 1');
import('node:fs').then((fs) => fs.writeFileSync('/out/code', mintBody.pairing_code));

// The phone has no webmail cookies: the code is its only credential.
const redeem = (base) => call(base, new Map(), '/api/auth/pair/redeem', { method: 'POST', body: JSON.stringify({ pairing_code: mintBody.pairing_code }) });
const r2 = await redeem(BW2);
const r2Body = await r2.json();
console.log(`redeemed on instance 2: ${r2.status}`);
if (SHARED) {
  if (r2.status !== 200 || !r2Body.access_token) fail(`instance 2 did not redeem the code instance 1 minted: ${r2.status} ${JSON.stringify(r2Body)}`);
  // The tokens it handed over are real: Stalwart opens a session on them.
  const session = await fetch(`${ST}/jmap/session`, { headers: { authorization: `Bearer ${r2Body.access_token}` } });
  if (session.status !== 200) fail(`the redeemed access token was refused by Stalwart: ${session.status}`);
  console.log('the redeemed access token opens a JMAP session');
  (await import('node:fs')).writeFileSync('/out/token', r2Body.access_token);
  const again1 = await redeem(BW1);
  const again2 = await redeem(BW2);
  console.log(`redeemed again: on 1 ${again1.status}, on 2 ${again2.status}`);
  if (again1.status === 200 || again2.status === 200) fail('a redeemed code was accepted a second time');
} else {
  if (r2.status === 200) fail(`separate: instance 2 answered ${r2.status} for a code it never minted`);
  const r1 = await redeem(BW1);
  console.log(`redeemed on instance 1, which minted it: ${r1.status}`);
  if (r1.status !== 200) fail('separate: instance 1 could not redeem its own code');
}

// 4. A store that refused the database is an error, never "no settings" and never a local file.
if (SHARED) {
  const bad = await load(BWBAD);
  const badSave = await save(BWBAD, 'bad');
  console.log(`the wrong-CA instance: load ${bad.status}, save ${badSave}`);
  // Upstream's boot gate: an instance whose store never answered serves nothing but its probes (503).
  if (bad.status !== 503 || badSave !== 503) fail('the wrong-CA instance did not fail closed');
  const after = await load(BW1);
  if (after.settings?.e2eMarker !== 'from-2') fail('the wrong-CA instance changed the shared settings');
}
console.log(`e2e-shared-store: OK (${EXPECT})`);
