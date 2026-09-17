import Foundation
import Security

/// API 密钥存储。
///
/// 密钥一律进系统钥匙串，绝不写进 settings.json、日志或错误信息里。
/// 这是硬约束——配置文件会被备份、被同步、被顺手发给别人，密钥不能跟着走。
///
/// ## 为什么这里有一层进程内缓存，存在性判断又单独走属性查询
///
/// 起因是「每重编译一次就疯狂弹钥匙串授权框」。根因有三层，缺一不可：
///
/// 1. **ad-hoc 签名的身份就是 CDHash**。`./build.sh` 每次都产生新 CDHash，
///    而 login 钥匙串的 ACL 认的正是二进制身份，于是旧条目在新二进制眼里
///    是「陌生程序」，macOS 就弹一次授权框。
/// 2. **存在性判断去解密文了**。`SecItemCopyMatching` 只要带 `kSecReturnData`
///    就必须解密，必须走 ACL 授权；而「有没有配密钥」根本不需要密文。
///    实测（tools/keychain-probe）：只读属性 32ms 零弹窗，
///    读密文 7282ms 且触发系统弹窗——差了三个数量级。
/// 3. **调用点挂在 SwiftUI 渲染路径上**。`isConfigured` 被 AIPanelView 的
///    服务商菜单求值，而它是同步阻塞调用，弹窗期间主线程被按住，
///    界面表现为「卡住 + 弹窗连发」。
///
/// 所以这里把两件事拆开：存在性只看属性（永不弹窗），密文每个账户每进程最多读一次。
///
/// ## 已知边界：重编译后仍会弹一次
///
/// 读密文终究要授权，而签名身份每构建都变，因此**重编译后首次真正用到密钥时
/// 仍会弹一次**授权框（点「始终允许」后，同一次构建内不再弹）。
/// 抹掉这最后一次需要一把稳定的代码签名身份——本机 `find-identity` 为 0，
/// 且 ad-hoc 签名用不了数据保护钥匙串（实测 `errSecMissingEntitlement -34018`，
/// 该钥匙串要求 `keychain-access-groups` entitlement）。
/// 这是当前签名条件下的地板，不是可以再优化掉的东西。
public enum AIKeychain {

    private static let service = "com.jn.lumen.ai"

    // MARK: - 进程内缓存

    private enum Entry {
        /// 密文已在内存里。
        case value(String)
        /// 条目存在，但密文还没取过（存在性判断只查属性，不顺手解密）。
        case present
        /// 已确认不存在。
        case missing
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Entry] = [:]
    /// 自检用：真实打到钥匙串的次数。命中缓存就不该增长，这是「缓存生效」的客观信号。
    nonisolated(unsafe) private static var keychainCalls = 0

    private static func cached(_ account: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return cache[account]
    }

    private static func noteKeychainCall() {
        lock.lock(); defer { lock.unlock() }
        keychainCalls += 1
    }

    private static func store(_ account: String, _ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        cache[account] = entry
    }

    private static func forget(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: account)
    }

    // MARK: - 写入

    /// 写入（已存在则覆盖）。
    @discardableResult
    public static func save(_ value: String, account: String) -> Bool {
        guard !account.isEmpty else { return false }

        // Keychain 没有 upsert，只能先删后加
        delete(account: account)

        guard !value.isEmpty else {
            store(account, .missing)
            return true
        }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: "Lumen AI 密钥"
        ]

        let ok = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        if ok {
            // 刚写进去的明文顺手进缓存，省掉一次授权
            store(account, .value(value))
        } else {
            forget(account)
        }
        return ok
    }

    // MARK: - 读取

    /// 取出密钥明文。需要 ACL 授权，因此**每个账户每个进程只读一次**。
    public static func read(account: String) -> String? {
        guard !account.isEmpty else { return nil }

        if let entry = cached(account) {
            switch entry {
            case .value(let value): return value
            case .missing:          return nil
            case .present:          break // 已知存在，但密文还没取过，往下走真取一次
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        noteKeychainCall()
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            // 只有「确实不存在」才写缓存。授权被拒 / 用户取消这类失败**不缓存**：
            // 缓存了就等于把一次拒绝升级成本进程内的永久拒绝，
            // 用户重新授权之后仍然以为没密钥。
            if status == errSecItemNotFound {
                store(account, .missing)
            }
            return nil
        }

        store(account, .value(value))
        return value
    }

    public static func delete(account: String) {
        guard !account.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        store(account, .missing)
    }

    /// 是否已配置密钥。
    ///
    /// **只查属性，不取密文**——这是本文件最重要的一个实现约束。
    /// 带上 `kSecReturnData` 就会去解密，就会走 ACL 授权、就会弹窗；
    /// 而属性查询实测 32ms 完成且永不弹窗，可以安全地放在渲染路径上。
    /// 结果同样进缓存，因此渲染路径上重复求值的成本是 0。
    public static func hasKey(account: String) -> Bool {
        guard !account.isEmpty else { return false }

        if let entry = cached(account) {
            switch entry {
            case .value, .present: return true
            case .missing:         return false
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        noteKeychainCall()
        var item: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
        // 记成 .present 而不是 .value：这里没拿到密文，
        // 记成 .value 会让后续 read 直接返回空串。
        store(account, found ? .present : .missing)
        return found
    }

    /// 只展示尾部四位，用于设置界面的回显。永远不把完整密钥交给 UI。
    public static func maskedKey(account: String) -> String? {
        guard let value = read(account: account), value.count >= 4 else { return nil }
        return "••••••••" + value.suffix(4)
    }

    // MARK: - 自检

    /// 自检通道：`--keychain-report 1` 用。
    ///
    /// 每个账户**连打两次**存在性判断并分别计时。
    /// 单看一次「有没有密钥」是终值，无法区分「缓存生效」与「本来只调用了一次」；
    /// 两次的耗时差与钥匙串调用增量才是证据——第二次应当接近 0ms 且调用数不增长。
    public static func diagnosticSnapshot(accounts: [String]) -> [String] {
        var lines: [String] = []

        for account in accounts {
            let before = keychainCallCount()
            let first = timed { hasKey(account: account) }
            let second = timed { hasKey(account: account) }
            let delta = keychainCallCount() - before

            lines.append("账户 \(account.prefix(8))…  存在=\(first.value)"
                         + "  首次=\(first.ms)ms  再次=\(second.ms)ms"
                         + "  钥匙串调用+\(delta)  缓存=\(cacheState(account))")
        }

        return lines
    }

    /// 缓存的三态。自检要靠它区分「只查了属性」与「把明文缓存下来了」——
    /// 后者会让后续 `read` 拿到空串，是个安静的坑。
    public static func cacheState(_ account: String) -> String {
        switch cached(account) {
        case .value:   return "已缓存密文"
        case .present: return "已缓存「存在」"
        case .missing: return "已缓存「无」"
        case nil:      return "未缓存"
        }
    }

    private static func timed(_ body: () -> Bool) -> (value: Bool, ms: Int) {
        let t0 = Date()
        let value = body()
        return (value, Int(Date().timeIntervalSince(t0) * 1000))
    }

    private static func keychainCallCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return keychainCalls
    }
}
