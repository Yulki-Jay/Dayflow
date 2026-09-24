import Combine
import Foundation
import GRDB

struct WebDAVConfiguration: Sendable, Equatable {
  static let passwordKeychainKey = "webdav.timeline.password"

  var serverURL: String
  var username: String
  var password: String
  var remotePath: String
  var includeMedia: Bool = false
  var snapshotFilename: String = "timeline.json"

  var normalizedServerURL: URL? {
    let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      components.host != nil
    else { return nil }

    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.url
  }

  var normalizedRemotePathComponents: [String] {
    remotePath
      .split(separator: "/")
      .map(String.init)
      .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  var remoteFileURL: URL? {
    guard var url = normalizedServerURL else { return nil }
    for component in normalizedRemotePathComponents {
      url.appendPathComponent(component)
    }
    url.appendPathComponent(snapshotFilename)
    return url
  }

  var remoteDirectoryURLs: [URL] {
    guard var url = normalizedServerURL else { return [] }
    return normalizedRemotePathComponents.map { component in
      url.appendPathComponent(component, isDirectory: true)
      return url
    }
  }

  var validationMessage: String? {
    guard normalizedServerURL != nil else {
      return String(localized: "Enter a valid HTTP or HTTPS WebDAV URL.")
    }
    guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return String(localized: "Enter your WebDAV username.")
    }
    guard !password.isEmpty else {
      return String(localized: "Enter your WebDAV password.")
    }
    guard !remotePath.split(separator: "/").contains(".."),
      !remotePath.contains("://"),
      !remotePath.lowercased().hasSuffix(".json") else {
      return String(localized: "Enter a folder relative to the server URL, not a JSON filename.")
    }
    return nil
  }
}

enum WebDAVTimelinePreferences {
  private enum Key {
    static let serverURL = "webDAVTimelineServerURL"
    static let username = "webDAVTimelineUsername"
    static let remotePath = "webDAVTimelineRemotePath"
    static let automaticSync = "webDAVTimelineAutomaticSync"
    static let lastSyncAt = "webDAVTimelineLastSyncAt"
  }

  static let defaultRemotePath = "Dayflow"

  static var includeMedia: Bool {
    get { UserDefaults.standard.bool(forKey: "webDAVIncludeMedia") }
    set { UserDefaults.standard.set(newValue, forKey: "webDAVIncludeMedia") }
  }

  static var serverURL: String {
    get { UserDefaults.standard.string(forKey: Key.serverURL) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: Key.serverURL) }
  }

  static var username: String {
    get { UserDefaults.standard.string(forKey: Key.username) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: Key.username) }
  }

  static var remotePath: String {
    get {
      if let directory = UserDefaults.standard.string(forKey: "webDAVSyncDirectory") { return directory }
      guard let legacy = UserDefaults.standard.string(forKey: Key.remotePath) else { return defaultRemotePath }
      return migratedLocation(from: legacy).directory
    }
    set { UserDefaults.standard.set(newValue, forKey: "webDAVSyncDirectory") }
  }

  // Keep existing custom snapshot filenames so old readers continue to work.
  static var snapshotFilename: String {
    let legacy = UserDefaults.standard.string(forKey: Key.remotePath)
    return legacy.map { migratedLocation(from: $0).filename } ?? "timeline.json"
  }

  static func migratedLocation(from legacy: String) -> (directory: String, filename: String) {
    let parts = legacy.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." }
    guard let filename = parts.last, filename.lowercased().hasSuffix(".json") else {
      return (parts.joined(separator: "/"), "timeline.json")
    }
    return (parts.dropLast().joined(separator: "/"), filename)
  }

  static var automaticSync: Bool {
    get { UserDefaults.standard.bool(forKey: Key.automaticSync) }
    set { UserDefaults.standard.set(newValue, forKey: Key.automaticSync) }
  }

  static var lastSyncAt: Date? {
    get { UserDefaults.standard.object(forKey: Key.lastSyncAt) as? Date }
    set { UserDefaults.standard.set(newValue, forKey: Key.lastSyncAt) }
  }

  static func configuration(password: String? = nil) -> WebDAVConfiguration {
    WebDAVConfiguration(
      serverURL: serverURL,
      username: username,
      password: password
        ?? KeychainManager.shared.retrieve(for: WebDAVConfiguration.passwordKeychainKey) ?? "",
      remotePath: remotePath,
      includeMedia: includeMedia,
      snapshotFilename: snapshotFilename
    )
  }

  static func save(_ configuration: WebDAVConfiguration, automaticSync: Bool) throws {
    serverURL = configuration.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
    remotePath = configuration.normalizedRemotePathComponents.joined(separator: "/")
    self.automaticSync = automaticSync
    includeMedia = configuration.includeMedia

    guard KeychainManager.shared.store(
      configuration.password, for: WebDAVConfiguration.passwordKeychainKey)
    else {
      throw WebDAVTimelineSyncError.keychainWriteFailed
    }
  }
}

struct WebDAVTimelineSnapshot: Codable, Sendable, Equatable {
  struct Source: Codable, Sendable, Equatable {
    let app: String
    let appVersion: String
    let timeZone: String
  }

  struct Category: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let colorHex: String
    let description: String?
    let order: Int
    let isSystem: Bool
    let isIdle: Bool
  }

  struct Activity: Codable, Sendable, Equatable {
    let id: Int64
    let startAt: Date
    let endAt: Date
    let day: String
    let startTime: String
    let endTime: String
    let category: String
    let subcategory: String
    let title: String
    let summary: String
    let detailedSummary: String
    let distractions: [Distraction]?
    let appSites: AppSites?
  }

  struct Standup: Codable, Sendable, Equatable {
    let day: String
    let payload: String
    let createdAt: Date?
    let updatedAt: Date?
  }

  let schemaVersion: Int
  let generatedAt: Date
  let source: Source
  let categories: [Category]
  let activities: [Activity]
  let standups: [Standup]
  var media: WebDAVMediaManifest? = nil
}

extension StorageManager {
  func makeWebDAVTimelineSnapshot(generatedAt: Date = Date()) throws -> WebDAVTimelineSnapshot {
    let decoder = JSONDecoder()
    let activities: [WebDAVTimelineSnapshot.Activity] = try timedRead(
      "makeWebDAVTimelineSnapshot"
    ) { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT id, start, end, start_ts, end_ts, day, title, summary,
                     category, subcategory, detailed_summary, metadata
              FROM timeline_cards
              WHERE is_deleted = 0
              ORDER BY start_ts ASC, id ASC
          """)
      .compactMap { row in
        guard let id: Int64 = row["id"],
          let startTs: Int = row["start_ts"],
          let endTs: Int = row["end_ts"]
        else { return nil }

        var distractions: [Distraction]?
        var appSites: AppSites?
        if let metadataString: String = row["metadata"],
          let data = metadataString.data(using: .utf8)
        {
          if let metadata = try? decoder.decode(TimelineMetadata.self, from: data) {
            distractions = metadata.distractions
            appSites = metadata.appSites
          } else {
            distractions = try? decoder.decode([Distraction].self, from: data)
          }
        }

        return WebDAVTimelineSnapshot.Activity(
          id: id,
          startAt: Date(timeIntervalSince1970: TimeInterval(startTs)),
          endAt: Date(timeIntervalSince1970: TimeInterval(endTs)),
          day: row["day"],
          startTime: row["start"],
          endTime: row["end"],
          category: row["category"],
          subcategory: row["subcategory"] ?? "",
          title: row["title"],
          summary: row["summary"] ?? "",
          detailedSummary: row["detailed_summary"] ?? "",
          distractions: distractions,
          appSites: appSites
        )
      }
    }

    let descriptors = CategoryStore.descriptorsForLLM()
    let categories = descriptors.enumerated().map { index, descriptor in
      WebDAVTimelineSnapshot.Category(
        id: descriptor.id,
        name: descriptor.name,
        colorHex: descriptor.colorHex,
        description: descriptor.description,
        order: index,
        isSystem: descriptor.isSystem,
        isIdle: descriptor.isIdle
      )
    }
    let standups = fetchAllDailyStandups().map {
      WebDAVTimelineSnapshot.Standup(
        day: $0.standupDay,
        payload: $0.payloadJSON,
        createdAt: $0.createdAt,
        updatedAt: $0.updatedAt
      )
    }
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

    return WebDAVTimelineSnapshot(
      schemaVersion: 1,
      generatedAt: generatedAt,
      source: .init(
        app: "Dayflow",
        appVersion: version,
        timeZone: TimeZone.autoupdatingCurrent.identifier
      ),
      categories: categories,
      activities: activities,
      standups: standups
    )
  }
}

enum WebDAVTimelineSyncError: LocalizedError, Equatable {
  case invalidConfiguration(String)
  case keychainWriteFailed
  case invalidResponse
  case alreadySyncing
  case requestFailed(method: String, statusCode: Int, message: String?)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message): return message
    case .keychainWriteFailed:
      return String(localized: "Couldn't save the WebDAV password to Keychain.")
    case .invalidResponse:
      return String(localized: "The WebDAV server returned an invalid response.")
    case .alreadySyncing:
      return String(localized: "A WebDAV sync is already running. Please try again when it finishes.")
    case .requestFailed(let method, let statusCode, let message):
      let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return detail.isEmpty
        ? String(localized: "WebDAV \(method) failed (HTTP \(statusCode)).")
        : String(localized: "WebDAV \(method) failed (HTTP \(statusCode)): \(detail)")
    }
  }
}

actor WebDAVTimelineSyncService {
  static let shared = WebDAVTimelineSyncService()

  let session: URLSession
  private var isSyncing = false

  init(session: URLSession = .shared) {
    self.session = session
  }

  func testConnection(configuration: WebDAVConfiguration) async throws {
    try validate(configuration)
    guard let url = configuration.normalizedServerURL else { return }
    var request = authenticatedRequest(url: url, method: "PROPFIND", configuration: configuration)
    request.setValue("0", forHTTPHeaderField: "Depth")
    let (data, response) = try await session.data(for: request)
    try validateResponse(response, data: data, method: "PROPFIND", accepted: 200..<300)
  }

  @discardableResult
  func sync(configuration: WebDAVConfiguration) async throws -> Int {
    try validate(configuration)
    guard !isSyncing else { throw WebDAVTimelineSyncError.alreadySyncing }
    isSyncing = true
    defer { isSyncing = false }

    for directoryURL in configuration.remoteDirectoryURLs {
      var request = authenticatedRequest(
        url: directoryURL, method: "MKCOL", configuration: configuration)
      request.setValue("0", forHTTPHeaderField: "Content-Length")
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw WebDAVTimelineSyncError.invalidResponse
      }
      guard (200..<300).contains(http.statusCode) || http.statusCode == 405 else {
        throw requestError(method: "MKCOL", response: http, data: data)
      }
    }

    var snapshot = try StorageManager.shared.makeWebDAVTimelineSnapshot()
    if configuration.includeMedia {
      snapshot.media = try await uploadMedia(configuration: configuration, activities: snapshot.activities)
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let body = try encoder.encode(snapshot)

    guard let remoteURL = configuration.remoteFileURL else {
      throw WebDAVTimelineSyncError.invalidResponse
    }
    var request = authenticatedRequest(
      url: remoteURL, method: "PUT", configuration: configuration)
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    let (responseData, response) = try await session.upload(for: request, from: body)
    try validateResponse(response, data: responseData, method: "PUT", accepted: 200..<300)
    WebDAVTimelinePreferences.lastSyncAt = Date()
    return snapshot.activities.count
  }

  func syncIfConfigured() async {
    guard WebDAVTimelinePreferences.automaticSync else { return }
    let configuration = WebDAVTimelinePreferences.configuration()
    guard configuration.validationMessage == nil else { return }
    do {
      _ = try await sync(configuration: configuration)
    } catch {
      print("⚠️ [WebDAV] Automatic timeline sync failed: \(error.localizedDescription)")
    }
  }

  private func validate(_ configuration: WebDAVConfiguration) throws {
    if let message = configuration.validationMessage {
      throw WebDAVTimelineSyncError.invalidConfiguration(message)
    }
  }

  func authenticatedRequest(
    url: URL,
    method: String,
    configuration: WebDAVConfiguration
  ) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 60
    let credentials = "\(configuration.username):\(configuration.password)"
    let encoded = Data(credentials.utf8).base64EncodedString()
    request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    request.setValue("Dayflow WebDAV Sync", forHTTPHeaderField: "User-Agent")
    return request
  }

  func validateResponse(
    _ response: URLResponse,
    data: Data,
    method: String,
    accepted: Range<Int>
  ) throws {
    guard let http = response as? HTTPURLResponse else {
      throw WebDAVTimelineSyncError.invalidResponse
    }
    guard accepted.contains(http.statusCode) else {
      throw requestError(method: method, response: http, data: data)
    }
  }

  private func requestError(method: String, response: HTTPURLResponse, data: Data) -> Error {
    let message = String(data: data.prefix(1_024), encoding: .utf8)
    return WebDAVTimelineSyncError.requestFailed(
      method: method,
      statusCode: response.statusCode,
      message: message
    )
  }
}

@MainActor
final class WebDAVAutomaticSyncScheduler {
  static let shared = WebDAVAutomaticSyncScheduler()
  private var timer: Timer?

  private init() {}

  func start() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
      Task { await WebDAVTimelineSyncService.shared.syncIfConfigured() }
    }
    Task { await WebDAVTimelineSyncService.shared.syncIfConfigured() }
  }
}

@MainActor
final class WebDAVSettingsViewModel: ObservableObject {
  @Published var serverURL: String
  @Published var username: String
  @Published var password: String
  @Published var remotePath: String
  @Published var automaticSync: Bool
  @Published var includeMedia: Bool
  @Published private(set) var isWorking = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var errorMessage: String?
  @Published private(set) var lastSyncAt: Date?

  init() {
    serverURL = WebDAVTimelinePreferences.serverURL
    username = WebDAVTimelinePreferences.username
    password =
      KeychainManager.shared.retrieve(for: WebDAVConfiguration.passwordKeychainKey) ?? ""
    remotePath = WebDAVTimelinePreferences.remotePath
    automaticSync = WebDAVTimelinePreferences.automaticSync
    includeMedia = WebDAVTimelinePreferences.includeMedia
    lastSyncAt = WebDAVTimelinePreferences.lastSyncAt
  }

  var canSubmit: Bool {
    !isWorking && configuration.validationMessage == nil
  }

  func saveAndTest() {
    perform(actionName: String(localized: "Connection successful. Settings saved.")) {
      let configuration = self.configuration
      try WebDAVTimelinePreferences.save(configuration, automaticSync: self.automaticSync)
      try await WebDAVTimelineSyncService.shared.testConnection(configuration: configuration)
      return nil
    }
  }

  func syncNow() {
    perform(actionName: nil) {
      let configuration = self.configuration
      try WebDAVTimelinePreferences.save(configuration, automaticSync: self.automaticSync)
      let count = try await WebDAVTimelineSyncService.shared.sync(configuration: configuration)
      return String(localized: "Synced \(count) timeline activities.")
    }
  }

  func persistAutomaticSync() {
    guard configuration.validationMessage == nil else { return }
    do {
      try WebDAVTimelinePreferences.save(configuration, automaticSync: automaticSync)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private var configuration: WebDAVConfiguration {
    WebDAVConfiguration(
      serverURL: serverURL,
      username: username,
      password: password,
      remotePath: remotePath,
      includeMedia: includeMedia,
      snapshotFilename: WebDAVTimelinePreferences.snapshotFilename
    )
  }

  private func perform(
    actionName: String?,
    operation: @escaping () async throws -> String?
  ) {
    guard !isWorking else { return }
    if let validationMessage = configuration.validationMessage {
      errorMessage = validationMessage
      statusMessage = nil
      return
    }

    isWorking = true
    errorMessage = nil
    statusMessage = nil

    Task {
      do {
        let resultMessage = try await operation()
        statusMessage = resultMessage ?? actionName
        lastSyncAt = WebDAVTimelinePreferences.lastSyncAt
      } catch {
        errorMessage = error.localizedDescription
      }
      isWorking = false
    }
  }
}
