//
//  KeychainManager.swift
//  Dayflow
//

import Foundation
import Security

/// Thread-safe manager for securely storing API keys in macOS Keychain
final class KeychainManager {

  static let shared = KeychainManager()

  private let servicePrefix = "com.teleportlabs.dayflow.apikeys"
  private let queue = DispatchQueue(label: "com.teleportlabs.dayflow.keychain", qos: .userInitiated)

  private init() {}

  // Serialize legacy keychain operations while its process-wide UI policy is changed.
  func withAccess<T>(_ operation: () throws -> T) rethrows -> T {
    try queue.sync(execute: operation)
  }

  /// Stores an API key in the keychain
  /// - Parameters:
  ///   - apiKey: The API key to store
  ///   - provider: The provider identifier (e.g., "gemini", "dayflow")
  /// - Returns: true if successful, false otherwise
  @discardableResult
  func store(_ apiKey: String, for provider: String) -> Bool {
    return queue.sync {
      guard let data = apiKey.data(using: .utf8) else { return false }

      let service = "\(servicePrefix).\(provider)"
      let itemQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
      ]

      let updateStatus = SecItemUpdate(
        itemQuery as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
      if updateStatus == errSecSuccess {
        return true
      }
      guard updateStatus == errSecItemNotFound else {
        return false
      }

      let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
      ]

      return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }
  }

  /// Retrieves an API key from the keychain
  /// - Parameter provider: The provider identifier
  /// - Returns: The API key if found, nil otherwise
  func retrieve(for provider: String) -> String? {
    let timestamp = DateFormatter.localizedString(
      from: Date(), dateStyle: .none, timeStyle: .medium)
    print("\n🔐 [KeychainManager] Retrieving key for '\(provider)' at \(timestamp)")

    return queue.sync {
      let service = "\(servicePrefix).\(provider)"
      print("   Service: \(service)")
      print("   Account: \(provider)")

      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]

      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)

      // Log the status code for debugging
      switch status {
      case errSecSuccess:
        print("✅ [KeychainManager] SecItemCopyMatching succeeded")
      case errSecItemNotFound:
        print("❌ [KeychainManager] Item not found in keychain (errSecItemNotFound)")
      case errSecAuthFailed:
        print("❌ [KeychainManager] Authentication failed (errSecAuthFailed)")
      case errSecInteractionNotAllowed:
        print("❌ [KeychainManager] Interaction not allowed (errSecInteractionNotAllowed)")
        print("   This usually means the keychain is locked or inaccessible")
      case errSecParam:
        print("❌ [KeychainManager] Invalid parameters (errSecParam)")
      case errSecNotAvailable:
        print("❌ [KeychainManager] Keychain services not available (errSecNotAvailable)")
      default:
        print("❌ [KeychainManager] Unknown error code: \(status)")
      }

      guard status == errSecSuccess else {
        print("   Failed with status: \(status)")
        return nil
      }

      guard let data = result as? Data else {
        print("❌ [KeychainManager] Result is not Data type")
        print("   Result type: \(type(of: result))")
        return nil
      }

      print("   Retrieved data: \(data.count) bytes")

      guard let apiKey = String(data: data, encoding: .utf8) else {
        print("❌ [KeychainManager] Failed to decode data as UTF-8 string")
        return nil
      }

      print("✅ [KeychainManager] Successfully retrieved key")
      print("   Key length: \(apiKey.count) characters")

      return apiKey
    }
  }

  enum ReadError: LocalizedError, Equatable {
    case status(OSStatus)
    case invalidData

    var errorDescription: String? {
      switch self {
      case .status(errSecInteractionNotAllowed), .status(errSecAuthFailed):
        return String(localized: "Keychain access is locked or requires approval. Use Unlock saved password in WebDAV settings.")
      case .status(errSecUserCanceled):
        return String(localized: "Keychain access was cancelled.")
      case .status(let status):
        return SecCopyErrorMessageString(status, nil) as String?
      case .invalidData:
        return String(localized: "The saved password could not be decoded. Enter it again in WebDAV settings.")
      }
    }
  }

  func readPassword(
    for provider: String, allowInteraction: Bool,
    lookup: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = KeychainManager.copyLegacyPassword
  ) throws -> String? {
    try queue.sync {
      var previousInteractionAllowed: DarwinBoolean = true
      if !allowInteraction {
        let status = SecKeychainGetUserInteractionAllowed(&previousInteractionAllowed)
        guard status == errSecSuccess else { throw ReadError.status(status) }
        // LAContext alone does not suppress UI for the legacy login keychain.
        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else { throw ReadError.status(disableStatus) }
      }
      defer {
        if !allowInteraction {
          SecKeychainSetUserInteractionAllowed(previousInteractionAllowed.boolValue)
        }
      }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "\(servicePrefix).\(provider)",
        kSecAttrAccount as String: provider,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: AnyObject?
      let status = lookup(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess else { throw ReadError.status(status) }
      guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
        throw ReadError.invalidData
      }
      return value
    }
  }

  static func copyLegacyPassword(
    _ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?
  ) -> OSStatus {
    let attributes = query as NSDictionary
    guard let service = attributes[kSecAttrService] as? String,
      let account = attributes[kSecAttrAccount] as? String else { return errSecParam }
    let keychains = attributes[kSecMatchSearchList].map { $0 as CFTypeRef }
    var item: SecKeychainItem?
    let findStatus = SecKeychainFindGenericPassword(
      keychains, UInt32(service.utf8.count), service,
      UInt32(account.utf8.count), account, nil, nil, &item)
    guard findStatus == errSecSuccess else { return findStatus }
    guard let item else { return errSecInvalidItemRef }
    var allowed: DarwinBoolean = true
    let interactionStatus = SecKeychainGetUserInteractionAllowed(&allowed)
    guard interactionStatus == errSecSuccess else { return interactionStatus }
    if !allowed.boolValue {
      var keychain: SecKeychain?
      let copyStatus = SecKeychainItemCopyKeychain(item, &keychain)
      guard copyStatus == errSecSuccess else { return copyStatus }
      var state: SecKeychainStatus = 0
      let stateStatus = SecKeychainGetStatus(keychain, &state)
      guard stateStatus == errSecSuccess else { return stateStatus }
      // A cached legacy keychain can still try to unlock despite the global UI policy.
      guard state & SecKeychainStatus(kSecUnlockStateStatus) != 0 else {
        return errSecInteractionNotAllowed
      }
    }
    var length: UInt32 = 0
    var bytes: UnsafeMutableRawPointer?
    let status = SecKeychainItemCopyContent(item, nil, nil, &length, &bytes)
    guard status == errSecSuccess else { return status }
    defer { SecKeychainItemFreeContent(nil, bytes) }
    result?.pointee = (bytes.map { Data(bytes: $0, count: Int(length)) } ?? Data()) as CFData
    return errSecSuccess
  }

  /// Deletes an API key from the keychain
  /// - Parameter provider: The provider identifier
  /// - Returns: true if successful, false otherwise
  @discardableResult
  func delete(for provider: String) -> Bool {
    return queue.sync {
      let service = "\(servicePrefix).\(provider)"

      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: provider,
      ]

      let status = SecItemDelete(query as CFDictionary)
      return status == errSecSuccess || status == errSecItemNotFound
    }
  }

  /// Checks if an API key exists in the keychain
  /// - Parameter provider: The provider identifier
  /// - Returns: true if the key exists, false otherwise
  func exists(for provider: String) -> Bool {
    return retrieve(for: provider) != nil
  }
}
