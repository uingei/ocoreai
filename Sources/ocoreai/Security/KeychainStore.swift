// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// KeychainStore.swift — macOS Keychain-based secure credential storage
///
/// Stores API keys, agent private keys, and other secrets in the macOS Keychain.
/// Resolves ${KEYCHAIN:...} config references at runtime.

import Foundation
import os.log

/// Keychain store for secure credential management.
///
/// Uses macOS Keychain Services — no third-party dependency.
/// Supports both per-service and per-label lookups.
final class KeychainStore: Sendable {
	/// Service name used for all ocoreai Keychain entries.
	static let service = "com.ocoreai.runtime"

	private static let osLogger = os.Logger(subsystem: "com.ocoreai.runtime", category: "KeychainStore")

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
			kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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
		      let data = result as? Data
		else {
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

	/// Resolve a ``${KEYCHAIN:name}`` reference to its actual value.
	/// Returns nil if the key does not exist in the Keychain.
	static func resolveReference(_ value: String) -> String? {
		// Parse ${KEYCHAIN:accountName} — substring-based to avoid regex issues
		let prefix = "${KEYCHAIN:"
		let suffix = "}"
		guard value.hasPrefix(prefix), value.hasSuffix(suffix), value.count > prefix.count + suffix.count else {
			return nil
		}
		let accountName = String(value.dropFirst(prefix.count).dropLast())

		do {
			let store = KeychainStore()
			return try store.retrieve(account: accountName)
		} catch {
			Self.osLogger.debug("Credential resolution failed for \(accountName): \(error)")
			return nil
		}
	}

	// MARK: - Convenience wrappers (string-based, non-throwing fallbacks)

	/// Store a string value; silently logs on failure.
	@discardableResult
	func set(_ value: String?, forKey key: String) -> Bool {
		guard let value, !value.isEmpty else {
			// nil/empty → delete
			do { try delete(account: key) } catch {
				Self.osLogger.error("Keychain delete failed for \(key): \(error)")
			}
			return true
		}
		do { try save(account: key, value: value) } catch {
			Self.osLogger.error("Keychain write failed for \(key): \(error)")
		}
		return true
	}

	/// Read a string value; returns nil on any failure.
	func string(forKey key: String) -> String? {
		guard exists(account: key) else { return nil }
		do { return try retrieve(account: key) } catch {
			Self.osLogger.debug("Keychain read failed for \(key): \(error)")
			return nil
		}
	}

	/// Remove a key from the Keychain.
	func removeObject(forKey key: String) {
		do { try delete(account: key) } catch {
			Self.osLogger.error("Keychain delete failed for \(key): \(error)")
		}
	}

	/// Shared singleton for SettingsStore and App entry point.
	static let shared = KeychainStore()

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
		      let items = result as? [[String: Any]]
		else {
			return []
		}

		return items.compactMap { $0[kSecAttrAccount as String] as? String }
	}
}

/// Keychain-specific errors.
enum KeychainError: Error {
	case notFound(account: String)
	case decodeFailed(account: String)
	case writeFailed(status: OSStatus)
	case deleteFailed(status: OSStatus)
	case encodingFailed(String)
}

extension KeychainError: LocalizedError {
	var errorDescription: String? {
		switch self {
		case let .notFound(account): "Keychain entry not found: \(account)"
		case let .decodeFailed(account): "Failed to decode Keychain entry: \(account)"
		case let .writeFailed(status): "Keychain write failed (OSStatus: \(status))"
		case let .deleteFailed(status): "Keychain delete failed (OSStatus: \(status))"
		case let .encodingFailed(message): "Keychain encoding failed: \(message)"
		}
	}
}
