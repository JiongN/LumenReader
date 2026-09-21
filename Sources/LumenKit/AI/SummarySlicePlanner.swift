import Foundation

/// 将长文档均衡地分成有限数量的连续区间。
///
/// 这里不按“每 N 页”硬切，因为 31 页按 2 页一组只会得到 16 组，浪费了一半可用的
/// map 请求，也会让每一页能分到的代表性文字变少。按目标组数均分可以保证首、中、尾
/// 都被覆盖，而且每个页/章恰好出现一次。
public enum SummarySlicePlanner {
    public static func ranges(itemCount: Int, maximumGroups: Int = 30) -> [Range<Int>] {
        guard itemCount > 0, maximumGroups > 0 else { return [] }
        let groupCount = min(itemCount, maximumGroups)
        return (0..<groupCount).compactMap { group in
            let lower = group * itemCount / groupCount
            let upper = (group + 1) * itemCount / groupCount
            return lower < upper ? lower..<upper : nil
        }
    }

    public static func characterBudget(
        itemCount: Int,
        total: Int = 8_400,
        minimum: Int = 500
    ) -> Int {
        guard itemCount > 0 else { return total }
        return max(minimum, total / itemCount)
    }
}
