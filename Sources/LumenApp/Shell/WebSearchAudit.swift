import Foundation
import LumenKit

/// 联网文献检索自检：`--websearch-report 1`（**真实联网**，必须与 `--capture` 同用）。
///
/// 与 `--agent-report` 里那次检索的分工：`--agent-report` 关心的是
/// 「检索结果进没进提示词、顺序对不对」，那是**拼装**层的问题；
/// 这条通道关心的是**取数**本身——三个源现在到底通不通、各出了几条、耗时多少。
///
/// 为什么要单独一条：`WebLiteratureSearch` 的三个依赖都是**外部服务**，
/// 它们的可用性会随时间变化（Semantic Scholar 就是这样被判出局的：
/// 连测两次都 429，于是换成 OpenAlex）。「今天通」不代表「下个月通」，
/// 所以这条通道要能随时单独重跑，而不必顺带跑一遍 Agent 拼装。
///
/// 断言指向**外部可核对的产物**：真的发出 HTTP 请求、真的解析响应，
/// 而不是把检索函数换成桩——换成桩的话，源挂了自检照样全绿。
enum WebSearchAudit {

    /// 固定查询词。刻意选一个**跨库都有存量**的学术词组：
    /// 用冷门词会因为「确实没有文献」而失败，那时红的自检并不表示代码坏了——
    /// 那是不可判定的失败，等于给自检掺了噪声。
    static let query = "Bourdieu cultural capital education"

    static func run() async {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failures.append(name) }
            NSLog("[Lumen][websearch] \(ok ? "✅" : "❌") \(name)"
                  + (ok || detail.isEmpty ? "" : " —— \(detail)"))
        }

        NSLog("[Lumen][websearch] 查询词「\(query)」（真实联网，超时 10s/源）")

        // ① 逐源：命中数 / 失败原因 / 耗时。
        //
        // 「多少个源出了结果」比「总共几条」重要得多——三个源里挂两个、
        // 只剩一个在撑，从总数上完全看不出来（照样是十几条）。
        var sourcesWithHits: [String] = []
        /// 失败（或空结果）的源名，用来核对它们有没有被如实上报
        var failedNames: [String] = []

        for source in Self.sources {
            let started = Date()
            let result = await source.fetch(query)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)

            switch result {
            case .success(let hits):
                NSLog("[Lumen][websearch]   \(source.name)：命中 \(hits.count) 条，耗时 \(elapsed)ms")
                for hit in hits.prefix(3) {
                    NSLog("[Lumen][websearch]     · \(hit.title.prefix(60))"
                          + " — \(hit.authors.prefix(30)) \(hit.year) \(hit.identifier)")
                }
                if hits.isEmpty {
                    failedNames.append(source.name)
                } else {
                    sourcesWithHits.append(source.name)
                }
            case .failure(let error):
                NSLog("[Lumen][websearch]   \(source.name)：失败 \(error.localizedDescription)，耗时 \(elapsed)ms")
                failedNames.append(source.name)
            }
        }

        NSLog("[Lumen][websearch] 出结果的源：\(sourcesWithHits.isEmpty ? "无" : sourcesWithHits.joined(separator: "、"))")
        if !failedNames.isEmpty {
            NSLog("[Lumen][websearch] 失败或空结果的源：\(failedNames.joined(separator: "、"))")
        }
        check("至少一个源检索到文献", !sourcesWithHits.isEmpty,
              "全部失败：\(failedNames.joined(separator: "、"))")

        // ② 聚合：去重之后的真实总数。走的是**请求时那条路**（`search`），
        //    因此这里的数字就是模型会看到的规模。
        let started = Date()
        let outcome = await WebLiteratureSearch.search(query: query)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        NSLog("[Lumen][websearch] 聚合检索：去重后 \(outcome.hits.count) 条，"
              + "失败 \(outcome.failures.count) 个源，耗时 \(elapsed)ms")
        for failure in outcome.failures {
            NSLog("[Lumen][websearch]   源失败：\(failure)")
        }
        check("去重后总命中 ≥ 3 条", outcome.hits.count >= 3,
              "实际 \(outcome.hits.count) 条")

        // ③ 每条都要带得回可核查的出处：这是「引用可核查」这条承诺的底线，
        //    没有 DOI / 编号的条目，模型写出来读者也验不了。
        let withIdentifier = outcome.hits.filter { !$0.identifier.isEmpty }
        NSLog("[Lumen][websearch] 带 DOI/编号的条目 \(withIdentifier.count)/\(outcome.hits.count)")
        if !outcome.hits.isEmpty {
            check("命中条目都带可核查的出处",
                  withIdentifier.count == outcome.hits.count,
                  "缺出处的 \(outcome.hits.count - withIdentifier.count) 条")
        }

        // ④ 失败必须**如实上报**而不是被吞掉。
        //
        //    判定基准是**②这次聚合检索自己的产物**：哪个源在这次聚合里缺席
        //    （一条都没贡献），它就必须出现在 failures 里——缺席只有两种可能
        //    （请求失败 / 命中为零），无论哪种都不该静默消失。
        //
        //    不能拿 ① 逐源探测的失败名单去要求 ②：两次是**独立的网络调用**，
        //    429 这类瞬时限流在几秒后恢复是常态。实测：OpenAlex 在 ① 里三次
        //    重试全吃 429（5.8s），几秒后的 ② 里一次成功、贡献满 4 条——
        //    若拿 ① 的名单判 ②，会把「源恢复了」误报成「失败被吞」，
        //    自检在 OpenAlex 限流的日子永远红一条（2026-09-17 连跑两次复现）。
        //
        //    可证伪性：若 `search()` 把某个源的失败吞掉（failures 为空而该源
        //    一条都没贡献），这条断言立刻红。查询词固定为跨库都有存量的词组，
        //    所以「命中为零」在实际运行里几乎只可能是失败。
        let aggregateSources = Set(outcome.hits.map(\.source))
        let absent = Set(Self.sources.map(\.name)).subtracting(aggregateSources)
        if !absent.isEmpty {
            let reported = outcome.failures.joined(separator: "；")
            let reportedAll = absent.allSatisfy { reported.contains($0) }
            check("聚合里缺席的源都写进了 failures", reportedAll,
                  "缺席的源 \(absent.sorted().joined(separator: "、"))，failures 记录了 \(outcome.failures.count) 条")
        } else {
            NSLog("[Lumen][websearch] 三个源在这次聚合里都出了结果——这一次没有可验证的失败上报，如实记录而不是硬造一条恒真断言")
        }

        NSLog("[Lumen][websearch] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
              + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；")))
    }

    // MARK: - 逐源描述

    private struct SourceDescriptor {
        let name: String
        let fetch: (String) async -> Result<[LiteratureHit], Error>
    }

    private static var sources: [SourceDescriptor] {
        [
            SourceDescriptor(name: "Crossref", fetch: { query in
                await WebLiteratureSearch.crossref(query, timeout: 10)
            }),
            SourceDescriptor(name: "OpenAlex", fetch: { query in
                await WebLiteratureSearch.openAlex(query, timeout: 10)
            }),
            SourceDescriptor(name: "arXiv", fetch: { query in
                await WebLiteratureSearch.arxiv(query, timeout: 10)
            })
        ]
    }
}
