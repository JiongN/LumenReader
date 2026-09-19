import WebKit

/// 对真实 WebKit 文档做的集成自检（`--epub-layout-report 1`）。
///
/// 三条设计约束，都是从踩过的坑里长出来的：
///
/// 1. **不许并发**。`didFinish` 会为同一份 DOM 触发多次（例如 `--jump-to`
///    先落第一章再跳章），两轮自检同时改 `--lm-paged` / `--lm-columns`
///    会互相覆盖——实测表现是「一次翻页跳了两个视口宽」（2696 = 2×1348），
///    以及 `continuous=false` 这种与设置矛盾的读数。所以同一时刻只许一轮在跑。
///
/// 2. **测应用当下的设置，而不是脚本硬塞的值**。上一版自己写死
///    `--lm-columns=2`，于是 `--epub-columns 1` 也报 `columns:"2"`，
///    「双栏开关到底生效没有」这条最重要的事反而测不到。
///
/// 3. **证据不足就是失败，不许 0 冒充通过**。内容撑不满一屏时
///    `maxScroll=0`，翻页分支整段被跳过，上一版照样 `pass:true`。
///    现在这种情形明确报 `insufficient`，由调用方换一份长文档重跑。
@MainActor enum EPUBLayoutAudit {

    private static var inFlight = false
    /// 已经拿到过一次「证据充分」的读数。之后的重复触发直接跳过：
    /// 同一份 DOM 量第二遍不会更真，只会多一次并发风险。
    private static var satisfied = false

    static func run(webView: WKWebView) async {
        guard !inFlight, !satisfied else {
            NSLog("[Lumen][epub-layout] 跳过：%@", inFlight ? "上一轮仍在跑" : "已取得充分读数")
            return
        }
        inFlight = true
        defer { inFlight = false }

        let script = #"""
        const root = document.documentElement, layout = window.__lumenLayout;
        if (!layout) throw new Error('layout bridge missing');
        const frame = () => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        const saved = {paged: root.style.getPropertyValue('--lm-paged'), columns: root.style.getPropertyValue('--lm-columns'), x: scrollX, y: scrollY};
        const read = key => (root.style.getPropertyValue(key) || '').trim();
        const result = {width: innerWidth};
        try {
          const requested = Number(read('--lm-columns')) || 1;
          const pagedWanted = read('--lm-paged') === '1';
          result.requestedColumns = requested;
          result.pagedWanted = pagedWanted;
          // 双栏有最小宽度门槛（脚本里 760）：窄窗口下要的是单栏，不是「设置失
          // 效」。期望值必须跟着算出来的门槛走，否则窄窗口会永远判失败。
          result.expectedColumns = requested === 2 && innerWidth >= 760 ? 2 : 1;

          layout.apply(); await frame();
          const cc = getComputedStyle(document.body).columnCount;
          // 连续流下 column-count 是 `auto`（不设栏），语义上就是单栏；
          // 直接 Number('auto') 会得到 NaN，读起来像「没量到」。
          result.columnsRaw = cc;
          result.columns = (cc === 'auto' || !cc) ? 1 : Number(cc);
          result.paged = layout.paged();
          result.matchesSetting = result.columns === result.expectedColumns && result.paged === pagedWanted;

          window.scrollTo(0, 0); await frame();
          if (result.paged) {
            const max = Math.max(0, root.scrollWidth - innerWidth);
            result.maxScroll = max;
            result.insufficient = max <= 2;              // 撑不满一屏 → 翻页读数无效
            if (!result.insufficient) {
              result.forward = layout.turn(1); await frame();
              result.forwardX = scrollX;
              result.oneViewport = Math.abs(scrollX - innerWidth) < 3;  // 一次翻一个视口宽，不是随便动一下
              window.scrollTo(Math.max(0, max - 20), 0); await frame();
              result.finalPartial = layout.turn(1); await frame();      // 末页残留也要能翻到底
              result.endReached = Math.abs(scrollX - max) < 3;
              result.endStops = !layout.turn(1);                        // 到底之后不许再翻
              result.backward = layout.turn(-1); await frame();
              result.backwardMoved = scrollX < max;
            }
            result.bodyWidth = document.body.getBoundingClientRect().width;
            result.fillsWidth = Math.abs(result.bodyWidth - (innerWidth - 56)) < 3;  // 双栏有 28pt 页边距
          } else {
            const maxY = Math.max(0, root.scrollHeight - innerHeight);
            result.maxScroll = maxY;
            result.insufficient = maxY <= 2;
            if (!result.insufficient) {
              result.forward = layout.turn(1); await frame();
              result.forwardY = scrollY;
              result.forwardMoved = scrollY > 0;
              result.backward = layout.turn(-1); await frame();
              result.backwardMoved = scrollY < result.forwardY;
            }
            result.horizontal = Math.max(0, root.scrollWidth - innerWidth);
            result.noSideways = result.horizontal <= 2;                 // 连续流不许横向溢出
            result.bodyWidth = document.body.getBoundingClientRect().width;
            result.fillsWidth = Math.abs(result.bodyWidth - innerWidth) < 3;
          }

          result.pass = result.matchesSetting && result.fillsWidth && !result.insufficient
            && (result.paged
              ? (result.forward && result.oneViewport && result.finalPartial
                 && result.endReached && result.endStops && result.backward && result.backwardMoved)
              : (result.forward && result.forwardMoved && result.backward && result.backwardMoved && result.noSideways));
        } finally {
          root.style.setProperty('--lm-paged', saved.paged);
          root.style.setProperty('--lm-columns', saved.columns);
          layout.apply(); await frame();
          window.scrollTo(saved.x, saved.y);
        }
        return JSON.stringify(result);
        """#

        do {
            let value = try await webView.callAsyncJavaScript(
                script, arguments: [:], in: nil, contentWorld: .page)
            let text = value as? String ?? "missing result"
            NSLog("[Lumen][epub-layout] %@", text)
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pass = json["pass"] as? Bool {
                satisfied = pass && (json["insufficient"] as? Bool) != true
            }
        } catch {
            NSLog("[Lumen][epub-layout] FAIL %@", error.localizedDescription)
        }
    }
}
