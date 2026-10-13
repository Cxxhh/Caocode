// The one-click import of an upstream (docs/upstream-import.md): a site's
// "Import to Caocode" link comes here, what to import after the # —
//
//   https://caocode.dev/import#v=1&name=…&protocol=…&url=…&key=…
//
// which browsers never send to caocode.dev — and goes on to the app as
// caocode://provider/import?…, Caocode asking before it adds anything. The
// fragment is taken off the address bar as soon as it is read, so the key
// is not left in it. The page's words are in its HTML (each language's).
(() => {
  const root = document.querySelector('[data-import]');
  if (!root) return;
  // One link for every site: a Chinese browser goes on to /zh/import, what
  // to import with it (replaced, so Back does not come here again).
  const zh = /^zh\b/i.test(navigator.languages?.[0] || navigator.language || '');
  if (root.dataset.import === 'en' && zh && (location.hash || location.search)) {
    location.replace(`/zh/import${location.search}${location.hash}`);
    return;
  }

  // As written, not as a form would: a + in a key stays a +.
  const read = (text) => {
    const params = new Map();
    for (const part of text.replace(/^[#?]/, '').split('&')) {
      if (!part) continue;
      const at = part.indexOf('=');
      const name = at < 0 ? part : part.slice(0, at);
      const value = at < 0 ? '' : part.slice(at + 1);
      try { params.set(decodeURIComponent(name), decodeURIComponent(value)); } catch {}
    }
    return params;
  };
  // The fragment; the query only for a site that put it there.
  const params = read(location.hash.length > 1 ? location.hash : location.search);
  if (location.hash || location.search) {
    history.replaceState(null, '', location.pathname);
  }

  const protocols = {
    '': 'anthropic', anthropic: 'anthropic',
    'openai-chat': 'openai-chat', 'openai-responses': 'openai-responses',
  };
  const protocol = protocols[params.get('protocol') || ''];
  let base = null;
  try {
    const url = new URL((params.get('url') || '').trim());
    if ((url.protocol === 'https:' || url.protocol === 'http:') && url.host) base = url;
  } catch {}
  const version = params.get('v') || '1';

  const show = (name) => {
    for (const el of root.querySelectorAll('[data-state]')) el.hidden = el.dataset.state !== name;
  };
  if (!protocol || !base || version !== '1') {
    show('invalid');
    return;
  }

  const name = (params.get('name') || '').trim().slice(0, 64) || base.host;
  const key = (params.get('key') || '').trim();
  const masked = !key ? '' : key.length <= 12 ? '•'.repeat(Math.min(key.length, 8))
    : `${key.slice(0, 6)}…${key.slice(-4)}`;
  const set = (field, text) => {
    for (const el of root.querySelectorAll(`[data-field="${field}"]`)) el.textContent = text;
  };
  set('name', name);
  set('host', base.host);
  set('url', base.href.replace(/\/+$/, ''));
  set('protocol', root.querySelector(`[data-protocol-name="${protocol}"]`)?.textContent || protocol);
  set('key', masked || root.querySelector('[data-no-key]')?.textContent || '');

  const query = [
    ['v', '1'], ['name', name], ['protocol', protocol],
    ['url', base.href.replace(/\/+$/, '')], ['key', key],
  ].filter(([, value]) => value)
    .map(([k, value]) => `${k}=${encodeURIComponent(value)}`).join('&');
  const link = `caocode://provider/import?${query}`;
  const open = root.querySelector('[data-open]');
  open.href = link;
  show('ready');

  // Opened, the app takes the focus from the page; still here a moment
  // later, Caocode is most likely not installed: the download comes first.
  let left = false;
  const away = () => { left = true; };
  window.addEventListener('blur', away);
  document.addEventListener('visibilitychange', () => { if (document.hidden) away(); });
  const tryOpen = () => {
    left = false;
    location.href = link;
    setTimeout(() => {
      if (!left) root.querySelector('[data-missing]').hidden = false;
    }, 1600);
  };
  open.addEventListener('click', (event) => {
    event.preventDefault();
    tryOpen();
  });
  tryOpen();
})();
