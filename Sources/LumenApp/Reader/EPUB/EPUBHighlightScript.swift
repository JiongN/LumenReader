import Foundation

/// Match normalized quotes while retaining exact UTF-16 offsets in the original DOM.
/// Inline formatting never inserts a synthetic space or creates separate highlight caps.
enum EPUBHighlightScript {
    static let source = #"""
    window.__lumenHighlights = {
      apply: function (id, quote, hex) {
        var norm = function (s) { return String(s || '').replace(/\s+/g, ' ').trim(); };
        var target = norm(quote);
        if (!target || !document.body) return false;
        if (Array.from(document.querySelectorAll('mark.lumen-hl')).some(function (m) {
          return m.getAttribute('data-lumen-id') === id;
        })) return true;

        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
          acceptNode: function (node) {
            if (node.nodeType === Node.ELEMENT_NODE) {
              if (node.matches('script,style,noscript,.lm-tr,[hidden]')) return NodeFilter.FILTER_REJECT;
              return node.tagName === 'BR' ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
            }
            return node.parentElement && !node.parentElement.closest('script,style,noscript,.lm-tr,[hidden]')
              ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
          }
        });
        var entries = [], raw = '', previousBlock = null, node;
        while ((node = walker.nextNode())) {
          if (node.nodeType === Node.ELEMENT_NODE) { raw += '\n'; continue; }
          if (!node.nodeValue) continue;
          var parent = node.parentElement;
          var block = parent.closest('p,li,td,th,dd,dt,figcaption,h1,h2,h3,h4,h5,h6,pre,blockquote')
            || parent.closest('div,section,article') || document.body;
          if (previousBlock && previousBlock !== block) raw += '\n';
          var start = raw.length;
          raw += node.nodeValue;
          entries.push({node: node, block: block, start: start, end: raw.length});
          previousBlock = block;
        }

        // One mapping segment per whitespace/word run, rather than an object per
        // character. Leading indentation and collapsed whitespace keep raw offsets.
        var normalized = '', segments = [], re = /\s+|\S+/g, match;
        while ((match = re.exec(raw))) {
          var space = /^\s/.test(match[0]);
          if (space && !normalized) continue;
          var piece = space ? ' ' : match[0];
          segments.push({start: normalized.length, end: normalized.length + piece.length,
            rawStart: match.index, rawEnd: re.lastIndex, space: space});
          normalized += piece;
        }
        var index = normalized.indexOf(target);
        if (index < 0) return false;
        function rawPosition(position, end) {
          var point = end ? position - 1 : position, low = 0, high = segments.length - 1;
          while (low <= high) {
            var mid = (low + high) >> 1, s = segments[mid];
            if (point < s.start) high = mid - 1;
            else if (point >= s.end) low = mid + 1;
            else return s.space ? (end ? s.rawEnd : s.rawStart)
              : s.rawStart + point - s.start + (end ? 1 : 0);
          }
          return -1;
        }
        var first = rawPosition(index, false), last = rawPosition(index + target.length, true);
        if (first < 0 || last <= first) return false;
        var groups = [];
        entries.forEach(function (entry) {
          if (entry.end <= first || entry.start >= last) return;
          if (!entry.node.nodeValue.slice(Math.max(0, first - entry.start), last - entry.start).trim()) return;
          var group = groups[groups.length - 1];
          if (!group || group.block !== entry.block) {
            group = {block: entry.block, first: entry, last: entry};
            groups.push(group);
          } else group.last = entry;
        });
        // Each paragraph has one wrapper containing its existing inline elements.
        // Work backwards so splitting a text node cannot invalidate an earlier range.
        for (var i = groups.length - 1; i >= 0; i--) {
          var g = groups[i], range = document.createRange();
          range.setStart(g.first.node, Math.max(0, first - g.first.start));
          range.setEnd(g.last.node, Math.min(g.last.node.length, last - g.last.start));
          var mark = document.createElement('mark');
          mark.className = 'lumen-hl';
          mark.setAttribute('data-lumen-id', id);
          if (/^#[0-9a-fA-F]{6}$/.test(hex)) {
            var rgb = [1,3,5].map(function (offset) { return parseInt(hex.slice(offset,offset + 2),16); });
            mark.style.setProperty('--lm-highlight-rgb', rgb.join(', '));
          }
          mark.appendChild(range.extractContents());
          range.insertNode(mark);
        }
        return groups.length > 0;
      }
    };
    """#
}
