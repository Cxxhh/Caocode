// caocode.dev's Worker: site/ is served as static assets, and this runs only
// for /dl/* (run_worker_first in wrangler.jsonc). /dl/windows, /dl/macos-arm64,
// /dl/macos-x64, /dl/linux-x64 and /dl/linux-arm64 redirect to that build of
// the release in latest.json, and
// /dl/android and /dl/ios to the phone app's in releases/mobile/latest.json, so
// a page's links work before site.js swaps them, and without it: a page
// cached by a browser, a fetch of the manifest too slow or blocked.
// /dl/browser-extension redirects to the browser extension's zip, and
// /dl/chrome-web-store to its page in the store (releases/extension/
// latest.json's store), or, that not read, to the page its id makes.

const MANIFEST = 'https://dl.caocode.dev/releases/latest.json';
const MOBILE_MANIFEST = 'https://dl.caocode.dev/releases/mobile/latest.json';
const EXTENSION_MANIFEST = 'https://dl.caocode.dev/releases/extension/latest.json';
const MOBILE = new Set(['android', 'ios']);
// The phone app is off the site for now: its links go to the download page
// instead of to a build. False brings them back.
const MOBILE_OFFLINE = true;
const EXTENSION = new Set(['browser-extension', 'chrome-web-store']);
const EXTENSION_ID = 'jfjagocghaaheooicmdnhcholmgdkngk';

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    const os = pathname.match(/^\/dl\/([a-z0-9-]+)\/?$/)?.[1];
    if (!os) return env.ASSETS.fetch(request);
    if (MOBILE.has(os) && MOBILE_OFFLINE) {
      return new Response(null, {
        status: 302,
        headers: { Location: '/download', 'Cache-Control': 'no-store' },
      });
    }
    let manifest;
    try {
      const url = MOBILE.has(os) ? MOBILE_MANIFEST : EXTENSION.has(os) ? EXTENSION_MANIFEST : MANIFEST;
      const res = await fetch(url, { cf: { cacheTtl: 60, cacheEverything: true } });
      if (res.ok) manifest = await res.json();
    } catch {}
    if (os === 'chrome-web-store') {
      return new Response(null, {
        status: 302,
        headers: { Location: manifest?.store || `https://chromewebstore.google.com/detail/${manifest?.id || EXTENSION_ID}`, 'Cache-Control': 'no-store' },
      });
    }
    const file = manifest?.downloads?.[os];
    if (!file?.url) {
      const [status, text] = manifest ? [404, 'Not found'] : [502, 'The release could not be read; try again shortly.'];
      return new Response(text, { status, headers: { 'Cache-Control': 'no-store' } });
    }
    return new Response(null, {
      status: 302,
      headers: { Location: file.url, 'Cache-Control': 'no-store' },
    });
  },
};
