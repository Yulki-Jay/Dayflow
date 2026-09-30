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

    if !components.percentEncodedPath.hasSuffix("/") {
      components.percentEncodedPath += "/"
    }
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

  func forDay(_ day: String) -> WebDAVConfiguration {
    var daily = self
    daily.remotePath = (normalizedRemotePathComponents + [day]).joined(separator: "/")
    return daily
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

  static func configuration(password: String) -> WebDAVConfiguration {
    WebDAVConfiguration(
      serverURL: serverURL,
      username: username,
      password: password,
      remotePath: remotePath,
      includeMedia: includeMedia,
      snapshotFilename: snapshotFilename
    )
  }

  static func save(
    _ configuration: WebDAVConfiguration, automaticSync: Bool,
    defaults: UserDefaults = .standard,
    storePassword: (String) -> Bool = {
      if (try? KeychainManager.shared.readPassword(
        for: WebDAVConfiguration.passwordKeychainKey, allowInteraction: false)) == $0 {
        return true
      }
      return KeychainManager.shared.store($0, for: WebDAVConfiguration.passwordKeychainKey)
    }
  ) throws {
    if let message = configuration.validationMessage {
      throw WebDAVTimelineSyncError.invalidConfiguration(message)
    }
    guard storePassword(configuration.password) else {
      throw WebDAVTimelineSyncError.keychainWriteFailed
    }
    defaults.set(configuration.serverURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.serverURL)
    defaults.set(configuration.username.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.username)
    defaults.set(configuration.normalizedRemotePathComponents.joined(separator: "/"), forKey: "webDAVSyncDirectory")
    defaults.set(automaticSync, forKey: Key.automaticSync)
    defaults.set(configuration.includeMedia, forKey: "webDAVIncludeMedia")
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

struct WebDAVDailyBackup: Sendable {
  let day: String
  var snapshot: WebDAVTimelineSnapshot
  let screenshots: [Screenshot]

  static func group(
    snapshot: WebDAVTimelineSnapshot, screenshots: [Screenshot]
  ) throws -> [WebDAVDailyBackup] {
    guard let timeZone = TimeZone(identifier: snapshot.source.timeZone) else {
      throw WebDAVTimelineSyncError.invalidResponse
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let activities = Dictionary(grouping: snapshot.activities, by: \.day)
    let standups = Dictionary(grouping: snapshot.standups, by: \.day)
    var frames: [String: [Screenshot]] = [:]
    var cachedDay: (dayString: String, startOfDay: Date, endOfDay: Date)?
    for screenshot in screenshots.sorted(by: { $0.capturedAt < $1.capturedAt })
      where !screenshot.isDeleted && screenshot.fileSize != nil {
      let date = screenshot.capturedDate
      if cachedDay == nil || date < cachedDay!.startOfDay || date >= cachedDay!.endOfDay {
        cachedDay = date.getDayInfoFor4AMBoundary(calendar: calendar)
      }
      frames[cachedDay!.dayString, default: []].append(screenshot)
    }
    let days = Set(activities.keys).union(standups.keys).union(frames.keys)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return try days.sorted(by: >).map { day in
      guard day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
        let date = formatter.date(from: day), formatter.string(from: date) == day else {
        throw WebDAVTimelineSyncError.invalidBackupDay
      }
      return WebDAVDailyBackup(day: day,
        snapshot: WebDAVTimelineSnapshot(
          schemaVersion: snapshot.schemaVersion, generatedAt: snapshot.generatedAt,
          source: snapshot.source, categories: snapshot.categories,
          activities: activities[day] ?? [], standups: standups[day] ?? []),
        screenshots: frames[day] ?? [])
    }
  }
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
  case redirected
  case mediaIncomplete(String)
  case invalidBackupDay
  case dailyBackupsIncomplete(String)
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
    case .redirected:
      return String(localized: "The WebDAV server redirected the request. Enter the final WebDAV URL, including its trailing slash, and try again.")
    case .mediaIncomplete(let detail):
      return String(localized: "Timeline updated, but media sync did not complete. Retry to finish syncing media. \(detail)")
    case .invalidBackupDay:
      return String(localized: "A backup contains an invalid date. No daily backup was uploaded.")
    case .dailyBackupsIncomplete(let detail):
      return String(localized: "Some daily backups did not complete. Retry to finish syncing. \(detail)")
    case .requestFailed(let method, let statusCode, let message):
      let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return detail.isEmpty
        ? String(localized: "WebDAV \(method) failed (HTTP \(statusCode)).")
        : String(localized: "WebDAV \(method) failed (HTTP \(statusCode)): \(detail)")
    }
  }
}

@MainActor
final class WebDAVSyncStatus: ObservableObject {
  static let shared = WebDAVSyncStatus()
  @Published var isSyncing = false
  @Published var phase: String?
  @Published var errorMessage: String?
  @Published var lastSyncAt = WebDAVTimelinePreferences.lastSyncAt
}

final class WebDAVRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    // WebDAV writes must never become GETs or forward credentials to another origin.
    completionHandler(nil)
  }
}

actor WebDAVTimelineSyncService {
  static let shared = WebDAVTimelineSyncService()

  let session: URLSession
  private let redirectPolicy = WebDAVRedirectPolicy()
  private let snapshotProvider: @Sendable () throws -> WebDAVTimelineSnapshot
  private let screenshotsProvider: @Sendable () throws -> [Screenshot]
  private let mediaProvider: (@Sendable (WebDAVConfiguration, [WebDAVTimelineSnapshot.Activity], [Screenshot]) async throws -> WebDAVMediaManifest)?
  private var currentBackupDay: String?
  private let retrySleep: @Sendable (TimeInterval) async throws -> Void
  private var activeSync: Task<Int, Error>?
  private let reportsStatus: Bool

  static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForResource = 300
    return URLSession(configuration: configuration)
  }

  init(session: URLSession = WebDAVTimelineSyncService.makeSession(), reportsStatus: Bool = true,
    snapshotProvider: @escaping @Sendable () throws -> WebDAVTimelineSnapshot = {
      try StorageManager.shared.makeWebDAVTimelineSnapshot()
    },
    screenshotsProvider: @escaping @Sendable () throws -> [Screenshot] = {
      try StorageManager.shared.webDAVScreenshots()
    },
    mediaProvider: (@Sendable (WebDAVConfiguration, [WebDAVTimelineSnapshot.Activity], [Screenshot]) async throws -> WebDAVMediaManifest)? = nil,
    retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
    }
  ) {
    self.session = session
    self.reportsStatus = reportsStatus
    self.snapshotProvider = snapshotProvider
    self.screenshotsProvider = screenshotsProvider
    self.mediaProvider = mediaProvider
    self.retrySleep = retrySleep
  }

  func cancelSync() {
    activeSync?.cancel()
  }

  func reportPhase(_ phase: String) async {
    guard reportsStatus else { return }
    let message = currentBackupDay.map { "\($0) · \(phase)" } ?? phase
    await MainActor.run { WebDAVSyncStatus.shared.phase = message }
  }

  func send(_ request: URLRequest, body: Data? = nil) async throws -> (Data, URLResponse) {
    for attempt in 0..<3 {
      try Task.checkCancellation()
      do {
        let result: (Data, URLResponse)
        if let body {
          result = try await session.upload(for: request, from: body, delegate: redirectPolicy)
        } else {
          result = try await session.data(for: request, delegate: redirectPolicy)
        }
        try Task.checkCancellation()
        guard let response = result.1 as? HTTPURLResponse else {
          throw WebDAVTimelineSyncError.invalidResponse
        }
        if (300..<400).contains(response.statusCode) {
          throw WebDAVTimelineSyncError.redirected
        }
        if [408, 429, 500, 502, 503, 504].contains(response.statusCode), attempt < 2 {
          let delay = Self.retryDelay(response: response, attempt: attempt)
          if let delay {
            try await retrySleep(delay)
            continue
          }
        }
        return result
      } catch let error as URLError where attempt < 2 && [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed
      ].contains(error.code) {
        try await retrySleep(pow(2, Double(attempt)))
      }
    }
    throw WebDAVTimelineSyncError.invalidResponse
  }

  static func retryDelay(response: HTTPURLResponse, attempt: Int, now: Date = Date()) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
      return pow(2, Double(attempt))
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
    let delay = TimeInterval(value) ?? formatter.date(from: value)?.timeIntervalSince(now)
    guard let delay else { return pow(2, Double(attempt)) }
    guard delay <= 30 else { return nil }
    return max(0, delay)
  }

  func testConnection(configuration: WebDAVConfiguration) async throws {
    try validate(configuration)
    guard let url = configuration.normalizedServerURL else { return }
    var request = authenticatedRequest(url: url, method: "PROPFIND", configuration: configuration)
    request.setValue("0", forHTTPHeaderField: "Depth")
    let (data, response) = try await send(request)
    try validateResponse(response, data: data, method: "PROPFIND", accepted: 200..<300)
  }

  func testAndSave(
    configuration: WebDAVConfiguration, automaticSync: Bool,
    save: @Sendable (WebDAVConfiguration, Bool) throws -> Void = {
      try WebDAVTimelinePreferences.save($0, automaticSync: $1)
    }
  ) async throws {
    try await testConnection(configuration: configuration)
    try Task.checkCancellation()
    try save(configuration, automaticSync)
  }

  @discardableResult
  func sync(configuration: WebDAVConfiguration) async throws -> Int {
    try validate(configuration)
    guard activeSync == nil else { throw WebDAVTimelineSyncError.alreadySyncing }
    try Task.checkCancellation()
    let task = Task { try await self.performSync(configuration: configuration) }
    activeSync = task
    defer { activeSync = nil }
    do {
      let count = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      if reportsStatus {
        await MainActor.run {
          WebDAVSyncStatus.shared.phase = String(localized: "Synced \(count) timeline activities.")
          WebDAVSyncStatus.shared.lastSyncAt = WebDAVTimelinePreferences.lastSyncAt
          WebDAVSyncStatus.shared.isSyncing = false
        }
      }
      return count
    } catch {
      if reportsStatus {
        await MainActor.run {
          WebDAVSyncStatus.shared.phase = nil
          WebDAVSyncStatus.shared.errorMessage = Self.message(for: error)
          WebDAVSyncStatus.shared.isSyncing = false
        }
      }
      throw error
    }
  }

  static func message(for error: Error) -> String {
    if error is CancellationError || (error as? URLError)?.code == .cancelled {
      return String(localized: "Sync cancelled.")
    }
    return error.localizedDescription
  }

  private func performSync(configuration: WebDAVConfiguration) async throws -> Int {
    if reportsStatus {
      await MainActor.run {
        WebDAVSyncStatus.shared.isSyncing = true
        WebDAVSyncStatus.shared.phase = nil
        WebDAVSyncStatus.shared.errorMessage = nil
      }
    }
    try Task.checkCancellation()
    defer { currentBackupDay = nil }
    let snapshot = try snapshotProvider()
    let screenshots = configuration.includeMedia ? try screenshotsProvider() : []
    let backups = try WebDAVDailyBackup.group(snapshot: snapshot, screenshots: screenshots)
    await reportPhase(String(localized: "Preparing remote folders…"))
    for directoryURL in configuration.remoteDirectoryURLs {
      try await createDirectory(directoryURL, configuration: configuration)
    }

    var ready: [WebDAVDailyBackup] = []
    var failures: [String] = []
    for var backup in backups {
      try Task.checkCancellation()
      currentBackupDay = backup.day
      let dailyConfiguration = configuration.forDay(backup.day)
      do {
        guard let directory = dailyConfiguration.remoteFileURL?.deletingLastPathComponent() else {
          throw WebDAVTimelineSyncError.invalidResponse
        }
        await reportPhase(String(localized: "Preparing remote folders…"))
        try await createDirectory(directory, configuration: dailyConfiguration)
        await reportPhase(String(localized: "Preserving the previous media index…"))
        backup.snapshot.media = try await previousMedia(configuration: dailyConfiguration)
        await reportPhase(String(localized: "Updating timeline…"))
        try await publish(backup.snapshot, configuration: dailyConfiguration)
        ready.append(backup)
      } catch {
        if mustStopSync(after: error) { throw error }
        failures.append("\(backup.day): \(Self.message(for: error))")
      }
    }
    let timelinesComplete = failures.isEmpty

    if configuration.includeMedia {
      for var backup in ready {
        try Task.checkCancellation()
        currentBackupDay = backup.day
        let dailyConfiguration = configuration.forDay(backup.day)
        do {
          let uploaded: WebDAVMediaManifest
          if let mediaProvider {
            uploaded = try await mediaProvider(
              dailyConfiguration, backup.snapshot.activities, backup.screenshots)
          } else {
            uploaded = try await uploadMedia(
              configuration: dailyConfiguration, activities: backup.snapshot.activities,
              screenshots: backup.screenshots)
          }
          backup.snapshot.media = backup.snapshot.media?.merging(uploaded) ?? uploaded
          await reportPhase(String(localized: "Publishing media index…"))
          try await publish(backup.snapshot, configuration: dailyConfiguration)
        } catch {
          let detail = "\(backup.day): \(Self.message(for: error))"
          if mustStopSync(after: error) {
            if timelinesComplete { throw WebDAVTimelineSyncError.mediaIncomplete(detail) }
            throw WebDAVTimelineSyncError.dailyBackupsIncomplete((failures + [detail]).joined(separator: "\n"))
          }
          failures.append(detail)
        }
      }
    }
    if !failures.isEmpty {
      let detail = failures.joined(separator: "\n")
      if timelinesComplete { throw WebDAVTimelineSyncError.mediaIncomplete(detail) }
      throw WebDAVTimelineSyncError.dailyBackupsIncomplete(detail)
    }
    if reportsStatus { WebDAVTimelinePreferences.lastSyncAt = Date() }
    return snapshot.activities.count
  }

  private func mustStopSync(after error: Error) -> Bool {
    if Task.isCancelled || error is CancellationError { return true }
    if let urlError = error as? URLError {
      return [.cancelled, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code)
    }
    if case WebDAVTimelineSyncError.requestFailed(_, let status, _) = error {
      return status == 401 || status == 403
    }
    return error as? WebDAVTimelineSyncError == .redirected
  }

  func createDirectory(_ url: URL, configuration: WebDAVConfiguration) async throws {
    var request = authenticatedRequest(url: url, method: "MKCOL", configuration: configuration)
    request.setValue("0", forHTTPHeaderField: "Content-Length")
    let (data, response) = try await send(request)
    guard let http = response as? HTTPURLResponse else { throw WebDAVTimelineSyncError.invalidResponse }
    guard (200..<300).contains(http.statusCode) || http.statusCode == 405 else {
      throw requestError(method: "MKCOL", response: http, data: data)
    }
  }

  private func previousMedia(configuration: WebDAVConfiguration) async throws -> WebDAVMediaManifest? {
    guard let url = configuration.remoteFileURL else { throw WebDAVTimelineSyncError.invalidResponse }
    var request = authenticatedRequest(url: url, method: "GET", configuration: configuration)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await send(request)
    if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
    try validateResponse(response, data: data, method: "GET", accepted: 200..<300)
    struct MediaIndex: Decodable { let media: WebDAVMediaManifest? }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MediaIndex.self, from: data).media
  }

  private func publish(_ snapshot: WebDAVTimelineSnapshot, configuration: WebDAVConfiguration) async throws {
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
    let (responseData, response) = try await send(request, body: body)
    try validateResponse(response, data: responseData, method: "PUT", accepted: 200..<300)
  }

  func syncIfConfigured() async {
    guard WebDAVTimelinePreferences.automaticSync, activeSync == nil else { return }
    do {
      let password = try KeychainManager.shared.readPassword(
        for: WebDAVConfiguration.passwordKeychainKey, allowInteraction: false) ?? ""
      let configuration = WebDAVTimelinePreferences.configuration(password: password)
      _ = try await sync(configuration: configuration)
    } catch {
      if reportsStatus {
        await MainActor.run {
          WebDAVSyncStatus.shared.phase = nil
          WebDAVSyncStatus.shared.errorMessage = Self.message(for: error)
        }
      }
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
    let credentials = "\(configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)):\(configuration.password)"
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
  private var operationTask: Task<Void, Never>?

  init() {
    serverURL = WebDAVTimelinePreferences.serverURL
    username = WebDAVTimelinePreferences.username
    password = ""
    remotePath = WebDAVTimelinePreferences.remotePath
    automaticSync = WebDAVTimelinePreferences.automaticSync
    includeMedia = WebDAVTimelinePreferences.includeMedia
    lastSyncAt = WebDAVTimelinePreferences.lastSyncAt
    do {
      password = try KeychainManager.shared.readPassword(
        for: WebDAVConfiguration.passwordKeychainKey, allowInteraction: false) ?? ""
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  var canSubmit: Bool {
    !isWorking && !WebDAVSyncStatus.shared.isSyncing && configuration.validationMessage == nil
  }

  func saveAndTest() {
    perform(actionName: String(localized: "Connection successful. Settings saved.")) {
      let configuration = self.configuration
      try await WebDAVTimelineSyncService.shared.testAndSave(
        configuration: configuration, automaticSync: self.automaticSync)
      return nil
    }
  }

  func syncNow() {
    perform(actionName: nil) {
      let configuration = self.configuration
      try await WebDAVTimelineSyncService.shared.testAndSave(
        configuration: configuration, automaticSync: self.automaticSync)
      let count = try await WebDAVTimelineSyncService.shared.sync(configuration: configuration)
      return String(localized: "Synced \(count) timeline activities.")
    }
  }

  func persistAutomaticSync() {
    if !automaticSync { WebDAVTimelinePreferences.automaticSync = false }
    if !includeMedia { WebDAVTimelinePreferences.includeMedia = false }
  }

  func unlockPassword() {
    guard !isWorking, !WebDAVSyncStatus.shared.isSyncing else { return }
    isWorking = true
    errorMessage = nil
    statusMessage = nil
    WebDAVSyncStatus.shared.errorMessage = nil
    WebDAVSyncStatus.shared.phase = nil
    operationTask = Task {
      defer { isWorking = false; operationTask = nil }
      do {
        let saved = try await Task.detached {
          try KeychainManager.shared.readPassword(
            for: WebDAVConfiguration.passwordKeychainKey, allowInteraction: true)
        }.value
        try Task.checkCancellation()
        password = saved ?? ""
        errorMessage = password.isEmpty ? String(localized: "Enter your WebDAV password.") : nil
      } catch {
        errorMessage = WebDAVTimelineSyncService.message(for: error)
      }
    }
  }

  func cancel() {
    operationTask?.cancel()
    Task { await WebDAVTimelineSyncService.shared.cancelSync() }
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
    guard !isWorking, !WebDAVSyncStatus.shared.isSyncing else { return }
    if let validationMessage = configuration.validationMessage {
      errorMessage = validationMessage
      statusMessage = nil
      return
    }

    isWorking = true
    errorMessage = nil
    statusMessage = nil

    WebDAVSyncStatus.shared.errorMessage = nil
    WebDAVSyncStatus.shared.phase = nil
    operationTask = Task {
      do {
        let resultMessage = try await operation()
        statusMessage = resultMessage ?? actionName
        lastSyncAt = WebDAVTimelinePreferences.lastSyncAt
      } catch {
        errorMessage = WebDAVTimelineSyncService.message(for: error)
      }
      isWorking = false
      operationTask = nil
    }
  }
}
