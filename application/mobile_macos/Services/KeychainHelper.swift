import Foundation
import Security

/// Keychain storage with transparent UserDefaults fallback for unsigned local builds and XCTest.
class KeychainHelper {
    static let standard = KeychainHelper()
    private let service = "com.bilingual.reader.mac"
    private let fallbackPrefix = "com.bilingual.reader.mac.fallback."
    private let xctestPrefix = "com.bilingual.reader.mac.xctest."

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Avoids blocking on macOS Login Keychain ACL prompts when running unsigned local builds or XCTest.
    private var shouldUseUserDefaultsOnly: Bool {
        if isRunningTests {
            return true
        }
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return true
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return true
        }
        var infoCF: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        )
        guard status == errSecSuccess,
              let info = infoCF as? [String: Any],
              let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty else {
            return true
        }
        return false
    }

    private func defaultsKey(for key: String) -> String {
        (isRunningTests ? xctestPrefix : fallbackPrefix) + key
    }

    private init() {}

    func save(_ value: String, forKey key: String) {
        if shouldUseUserDefaultsOnly {
            UserDefaults.standard.set(value, forKey: defaultsKey(for: key))
            return
        }
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var newQuery = query
        newQuery[kSecValueData as String] = data
        newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(newQuery as CFDictionary, nil)
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackPrefix + key)
        } else {
            UserDefaults.standard.set(value, forKey: fallbackPrefix + key)
        }
    }

    func get(forKey key: String) -> String? {
        if shouldUseUserDefaultsOnly {
            return UserDefaults.standard.string(forKey: defaultsKey(for: key))
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess,
           let data = dataTypeRef as? Data,
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return UserDefaults.standard.string(forKey: fallbackPrefix + key)
    }

    func delete(forKey key: String) {
        if shouldUseUserDefaultsOnly {
            UserDefaults.standard.removeObject(forKey: defaultsKey(for: key))
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + key)
    }

    static func delete(key: String) {
        standard.delete(forKey: key)
    }
}
