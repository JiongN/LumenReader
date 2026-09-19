import Foundation

/// Native WebKit CSS columns: one reflowing column or viewport-sized spreads.
enum EPUBLayoutScript {
    static let css = """
    html { overflow-x: hidden; }
    body { width: 100% !important; max-width: none !important; min-width: 0 !important; }
    body > * { max-width: 100% !important; box-sizing: border-box; }
    img, svg { object-fit: contain; }
    a, a:visited { color: var(--lm-accent) !important; }
    pre, table { max-width: 100%; overflow: auto; }
    html.lumen-paged { overflow-x: auto !important; overflow-y: hidden !important; scroll-behavior: auto; }
    html.lumen-paged body {
      box-sizing: border-box !important;
      height: calc(100vh - 56px) !important;
      min-height: 0 !important;
      width: calc(100vw - 56px) !important;
      max-width: none !important;
      margin: 28px !important;
      padding: 0 !important;
      column-count: var(--lm-effective-columns, 1) !important;
      column-gap: 56px !important;
      column-fill: auto !important;
      overflow: visible !important;
    }
    html.lumen-paged img, html.lumen-paged svg { max-height: calc(100vh - 80px); }
    html.lumen-paged figure { break-inside: avoid; }
    """

    static let javascript = #"""
    (() => {
      let anchor = null, anchorTop = 0, resizeFrame = 0, wheelTotal = 0, lastTurn = 0;
      let restoring = false;
      const root = document.documentElement;
      const paged = () => root.classList.contains('lumen-paged');
      const maxX = () => Math.max(0, root.scrollWidth - innerWidth);
      const remember = () => {
        if (restoring) return;
        const x = Math.min(innerWidth / 2, 60), y = 40;
        let candidate = document.elementFromPoint(x, y);
        if (!candidate || candidate === root || candidate === document.body) {
          candidate = Array.from(document.querySelectorAll('p,h1,h2,h3,li,figure')).find(e => {
            const r = e.getBoundingClientRect();
            return r.bottom > 28 && r.top < innerHeight && r.right > 0 && r.left < innerWidth;
          });
        }
        if (candidate && candidate !== document.body && candidate !== root) {
          anchor = candidate;
          anchorTop = candidate.getBoundingClientRect().top;
        }
      };
      const restore = () => {
        if (!anchor || !anchor.isConnected) { remember(); return; }
        restoring = true;
        const rect = anchor.getBoundingClientRect();
        if (paged()) {
          const page = Math.floor(Math.max(0, scrollX + rect.left - 28) / innerWidth);
          window.scrollTo(Math.min(maxX(), page * innerWidth), 0);
        } else {
          window.scrollTo(0, Math.max(0, scrollY + rect.top - anchorTop));
        }
        requestAnimationFrame(() => { restoring = false; remember(); });
      };
      function apply() {
        const style = getComputedStyle(root);
        const usePages = style.getPropertyValue('--lm-paged').trim() === '1';
        const requested = Number(style.getPropertyValue('--lm-columns')) || 1;
        root.style.setProperty('--lm-effective-columns', requested === 2 && innerWidth >= 760 ? '2' : '1');
        root.classList.toggle('lumen-paged', usePages);
        requestAnimationFrame(restore);
      }
      function turn(direction) {
        if (!paged()) { window.scrollBy(0, direction * innerHeight * .85); return true; }
        if ((direction > 0 && scrollX >= maxX() - 2) || (direction < 0 && scrollX <= 2)) return false;
        const target = direction > 0
          ? (Math.floor((scrollX + 2) / innerWidth) + 1) * innerWidth
          : (Math.ceil((scrollX - 2) / innerWidth) - 1) * innerWidth;
        window.scrollTo(Math.max(0, Math.min(maxX(), target)), 0);
        return true;
      }
      window.__lumenLayout = { apply, remember, turn, paged };
      window.addEventListener('scroll', remember, {passive: true});
      window.addEventListener('resize', () => {
        cancelAnimationFrame(resizeFrame);
        resizeFrame = requestAnimationFrame(apply);
      });
      window.addEventListener('wheel', event => {
        if (!paged() || event.ctrlKey || event.metaKey) return;
        event.preventDefault();
        const now = performance.now();
        if (now - lastTurn < 280) return;
        wheelTotal += Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY;
        if (Math.abs(wheelTotal) < 45) return;
        const direction = wheelTotal > 0 ? 1 : -1;
        wheelTotal = 0; lastTurn = now;
        if (!turn(direction)) {
          window.webkit.messageHandlers.lumen.postMessage({type:'turnChapter', direction});
        }
      }, {passive: false});
      document.addEventListener('keydown', event => {
        if (!paged() || event.metaKey || event.altKey || event.ctrlKey || /INPUT|TEXTAREA|SELECT/.test(event.target.tagName) || event.target.isContentEditable) return;
        let direction = 0;
        if (['ArrowRight','PageDown',' '].includes(event.key)) direction = event.shiftKey ? -1 : 1;
        if (['ArrowLeft','PageUp'].includes(event.key)) direction = -1;
        if (!direction) return;
        event.preventDefault();
        if (!turn(direction)) window.webkit.messageHandlers.lumen.postMessage({type:'turnChapter',direction});
      });
      apply();
      document.fonts.ready.then(() => { restore(); remember(); });
      window.addEventListener('load', () => { restore(); remember(); }, {once:true});
      requestAnimationFrame(remember);
    })();
    """#
}
