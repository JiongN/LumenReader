import Foundation
import Security

/// API 密钥存储。
///
/// 密钥一律进系统钥匙串，绝不写进 settings.json、日志或错误信息里。
/// 这是硬约束——配置文件会被备份、被同步、被顺手发给别人，密钥不能跟着走。
public enum AIKeychain {

    private static let service = "com.jn.lumen.ai"

    /// 写入（已存在则覆盖）。
    @discardableResult
    public static func save(_ value: String, account: String) -> Bool {
        guard !account.isEmpty else { return false }

        // Keychain 没有 upsert，只能先删后加
        delete(account: account)

        guard !value.isEmpty else { return true }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: "Lumen AI 密钥"
        ]

        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func read(account: String) -> String? {
        guard !account.isEmpty else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }
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
    }

    /// 是否已配置密钥（不需要读出明文）。
    public static func hasKey(account: String) -> Bool {
        read(account: account) != nil
    }

    /// 只展示尾部四位，用于设置界面的回显。永远不把完整密钥交给 UI。
    public static func maskedKey(account: String) -> String? {
        guard let value = read(account: account), value.count >= 4 else { return nil }
        return "••••••••" + value.suffix(4)
    }
}
