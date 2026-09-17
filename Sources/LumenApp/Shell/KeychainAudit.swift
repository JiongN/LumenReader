import Foundation
import LumenKit

/// 钥匙串访问自检：`--keychain-report 1`。
///
/// 为什么单独验这一块：`hasKey` 的返回值只有 true / false 两种，
/// **走属性通道和走密文通道得到的终值一模一样**，肉眼与日志都分不出来。
/// 但两者的代价差三个数量级（实测 32ms 零弹窗 vs 7282ms 触发系统弹窗），
/// 而且密文通道会因为 ad-hoc 签名每次重编译都换 CDHash 而反复弹授权框。
/// 所以这里不看终值，只看**耗时与钥匙串调用次数的增量**。
///
/// 自检原则：只做只读查询，绝不写、绝不删用户钥匙串里的任何东西。
@MainActor
enum KeychainAudit {

    /// 单次存在性判断的耗时上限。
    ///
    /// 属性通道实测 32ms 以内；密文通道在「重编译后的新二进制」上会阻塞到
    /// 系统弹窗出现（实测 7282ms 且需人工干预）。500ms 是个宽容但有效的分界。
    /// 注意这条断言只在**重编译之后**才有区分力——而那正是问题出现的时刻。
    private static let firstCallBudgetMS = 500

    static func run() {
        guard LaunchOptions.keychainReport else { return }

        let accounts = configuredAccounts()
        NSLog("[Lumen][keychain] 已配置服务商 \(accounts.count) 个")

        guard !accounts.isEmpty else {
            NSLog("[Lumen][keychain] 无服务商，跳过（先加一个 AI 服务商再看这条通道）")
            return
        }

        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failures.append(name) }
        }

        // ⓪ 冷启动计时必须放在最前面。一旦别的分支先调过 hasKey，缓存就热了，
        //    这条断言会退化成「恒真」，什么也证明不了。
        let probe = accounts[0]
        let cold = timed { AIKeychain.hasKey(account: probe) }
        NSLog("[Lumen][keychain] 冷启动首次判断：存在=\(cold.value) 耗时=\(cold.ms)ms"
              + "（预算 \(firstCallBudgetMS)ms）")
        check("存在性判断耗时在预算内（未走解密通道）", cold.ms < firstCallBudgetMS)

        // ① 真实账户
        NSLog("[Lumen][keychain] —— 真实账户 ——")
        for line in AIKeychain.diagnosticSnapshot(accounts: accounts) {
            NSLog("[Lumen][keychain] \(line)")
        }

        for account in accounts {
            let label = String(account.prefix(8))
            let state = AIKeychain.cacheState(account)
            // 关键断言：查过存在性之后缓存态必须是「存在」而不是「密文」。
            // 若成了「密文」，说明走了 read 那条路，并且把空串当密文缓存了下来，
            // 后续真正要发请求时会拿到空密钥，而整条链路一声不响。
            check("\(label) 判存在性后未误缓存明文", state != "已缓存密文")
        }

        // ② 缓存生效：同一账户再打两次，钥匙串调用次数不该再涨
        let warmed = AIKeychain.diagnosticSnapshot(accounts: [probe]).first ?? ""
        check("缓存生效（再次判断不再打钥匙串）", warmed.contains("钥匙串调用+0"))

        // ③ 对照组：必然不存在的账户
        let ghost = "00000000-0000-0000-0000-000000000000"
        let ghostExists = AIKeychain.hasKey(account: ghost)
        let ghostState = AIKeychain.cacheState(ghost)
        let ghostLine = AIKeychain.diagnosticSnapshot(accounts: [ghost]).first ?? ""
        NSLog("[Lumen][keychain] —— 对照：不存在的账户 ——")
        NSLog("[Lumen][keychain] \(ghostLine)")
        check("不存在的账户判为无", !ghostExists)
        check("不存在的账户缓存为「无」", ghostState == "已缓存「无」")
        check("不存在的账户不重复打钥匙串", ghostLine.contains("钥匙串调用+0"))

        NSLog(
            "[Lumen][keychain] 自检：通过 \(passed) 项，失败 \(failures.count) 项"
                + (failures.isEmpty ? " ✅" : " ❌ " + failures.joined(separator: "；"))
        )
    }

    // MARK: - 工具

    /// 从磁盘直接读一份配置，只为拿到账户名 UUID。
    ///
    /// 不走 `SettingsStore` 实例：自检只读，不该掺进应用的设置生命周期，
    /// 更不该因为自检而触发一次落盘。
    ///
    /// 当前激活的服务商排在最前——冷启动计时必须打在它身上：
    /// AIPanelView 的渲染路径求值的是 `activeProvider.isConfigured`，
    /// 拿一个没人用的服务商去测，测的就不是真实路径。
    private static func configuredAccounts() -> [String] {
        guard let data = try? Data(contentsOf: AppPaths.settingsFile), !data.isEmpty,
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return []
        }

        let providers = settings.ai.providers
        let activeID = settings.ai.activeProviderID ?? providers.first?.id
        let ordered = providers.filter { $0.id == activeID } + providers.filter { $0.id != activeID }
        return ordered.map(\.keychainAccount)
    }

    private static func timed(_ body: () -> Bool) -> (value: Bool, ms: Int) {
        let t0 = Date()
        let value = body()
        return (value, Int(Date().timeIntervalSince(t0) * 1000))
    }
}
