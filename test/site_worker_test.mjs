import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(new URL('../site-worker/index.js', import.meta.url), 'utf8');
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const standard = 'https://github.com/Cxxhh/Caocode/releases/download/v1.5.6c/Caocode-1.5.6c-setup.exe';
const channelBuild = 'https://downloads.example/channel.exe';
const manifest = { downloads: { windows: { url: standard, channel: { url: channelBuild } } } };

test('desktop downloads preserve the manifest URL and only set attribution for a valid channel', async (t) => {
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  globalThis.fetch = async () => Response.json(manifest);
  const env = {
    ASSETS: { fetch: async () => Response.json({ partner: { account: { url: 'https://partner.example' } } }) },
  };

  const plain = await worker.fetch(new Request('https://caocode.example/dl/windows'), env);
  assert.equal(plain.status, 302);
  assert.equal(plain.headers.get('location'), standard);
  assert.equal(plain.headers.get('set-cookie'), null);

  const known = await worker.fetch(new Request('https://caocode.example/dl/windows?ch=Partner'), env);
  assert.equal(known.headers.get('location'), channelBuild);
  const cookie = known.headers.get('set-cookie');
  const attribution = JSON.parse(decodeURIComponent(cookie.match(/^attribution=([^;]+)/)[1]));
  assert.equal(attribution.source, 'channel');
  assert.equal(attribution.value, 'partner');
  assert.ok(Number.isFinite(Date.parse(attribution.at)));
  assert.match(cookie, /Path=\/;.*Secure; SameSite=Lax/);
  assert.doesNotMatch(cookie, /baocode\.dev/);

  const unknown = await worker.fetch(new Request('https://caocode.example/dl/windows?ch=unlisted'), env);
  assert.equal(unknown.headers.get('location'), standard);
  assert.ok(unknown.headers.get('set-cookie'));

  const invalid = await worker.fetch(new Request('https://caocode.example/dl/windows?ch=bad%2Fchannel'), env);
  assert.equal(invalid.headers.get('location'), standard);
  assert.equal(invalid.headers.get('set-cookie'), null);
});

test('missing or unavailable manifests do not redirect to a different release', async (t) => {
  const originalFetch = globalThis.fetch;
  t.after(() => { globalThis.fetch = originalFetch; });
  globalThis.fetch = async () => Response.json({ downloads: {} });
  const missing = await worker.fetch(new Request('https://caocode.example/dl/windows'), {});
  assert.equal(missing.status, 404);
  globalThis.fetch = async () => { throw new Error('offline'); };
  const offline = await worker.fetch(new Request('https://caocode.example/dl/windows?ch=partner'), {});
  assert.equal(offline.status, 502);
  assert.equal(offline.headers.get('set-cookie'), null);
});

test('non-download routes still use the static asset binding', async () => {
  const request = new Request('https://caocode.example/zh/');
  const response = new Response('site');
  assert.equal(await worker.fetch(request, { ASSETS: { fetch: (seen) => {
    assert.equal(seen, request);
    return response;
  } } }), response);
});
