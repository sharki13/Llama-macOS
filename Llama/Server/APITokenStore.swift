import Foundation
import Security
import Darwin

/// Client credentials for llama-server. Secrets and their metadata live in the
/// login Keychain; UserDefaults only stores the anonymous-access preference.
enum APITokenStore {
  struct Token: Identifiable {
    let id: String
    let alias: String
    let createdAt: Date
  }

  enum StoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case invalidItem
    case randomFailure
    case fileFailure(String)

    var errorDescription: String? {
      switch self {
      case .keychain(let status):
        return "Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"
      case .invalidItem: return "An API token in Keychain is invalid."
      case .randomFailure: return "Couldn't generate a secure API token."
      case .fileFailure(let detail): return "Couldn't prepare the server API keys: \(detail)"
      }
    }
  }

  private static let service = "\(Bundle.main.bundleIdentifier ?? "app.llama.Llama").api-tokens"
  private static let internalAccount = "internal-server-client"

  private static func query(account: String? = nil) -> [String: Any] {
    var result: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrSynchronizable as String: false,
    ]
    if let account { result[kSecAttrAccount as String] = account }
    return result
  }

  static func list() throws -> [Token] {
    var request = query()
    request[kSecMatchLimit as String] = kSecMatchLimitAll
    request[kSecReturnAttributes as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw StoreError.keychain(status) }
    guard let items = result as? [[String: Any]] else { throw StoreError.invalidItem }
    return try items.compactMap { item in
      guard let id = item[kSecAttrAccount as String] as? String else {
        throw StoreError.invalidItem
      }
      if id == internalAccount { return nil }
      guard let alias = item[kSecAttrLabel as String] as? String,
        let createdAt = item[kSecAttrCreationDate as String] as? Date
      else { throw StoreError.invalidItem }
      return Token(id: id, alias: alias, createdAt: createdAt)
    }.sorted { $0.createdAt > $1.createdAt }
  }

  /// Returns the value once for the creation sheet. The list view never reads it.
  static func create(alias: String) throws -> String {
    let value = try randomToken()
    try add(value: value, account: UUID().uuidString, alias: alias)
    return value
  }

  static func rename(id: String, alias: String) throws {
    guard id != internalAccount else { throw StoreError.invalidItem }
    let attributes = [kSecAttrLabel as String: alias]
    let status = SecItemUpdate(query(account: id) as CFDictionary, attributes as CFDictionary)
    guard status == errSecSuccess else { throw StoreError.keychain(status) }
  }

  static func delete(id: String) throws {
    guard id != internalAccount else { throw StoreError.invalidItem }
    let status = SecItemDelete(query(account: id) as CFDictionary)
    guard status == errSecSuccess else { throw StoreError.keychain(status) }
  }

  static func internalToken() throws -> String {
    if let existing = try read(account: internalAccount) { return existing }
    let value = try randomToken()
    do {
      try add(value: value, account: internalAccount, alias: "Llama internal client")
      return value
    } catch StoreError.keychain(errSecDuplicateItem) {
      guard let existing = try read(account: internalAccount) else { throw StoreError.invalidItem }
      return existing
    }
  }

  static func allServerKeys() throws -> [String] {
    let tokens = try list()
    return try [internalToken()] + tokens.map { token in
      guard let value = try read(account: token.id) else { throw StoreError.invalidItem }
      return value
    }
  }

  private static func read(account: String) throws -> String? {
    var request = query(account: account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw StoreError.keychain(status) }
    guard let data = result as? Data, let value = String(data: data, encoding: .utf8),
      !value.isEmpty else { throw StoreError.invalidItem }
    return value
  }

  private static func add(value: String, account: String, alias: String) throws {
    var request = query(account: account)
    request[kSecAttrLabel as String] = alias
    request[kSecValueData as String] = Data(value.utf8)
    let status = SecItemAdd(request as CFDictionary, nil)
    guard status == errSecSuccess else { throw StoreError.keychain(status) }
  }

  private static func randomToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw StoreError.randomFailure
    }
    return "llama_" + Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static var keyDirectory: URL {
    UserSettings.appSupportDir.appendingPathComponent("APIKeys", isDirectory: true)
  }
  static var serverKeyFileURL: URL { keyDirectory.appendingPathComponent("server.keys") }

  /// llama-server reads this file during startup. Keep it until the process
  /// exits, including older router builds that pass the path to model workers.
  static func prepareServerKeyFile() throws -> (url: URL, internalToken: String) {
    let directory = keyDirectory
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    } catch {
      throw StoreError.fileFailure(error.localizedDescription)
    }

    let url = serverKeyFileURL
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw StoreError.fileFailure(String(cString: strerror(errno))) }
    do {
      let keys = try allServerKeys()
      let contents = Data(keys.joined(separator: "\n").appending("\n").utf8)
      try contents.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var written = 0
        while written < raw.count {
          let count = write(fd, base.advanced(by: written), raw.count - written)
          guard count > 0 else { throw StoreError.fileFailure(String(cString: strerror(errno))) }
          written += count
        }
      }
      guard close(fd) == 0 else { throw StoreError.fileFailure(String(cString: strerror(errno))) }
      return (url, keys[0])
    } catch {
      _ = close(fd)
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  static func removeServerKeyFile(_ url: URL?) {
    guard let url else { return }
    try? FileManager.default.removeItem(at: url)
  }

  /// Called after reclaiming a server left by an earlier app crash.
  static func removeStaleServerKeyFiles() {
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: keyDirectory, includingPropertiesForKeys: nil) else { return }
    for url in urls where url.pathExtension == "keys" { removeServerKeyFile(url) }
  }
}
