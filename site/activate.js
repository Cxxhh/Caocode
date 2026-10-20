// The channel build's first start: Caocode opens
//
//   https://caocode.dev/activate#i=<install id>
//
// and waits (`&again=<id>` too when it asks once more: its channel not one
// with accounts, the visitor might have come by another since, which this
// browser now keeps). This page sends stats.caocode.dev where the visitor came to
// the site from, as site.js kept it in this browser, and Caocode, asking
// there, goes on. Should Caocode not hear of it (its network, the server
// down), the page hands it over itself: caocode://activate?…, opened or
// pasted into Caocode. Nothing kept in this browser: the link to open in
// the one that came to the site, or on without. The page's words are in
// its HTML (each language's).
(() => {
  const root = document.querySelector('[data-activate]');
  if (!root) return;
  // One link for every language: a Chinese browser goes on to /zh/activate.
  const zh = /^zh\b/i.test(navigator.languages?.[0] || navigator.language || '');
  if (root.dataset.activate === 'en' && zh && location.hash) {
    location.replace(`/zh/activate${location.hash}`);
    return;
  }

  const show = (name) => {
    for (const el of root.querySelectorAll('[data-state]')) el.hidden = el.dataset.state !== name;
    root.querySelector('[data-handover]').hidden = name !== 'done' && name !== 'failed';
  };
  const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  const hash = new URLSearchParams(location.hash.slice(1));
  const id = hash.get('i') || '';
  const again = hash.get('again');
  if (!ID.test(id) || (again != null && !ID.test(again))) {
    show('invalid');
    return;
  }

  let sent = false;
  const send = async (kept) => {
    if (sent) return;
    sent = true;
    const source = kept?.source || 'none';
    const value = kept?.value || null;
    const link = `caocode://activate?i=${id}&s=${source}${value ? `&c=${encodeURIComponent(value)}` : ''}`;
    root.querySelector('[data-open]').href = link;
    root.querySelector('[data-link]').textContent = link;
    show('sending');
    try {
      const ctl = new AbortController();
      setTimeout(() => ctl.abort(), 8000);
      const res = await fetch('https://stats.caocode.dev/v1/attribution', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ v: 1, id, source, value, ...(again ? { again } : {}) }),
        signal: ctl.signal,
      });
      show(res.ok ? 'done' : 'failed');
    } catch {
      show('failed');
    }
  };

  attribution.kept().then((kept) => {
    if (kept) {
      send(kept);
      return;
    }
    root.querySelector('[data-page-link]').textContent = `https://caocode.dev/activate${location.hash}`;
    show('missing');
    root.querySelector('[data-continue]').addEventListener('click', () => send(null));
  });
})();
