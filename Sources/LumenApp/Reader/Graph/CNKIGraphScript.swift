import Foundation

enum CNKIGraphScript {
    // Observe only the three relation responses made by this visible article page.
    // No extra authenticated requests, cookie export, or CAPTCHA interaction.
    static let capture = #"""
    (() => {
      if (window.top !== window || location.protocol !== 'https:' ||
          !(location.hostname === 'cnki.net' || location.hostname.endsWith('.cnki.net'))) return;
      if (window.__lumenRelations) return;
      const state = window.__lumenRelations = {entries: new Map()};
      const allowed = value => {
        try {
          const u = new URL(value, location.href);
          return u.protocol === 'https:' && !u.username && !u.password && (!u.port || u.port === '443') &&
            (u.hostname === 'cnki.net' || u.hostname.endsWith('.cnki.net')) &&
            /^\/(restapi\/citation-api\/v1\/literature\/(references|citations)|openapi\/usercenter-api\/v1\/recommend\/similar\/articles)\/?$/.test(u.pathname);
        } catch { return false; }
      };
      const save = (url, body) => {
        if (body.length > 524288 || !allowed(url)) return;
        const key = new URL(url, location.href).pathname.replace(/\/$/, '');
        state.entries.set(key, {endpoint: new URL(url, location.href).href, page: location.href, body});
      };
      const observe = async response => {
        if (!response.ok || !allowed(response.url)) return;
        if (Number(response.headers?.get('content-length')) > 524288) return;
        try {
          const copy = response.clone(), reader = copy.body?.getReader();
          if (!reader) return;
          const decoder = new TextDecoder(); let size = 0, text = '';
          while (true) {
            const {done, value} = await reader.read();
            if (done) break;
            size += value.byteLength;
            if (size > 524288) { await reader.cancel(); return; }
            text += decoder.decode(value, {stream: true});
          }
          text += decoder.decode(); save(response.url, text);
        } catch { /* A failed observer must not affect the site's own request. */ }
      };
      const fetch = window.fetch;
      window.fetch = function(...args) {
        const result = fetch.apply(this, args);
        result.then(response => { void observe(response); }, () => {});
        return result;
      };
      const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      const urls = new WeakMap();
      XMLHttpRequest.prototype.open = function(method, url, ...args) {
        urls.set(this, String(url)); return open.call(this, method, url, ...args);
      };
      XMLHttpRequest.prototype.send = function(...args) {
        const url = urls.get(this);
        if (allowed(url)) this.addEventListener('load', () => {
          if (this.status < 200 || this.status >= 300 || !allowed(this.responseURL)) return;
          if (Number(this.getResponseHeader('content-length')) > 524288) return;
          try { save(this.responseURL, this.responseType === 'json' ? JSON.stringify(this.response) : this.responseText); } catch {}
        }, {once: true});
        return send.apply(this, args);
      };
    })();
    """#

    static let read = #"""
    const valid = location.protocol === 'https:' &&
      (location.hostname === 'cnki.net' || location.hostname.endsWith('.cnki.net'));
    if (!valid) return {};
    const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
    const meta = name => Array.from(document.querySelectorAll('meta')).filter(e => e.name === name).slice(0,20)
      .map(e => e.content.slice(0,1000).trim());
    const heading = Array.from(document.querySelectorAll('.wx-tit h1, article h1, h1')).find(visible);
    const title = (meta('citation_title')[0] || heading?.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 1000);
    const entries = window.__lumenRelations?.entries;
    const first = entries instanceof Map ? entries.entries().next().value : null;
    if (first) entries.delete(first[0]);
    const raw = first?.[1];
    const receipt = raw && typeof raw.endpoint === 'string' && raw.endpoint.length <= 8192 &&
      typeof raw.page === 'string' && raw.page.length <= 8192 &&
      typeof raw.body === 'string' && raw.body.length <= 524288
      ? {endpoint:raw.endpoint, page:raw.page, body:raw.body} : null;
    return {title, authors: meta('citation_author').map(value => value.slice(0,100)),
      year: (meta('citation_publication_date')[0] || '').slice(0, 40),
      doi: (meta('citation_doi')[0] || '').slice(0, 300),
      receipt};
    """#

    static let focus = #"""
    const valid = location.protocol === 'https:' &&
      (location.hostname === 'cnki.net' || location.hostname.endsWith('.cnki.net'));
    if (!valid) return {found: false};
    const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
    const exact = /^(引文网络|知识网络|文献网络|网络图谱|知网节)$/;
    const safe = e => {
      const href = e.getAttribute('href') || '';
      if (!href || href.startsWith('#') || href.startsWith('javascript:')) return true;
      try { const u = new URL(href,location.href); return u.protocol === 'https:' && !u.username && !u.password &&
        (!u.port || u.port === '443') && (u.hostname === 'cnki.net' || u.hostname.endsWith('.cnki.net')); } catch { return false; }
    };
    const entry = (typeof openGraph === 'undefined' || openGraph)
      ? Array.from(document.querySelectorAll('a,button,[role="tab"]')).find(e => visible(e) && safe(e) && exact.test(e.innerText.trim())) : null;
    if (entry) { entry.scrollIntoView({block:'center', behavior:'instant'}); entry.click(); }
    const tab = Array.from(document.querySelectorAll('li[data-id], [role="tab"][data-id]'))
      .find(e => visible(e) && e.getAttribute('data-id') === relation);
    if (tab) { tab.scrollIntoView({block:'center', behavior:'instant'}); tab.click(); }
    return {found: !!(entry || tab), destination: entry?.getAttribute('href') ? (entry.href || null) : null};
    """#
}
