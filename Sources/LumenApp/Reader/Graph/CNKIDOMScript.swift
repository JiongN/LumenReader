import Foundation

/// Uses the site's visible form, not obsolete SKey URLs. Runs only on CNKI's main frame.
enum CNKIDOMScript {
    static let read = #"""
    const host = location.hostname.toLowerCase();
    if (location.protocol !== 'https:' || !(host === 'cnki.net' || host.endsWith('.cnki.net'))) return {};
    const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
    const first = (root, selectors) => selectors.flatMap(s => Array.from(root.querySelectorAll(s))).find(visible);
    const text = (e, cap = 1000) => (e?.innerText || '').replace(/\s+/g, ' ').trim().slice(0, cap);
    const body = (document.body?.innerText || '').slice(0, 24000);
    const input = first(document, ['input#txt_search', 'input.search-input', 'input[name="kw"]']);
    const verification = /\/verify\//i.test(location.pathname)
        || /请完成(?:安全)?验证|访问过于频繁|拖动滑块|滑动验证|请输入验证码/.test(body)
        || !!first(document, ['.verify-wrap', '.captcha-box', '#captcha:not(input)']);
    const loginRequired = /请先登录|请登录后检索|登录后(?:才)?可(?:以)?检索/.test(body);
    const noResults = /未检索到|没有找到(?:相关)?(?:文献|结果)|暂无检索结果|无检索结果/.test(body);
    const rows = Array.from(new Set(['.result-table-list tbody tr', '#gridTable tbody tr',
        'table.result-table-list tr'].flatMap(s => Array.from(document.querySelectorAll(s))))).slice(0, 80);
    const papers = [];
    for (const row of rows) {
        const a = first(row, ['td.name a.fz14', 'td.name a', 'a.fz14', '.name a']);
        if (!a || !a.href) continue;
        const authorCell = first(row, ['td.author', '.author']);
        const authorLinks = Array.from(authorCell?.querySelectorAll('a') || []).filter(visible).map(a => text(a, 100));
        const authors = authorLinks.length ? authorLinks : text(authorCell, 1000).split(/[;；、,，]/).filter(Boolean);
        papers.push({title: text(a), url: a.href.slice(0, 8192), authors: authors.slice(0, 20),
            year: text(first(row, ['td.date', '.date']), 40),
            journal: text(first(row, ['td.source', '.source']), 300),
            citations: text(first(row, ['td.quote', '.quote', 'td.cited', '.cited']), 30)});
        if (papers.length === 40) break;
    }
    return {formReady: !!input, verification, loginRequired, noResults, papers};
    """#

    // query is a callAsyncJavaScript argument, never interpolated into executable code.
    static let submit = #"""
    const host = location.hostname.toLowerCase();
    if (location.protocol !== 'https:' || !(host === 'cnki.net' || host.endsWith('.cnki.net'))) return false;
    const visible = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
    const first = selectors => selectors.flatMap(s => Array.from(document.querySelectorAll(s))).find(visible);
    const input = first(['input#txt_search', 'input.search-input', 'input[name="kw"]']);
    const button = first(['input.search-btn', 'button.search-btn', '.search-btn']);
    if (!input || !button) return false;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(input, query);
    input.dispatchEvent(new Event('input', {bubbles: true}));
    input.dispatchEvent(new Event('change', {bubbles: true}));
    button.click();
    return true;
    """#
}
