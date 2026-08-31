import Foundation
import Security

final class SecretStore {
    enum SecretError: LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
                return "无法访问钥匙串：\(message)（\(status)）"
            }
        }
    }

    private let service = "com.clipkeep.app.ai"

    func apiKey(for provider: AIProviderKind, baseURL: String) throws -> String {
        let account = try scopedAccount(for: provider, baseURL: baseURL)
        return try value(forAccount: account) ?? ""
    }

    func saveAPIKey(_ key: String, for provider: AIProviderKind, baseURL: String) throws {
        let account = try scopedAccount(for: provider, baseURL: baseURL)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: account)
        } else {
            try store(trimmed, forAccount: account)
        }
        // 用户已明确保存当前 origin 后，清理无法归属到主机的旧开发版条目。
        try delete(account: provider.rawValue)
    }

    private func scopedAccount(for provider: AIProviderKind, baseURL: String) throws -> String {
        "\(provider.rawValue)|\(try AIEndpointPolicy.credentialScope(for: baseURL))"
    }

    private func value(forAccount account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private func store(_ value: String, forAccount account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(identity as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw SecretError.keychain(updateStatus) }

        var insert = identity
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else { throw SecretError.keychain(insertStatus) }
    }

    private func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretError.keychain(status)
        }
    }
}
