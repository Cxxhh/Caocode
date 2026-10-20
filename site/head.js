// In each page's <head>, before it shows.

// The visitor's language: the page in it, if this one is in the other.
// Chinese for those whose system puts Chinese before English, English for
// anyone else; the language they last picked (the header's link) over
// both. Every page is at /<page> and /zh/<page> but for /import and
// /activate, which the app opens in its own language. Search engines are
// left on the page they asked for, to list each.
(() => {
  const path = location.pathname;
  const zh = path === '/zh' || path.startsWith('/zh/');
  document.addEventListener('click', (event) => {
    const link = event.target.closest?.('a.lang[hreflang]');
    if (link) try { localStorage.setItem('caocode.lang', link.hreflang); } catch {}
  }, true);
  if (/^\/(zh\/)?(import|activate)(\.html)?$/.test(path)) return;
  if (navigator.webdriver || /bot|crawl|spider|slurp|preview|facebookexternalhit/i.test(navigator.userAgent)) return;
  let picked = null;
  try { picked = localStorage.getItem('caocode.lang'); } catch {}
  const system = (navigator.languages || [navigator.language])
    .map((tag) => String(tag).toLowerCase())
    .find((tag) => tag.startsWith('zh') || tag.startsWith('en'));
  const wanted = picked === 'zh' || picked === 'en' ? picked : system?.startsWith('zh') ? 'zh' : 'en';
  if ((wanted === 'zh') === zh) return;
  const there = zh ? path.replace(/^\/zh(\/|$)/, '/') : `/zh${path}`;
  location.replace(there + location.search + location.hash);
})();

// A visitor who may be a listed channel's has the places a channel changes
// (the brand, the home page's title and subtitle) hidden until site.js has
// filled them in, so ours never flash first; and channels.json is asked
// for already. Never hidden for long, whatever happens.
(() => {
  let kept = null;
  try { kept = JSON.parse(localStorage.getItem('caocode.attribution')); } catch {}
  // A channel kept, or one in the address, replacing whatever is.
  if (kept?.source !== 'channel' && location.search.length < 2) return;
  const root = document.documentElement;
  root.classList.add('channel-pending');
  window.channelsJson = fetch('/channels.json').then((res) => res.json()).catch(() => null);
  setTimeout(() => root.classList.remove('channel-pending'), 2000);
})();
