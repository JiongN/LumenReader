import AppKit

/// 缩略图缓存：容量上限 + 「离当前页越远越先淘汰」。
///
/// 存在的理由：侧栏每渲染一页就把它存进一张字典（`cache[index] = image`），
/// 而这张字典只在**换文档**时清空。于是一本 600 页的书，只要用户把侧栏从头滚到尾，
/// 就会把 600 张缩略图一直留在内存里——这正是「大文件场景内存持续增长」的来路。
/// 上限把「滚过多少页就攒多少张」改成「最多攒 `capacity` 张」。
///
/// 为什么按「距当前页远近」淘汰，而不是严格 LRU：用户翻找时真正会回看的，几乎都是
/// 当前位置附近的页；离当前页很远的图，再滚回去的概率最低。这个策略让「来回翻找」
/// 的手感不受影响，被淘汰的又恰是最不该留的。
///
/// 策略做成独立类型（而不是塞在视图里）：自检通道要用**同一套策略**跑对照读数，
/// 证明「有上限」确实让驻留张数收敛、「关掉上限」（`--perf-thumbnail-unbounded 1`）
/// 确实随页数线性增长。优化本身要能被证伪，否则它就是装饰。
struct ThumbnailCache {

    /// 默认容量。可视区一般只放得下 ≤ 8 张，这里给足「来回翻找」的余量。
    static let defaultCapacity = 160

    /// 容量上限；`nil` = 不设上限（只用于证伪对照，正常路径永远是 `defaultCapacity`）。
    let capacity: Int?

    private(set) var storage: [Int: NSImage] = [:]

    init(capacity: Int?) {
        self.capacity = capacity
    }

    var count: Int { storage.count }

    /// 只读访问：命中返回图片，未命中返回 nil。写一律走 `store`（那里才做淘汰）。
    subscript(index: Int) -> NSImage? { storage[index] }

    /// 存入一张缩略图，并把超出上限的、离 `current` 最远的若干张淘汰掉。
    ///
    /// - Parameters:
    ///   - image: 新渲染好的缩略图。
    ///   - index: 它对应的页号（0-based）。
    ///   - current: 调用时刻的当前页号，用于计算「距离」。
    mutating func store(_ image: NSImage, at index: Int, current: Int) {
        storage[index] = image
        guard let capacity, storage.count > capacity else { return }
        let overflow = storage.count - capacity
        let victims = storage.keys
            .sorted { abs($0 - current) > abs($1 - current) }
            .prefix(overflow)
        for victim in victims {
            storage.removeValue(forKey: victim)
        }
    }

    mutating func removeAll() {
        storage.removeAll()
    }
}
