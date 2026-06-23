// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// KeychainStore.swift — macOS Keychain-based secure credential storage
///
/// Stores API keys, agent private keys, and other secrets in the macOS Keychain.
/// Resolves ${KEYCHAIN:...} config references at runtime.

import Foundation

/// Keychain store for secure credential management.
///
/// Uses macOS Keychain Services — no third-party dependency.
/// Supports both per-service and per-label lookups.
final class KeychainStore: Sendable {
    /// Service name used for all ocoreai Keychain entries.
    static let service = "com.ocoreai.runtime"

    /// Save a credential to the Keychain.
    /// - Parameters:
    ///   - account: Identifier for this credential (e.g. "api_key_modelscope")
    ///   - value:  Secret plaintext saved to Keychain
    func save(account: String, value: String) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        // Delete existing entry first to avoid duplicates
        SecItemDelete(deleteQuery as CFDictionary)

        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed("UTF-8 encoding failed for account: \(account)")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.writeFailed(status: status)
        }
    }

    /// Retrieve a credential from the Keychain.
    /// - Parameter account: Identifier for the credential
    func retrieve(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw KeychainError.notFound(account: account)
        }

        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodeFailed(account: account)
        }
        return value
    }

    /// Delete a credential from the Keychain.
    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }

    /// Check if a credential exists in the Keychain.
    func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Resolve a ${KEYCHAIN:name} reference to its actual value.
    /// Returns nil if the key does not exist in the Keychain.
    static func resolveReference(_ value: String) -> String? {
        guard let range = value.range(of: #"^\$\{KEYCHAIN:([^}]+)\}$"#, options: .regularExpression) else {
            return nil
        }
        let keyName = String(value[range])
        // Extract the name part after "KEYCHAIN:"
        guard let colonRange = keyName.range(of: "KEYCHAIN:") else { return nil }
        let accountName = String(keyName[keyName.index(colonRange.upperBound, offsetBy: 1)...].dropLast())
        
        do {
            let store = KeychainStore()
            return try store.retrieve(account: accountName)
        } catch {
            return nil
        }
    }

    /// List all credential accounts stored for this service.
    func listAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Keychain-specific errors.
enum KeychainError: Error, Sendable {
    case notFound(account: String)
    case decodeFailed(account: String)
    case writeFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)
    case encodingFailed(String)
}

extension KeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notFound(let account): return "Keychain entry not found: \(account)"
        case .decodeFailed(let account): return "Failed to decode Keychain entry: \(account)"
        case .writeFailed(let status): return "Keychain write failed (OSStatus: \(status))"
        case .deleteFailed(let status): return "Keychain delete failed (OSStatus: \(status))"
        case .encodingFailed(let message): return "Keychain encoding failed: \(message)"
        }
    }
}