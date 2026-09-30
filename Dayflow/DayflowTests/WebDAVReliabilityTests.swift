import Security
import XCTest

@testable import Dayflow

final class WebDAVReliabilityTests: XCTestCase {
  private var sessions: [(URLSession, String)] = []
  private let configuration = WebDAVConfiguration(
    serverURL: "https://webdav.invalid/root/", username: "test", password: "test",
    remotePath: "Dayflow")

  override func tearDown() {
    for (session, id) in sessions {
      session.invalidateAndCancel()
      DAVProtocol.remove(id)
    }
    sessions = []
    super.tearDown()
  }

  func testFailedPasswordWritePreservesAllSettings() throws {
    let name = "WebDAVReliabilityTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("old-server", forKey: "webDAVTimelineServerURL")
    defaults.set("old-user", forKey: "webDAVTimelineUsername")
    defaults.set("old-path", forKey: "webDAVSyncDirectory")
    defaults.set(false, forKey: "webDAVTimelineAutomaticSync")
    let before = defaults.dictionaryRepresentation()
    XCTAssertThrowsError(try WebDAVTimelinePreferences.save(
      configuration, automaticSync: true, defaults: defaults, storePassword: { _ in false })) {
      XCTAssertEqual($0 as? WebDAVTimelineSyncError, .keychainWriteFailed)
    }
    XCTAssertEqual(before as NSDictionary, defaults.dictionaryRepresentation() as NSDictionary)
  }

  func testInvalidConfigurationDoesNotWriteCredentials() {
    var invalid = configuration
    invalid.serverURL = "ftp://webdav.invalid"
    XCTAssertThrowsError(try WebDAVTimelinePreferences.save(
      invalid, automaticSync: true, storePassword: { _ in
        XCTFail("Invalid configuration must not write credentials")
        return true
      }))
  }

  func testFailedConnectionDoesNotSave() async throws {
    let stub = DAVStub { _ in .init(status: 401) }
    let service = makeService(stub)
    do {
      try await service.testAndSave(configuration: configuration, automaticSync: true) { _, _ in
        XCTFail("Failed connection must not change saved settings")
      }
      XCTFail("Expected authentication failure")
    } catch {
      XCTAssertEqual(stub.requests.count, 1)
    }
  }

  func testSuccessfulConnectionSavesExactlyTheTestedConfiguration() async throws {
    let stub = DAVStub { _ in .init(status: 207) }
    let service = makeService(stub)
    let saved = expectation(description: "settings saved")
    let expected = configuration
    try await service.testAndSave(configuration: configuration, automaticSync: true) { config, enabled in
      XCTAssertEqual(config, expected)
      XCTAssertTrue(enabled)
      saved.fulfill()
    }
    await fulfillment(of: [saved], timeout: 1)
    XCTAssertEqual(stub.methods, ["PROPFIND"])
  }

  func testCancellationDoesNotSaveOrRetry() async throws {
    let stub = DAVStub { _ in .init(status: 503) }
    let service = makeService(stub, sleep: { _ in throw CancellationError() })
    do {
      try await service.testAndSave(configuration: configuration, automaticSync: true) { _, _ in
        XCTFail("Cancelled operation must not save")
      }
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
      XCTAssertEqual(stub.requests.count, 1)
    }
  }

  func testBackgroundCredentialReadDisallowsInteraction() throws {
    XCTAssertThrowsError(try KeychainManager.shared.readPassword(
      for: "webdav-test", allowInteraction: false, lookup: { query, _ in
        var allowed: DarwinBoolean = true
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        XCTAssertFalse(allowed.boolValue)
        return errSecInteractionNotAllowed
      })) {
      XCTAssertEqual($0 as? KeychainManager.ReadError, .status(errSecInteractionNotAllowed))
    }
  }

  func testLegacyInteractionPolicyIsRestoredAfterFailure() throws {
    var before: DarwinBoolean = true
    XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&before), errSecSuccess)
    XCTAssertThrowsError(try KeychainManager.shared.readPassword(
      for: "webdav-test", allowInteraction: false, lookup: { _, _ in
        var during: DarwinBoolean = true
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&during), errSecSuccess)
        XCTAssertFalse(during.boolValue)
        return errSecAuthFailed
      }))
    var after: DarwinBoolean = false
    XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
    XCTAssertEqual(after.boolValue, before.boolValue)
  }

  func testLockedLegacyKeychainFailsWithoutPrompt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("test.keychain").path
    let password = "test-keychain-password"
    var keychain: SecKeychain?
    let status = password.withCString { bytes in
      SecKeychainCreate(path, UInt32(password.utf8.count), bytes, false, nil, &keychain)
    }
    XCTAssertEqual(status, errSecSuccess)
    let temporaryKeychain = try XCTUnwrap(keychain)
    defer { SecKeychainDelete(temporaryKeychain) }
    let service = "com.teleportlabs.dayflow.apikeys.webdav-test"
    let account = "webdav-test"
    let added = SecItemAdd([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: Data("dummy-password".utf8),
      kSecUseKeychain as String: temporaryKeychain,
    ] as CFDictionary, nil)
    XCTAssertEqual(added, errSecSuccess)
    let saved = try KeychainManager.shared.readPassword(
      for: account, allowInteraction: false, lookup: { query, result in
        var scoped = query as! [String: Any]
        scoped[kSecMatchSearchList as String] = [temporaryKeychain]
        return KeychainManager.copyLegacyPassword(scoped as CFDictionary, result)
      })
    XCTAssertEqual(saved, "dummy-password")
    XCTAssertEqual(SecKeychainLock(temporaryKeychain), errSecSuccess)
    XCTAssertThrowsError(try KeychainManager.shared.readPassword(
      for: account, allowInteraction: false, lookup: { query, result in
        var scoped = query as! [String: Any]
        scoped[kSecMatchSearchList as String] = [temporaryKeychain]
        return KeychainManager.copyLegacyPassword(scoped as CFDictionary, result)
      })) {
      XCTAssertEqual($0 as? KeychainManager.ReadError, .status(errSecInteractionNotAllowed))
    }
  }

  func testCredentialReadDistinguishesMissingDeniedAndInvalidData() throws {
    XCTAssertNil(try KeychainManager.shared.readPassword(
      for: "webdav-test", allowInteraction: false, lookup: { _, _ in errSecItemNotFound }))
    for status in [errSecAuthFailed, errSecUserCanceled, errSecNotAvailable] {
      XCTAssertThrowsError(try KeychainManager.shared.readPassword(
        for: "webdav-test", allowInteraction: false, lookup: { _, _ in status })) {
        XCTAssertEqual($0 as? KeychainManager.ReadError, .status(status))
      }
    }
    XCTAssertThrowsError(try KeychainManager.shared.readPassword(
      for: "webdav-test", allowInteraction: false, lookup: { _, result in
        result?.pointee = Data([0xff]) as CFData
        return errSecSuccess
      })) {
      XCTAssertEqual($0 as? KeychainManager.ReadError, .invalidData)
    }
  }

  func testExplicitCredentialReadAllowsInteraction() throws {
    let value = try KeychainManager.shared.readPassword(
      for: "webdav-test", allowInteraction: true, lookup: { query, result in
        XCTAssertNil((query as NSDictionary)[kSecUseAuthenticationContext])
        result?.pointee = Data("sample".utf8) as CFData
        return errSecSuccess
      })
    XCTAssertEqual(value, "sample")
  }

  func testRetriesTransientResponsesWithBoundedAttempts() async throws {
    let stub = DAVStub { request in
      .init(status: request.index < 2 ? 503 : 207, headers: ["Retry-After": "0"])
    }
    let service = makeService(stub)
    try await service.testConnection(configuration: configuration)
    XCTAssertEqual(stub.methods, ["PROPFIND", "PROPFIND", "PROPFIND"])
  }

  func testRetriesNetworkDisconnect() async throws {
    let stub = DAVStub { request in
      if request.index == 0 { throw URLError(.networkConnectionLost) }
      return .init(status: 207)
    }
    try await makeService(stub).testConnection(configuration: configuration)
    XCTAssertEqual(stub.requests.count, 2)
  }

  func testRetryExhaustionAndLongRetryAfterStop() async throws {
    for headers in [[:], ["Retry-After": "3600"]] {
      let stub = DAVStub { _ in .init(status: 429, headers: headers) }
      do {
        try await makeService(stub).testConnection(configuration: configuration)
        XCTFail("Expected rate limit error")
      } catch {
        XCTAssertEqual(stub.requests.count, headers.isEmpty ? 3 : 1)
      }
    }
  }

  func testRetryAfterHTTPDateAndInvalidValues() {
    let date = Date(timeIntervalSince1970: 0)
    for (value, expected) in [("Thu, 01 Jan 1970 00:00:10 GMT", 10.0), ("invalid", 2.0), ("-1", 0.0)] {
      let response = HTTPURLResponse(url: configuration.normalizedServerURL!, statusCode: 503,
        httpVersion: nil, headerFields: ["Retry-After": value])!
      XCTAssertEqual(WebDAVTimelineSyncService.retryDelay(response: response, attempt: 1, now: date), expected)
    }
  }

  func testRedirectResponsesNeverPublishOrSave() async throws {
    let stub = DAVStub { _ in .init(status: 302, headers: ["Location": "https://other.invalid/"]) }
    do {
      try await makeService(stub).testAndSave(configuration: configuration, automaticSync: false) { _, _ in
        XCTFail("A redirect is not a successful connection")
      }
      XCTFail("Expected redirect rejection")
    } catch {
      XCTAssertEqual(error as? WebDAVTimelineSyncError, .redirected)
      XCTAssertEqual(stub.requests.count, 1)
    }
  }

  func testRedirectDelegateRejectsCrossOriginAndMethodChanges() async {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: configuration.remoteFileURL!)
    for target in [configuration.remoteFileURL!, URL(string: "https://other.invalid/")!] {
      let done = expectation(description: "redirect rejected")
      let response = HTTPURLResponse(url: configuration.remoteFileURL!, statusCode: 302,
        httpVersion: nil, headerFields: nil)!
      WebDAVRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: target)) { next in
          XCTAssertNil(next)
          done.fulfill()
        }
      await fulfillment(of: [done], timeout: 1)
    }
  }

  func testConnectionUsesCanonicalDirectoryAndTrimmedUsername() async throws {
    var config = configuration
    config.serverURL = "https://webdav.invalid/root"
    config.username = " test \n"
    let stub = DAVStub { _ in .init(status: 207) }
    try await makeService(stub).testConnection(configuration: config)
    XCTAssertEqual(stub.requests.first?.request.url?.path, "/root")
    XCTAssertEqual(stub.requests.first?.request.url?.absoluteString, "https://webdav.invalid/root/")
    XCTAssertEqual(stub.requests.first?.request.value(forHTTPHeaderField: "Authorization"),
      "Basic " + Data("test:test".utf8).base64EncodedString())
  }

  func testMediaFailureStillPublishesTimelineAndPreservesPreviousIndex() async throws {
    let previous = Self.manifest
    let stub = snapshotStub(previous: previous)
    var config = configuration
    config.includeMedia = true
    do {
      try await makeService(stub, media: { _, _, _ in throw URLError(.cannotConnectToHost) }).sync(configuration: config)
      XCTFail("Expected partial sync")
    } catch WebDAVTimelineSyncError.mediaIncomplete {
      let uploads = try publishedSnapshots(stub)
      XCTAssertEqual(uploads.count, 1)
      XCTAssertEqual(uploads.first?.source.appVersion, "test-new")
      XCTAssertEqual(uploads.first?.media, previous)
    }
  }

  func testFirstSyncMediaFailureDoesNotInventMediaReferences() async throws {
    let stub = snapshotStub(previous: nil)
    var config = configuration
    config.includeMedia = true
    do {
      try await makeService(stub, media: { _, _, _ in throw URLError(.timedOut) }).sync(configuration: config)
      XCTFail("Expected partial sync")
    } catch WebDAVTimelineSyncError.mediaIncomplete {
      let uploads = try publishedSnapshots(stub)
      XCTAssertEqual(uploads.count, 1)
      XCTAssertNil(uploads.first?.media)
    }
  }

  func testCompletedMediaIsPublishedOnlyAfterUpload() async throws {
    let stub = snapshotStub(previous: nil)
    var config = configuration
    config.includeMedia = true
    let service = makeService(stub, media: { _, _, _ in
      XCTAssertEqual(stub.methods.filter { $0 == "PUT" }.count, 1)
      return Self.manifest
    })
    let count = try await service.sync(configuration: config)
    XCTAssertEqual(count, 0)
    let uploads = try publishedSnapshots(stub)
    XCTAssertEqual(uploads.count, 2)
    XCTAssertNil(uploads.first?.media)
    XCTAssertEqual(uploads.last?.media, Self.manifest)
  }

  func testDisablingMediaKeepsExistingRemoteIndex() async throws {
    let stub = snapshotStub(previous: Self.manifest)
    _ = try await makeService(stub, media: { _, _, _ in
      XCTFail("Disabled media must not upload")
      return Self.manifest
    }).sync(configuration: configuration)
    XCTAssertEqual(try publishedSnapshots(stub).first?.media, Self.manifest)
  }

  func testUnreadablePreviousIndexDoesNotOverwriteRemoteData() async throws {
    let stub = DAVStub { request in
      request.request.httpMethod == "GET"
        ? .init(status: 200, body: Data("not-json".utf8)) : .init(status: 201)
    }
    do {
      try await makeService(stub).sync(configuration: configuration)
      XCTFail("Expected decode failure")
    } catch {
      XCTAssertFalse(stub.methods.contains("PUT"))
    }
  }

  func testCancelAndConcurrentSyncDoNotLeakOrQueueUploads() async throws {
    let stub = snapshotStub(previous: Self.manifest)
    let started = expectation(description: "media started")
    let service = makeService(stub, media: { _, _, _ in
      started.fulfill()
      try await Task.sleep(nanoseconds: 60_000_000_000)
      XCTFail("Cancelled media must not complete")
      return Self.manifest
    })
    var config = configuration
    config.includeMedia = true
    let task = Task { try await service.sync(configuration: config) }
    await fulfillment(of: [started], timeout: 3)
    do {
      try await service.sync(configuration: config)
      XCTFail("Concurrent sync must not start another upload")
    } catch {
      XCTAssertEqual(error as? WebDAVTimelineSyncError, .alreadySyncing)
    }
    await service.cancelSync()
    do {
      _ = try await task.value
      XCTFail("Expected cancelled partial sync")
    } catch WebDAVTimelineSyncError.mediaIncomplete {
      XCTAssertEqual(try publishedSnapshots(stub).count, 1)
    }
    _ = try await service.sync(configuration: configuration)
    XCTAssertEqual(try publishedSnapshots(stub).count, 2)
  }

  func testUnsupportedHEADFallsBackToPUTButAuthenticationDoesNot() async throws {
    let asset = WebDAVMediaManifest.asset(data: Data("test".utf8), extension: "jpg", mimeType: "image/jpeg")
    for status in [405, 501, 401, 403] {
      let stub = DAVStub { request in
        .init(status: request.request.httpMethod == "HEAD" ? status : 201)
      }
      do {
        try await makeService(stub).uploadAsset(asset, data: Data("test".utf8),
          base: configuration.normalizedServerURL!, configuration: configuration)
        XCTAssertTrue([405, 501].contains(status))
        XCTAssertEqual(stub.methods, ["HEAD", "PUT"])
      } catch {
        XCTAssertTrue([401, 403].contains(status))
        XCTAssertEqual(stub.methods, ["HEAD"])
      }
    }
  }

  func testMissingMediaIsSkippedButOtherReadErrorsSurface() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let data = try await WebDAVTimelineSyncService.readMediaFile(missing)
    XCTAssertNil(data)
    do {
      _ = try await WebDAVTimelineSyncService.readMediaFile(FileManager.default.temporaryDirectory)
      XCTFail("Reading a directory must not be silently skipped")
    } catch {}
  }

  @MainActor
  func testDebugUpdaterNeverStartsChecking() {
    #if DEBUG
      let updater = UpdaterManager.shared
      updater.checkForUpdates()
      XCTAssertFalse(updater.isChecking)
      XCTAssertFalse(updater.updateAvailable)
      XCTAssertEqual(updater.statusText, UpdaterManager.localBuildNotice)
    #endif
  }

  func testDailySnapshotsStayInDateDirectoriesAndPrecedeMedia() async throws {
    let stub = snapshotStub(previous: nil)
    var configuration = configuration
    configuration.includeMedia = true
    let service = makeService(stub, snapshot: Self.twoDaySnapshot, media: { config, _, shots in
      XCTAssertEqual(stub.methods.filter { $0 == "PUT" }.count >= 2, true)
      XCTAssertTrue(["2026-09-29", "2026-09-30"].contains(config.remoteFileURL!.deletingLastPathComponent().lastPathComponent))
      XCTAssertTrue(shots.isEmpty)
      return .init(version: 1, assets: [], frames: [], thumbnails: [])
    })
    _ = try await service.sync(configuration: configuration)
    let writes = stub.requests.filter { $0.request.httpMethod == "PUT" }
    XCTAssertEqual(writes.map { $0.request.url!.path }, [
      "/root/Dayflow/2026-09-30/timeline.json", "/root/Dayflow/2026-09-29/timeline.json",
      "/root/Dayflow/2026-09-30/timeline.json", "/root/Dayflow/2026-09-29/timeline.json",
    ])
    let snapshots = try publishedSnapshots(stub)
    XCTAssertEqual(snapshots.map { $0.standups.map(\.day) }, [
      ["2026-09-30"], ["2026-09-29"], ["2026-09-30"], ["2026-09-29"],
    ])
    XCTAssertFalse(stub.requests.contains { $0.request.url!.path == "/root/Dayflow/timeline.json" })
    XCTAssertFalse(stub.requests.contains { $0.request.url!.path.hasPrefix("/root/Dayflow/media") })
  }

  func testFailedDayDoesNotBlockOtherDailyTimelines() async throws {
    let stub = DAVStub { request in
      if request.request.httpMethod == "GET" { return .init(status: 404) }
      if request.request.httpMethod == "PUT", request.request.url!.path.contains("2026-09-30") {
        return .init(status: 507)
      }
      return .init(status: 201)
    }
    do {
      try await makeService(stub, snapshot: Self.twoDaySnapshot).sync(configuration: configuration)
      XCTFail("Expected a partial daily backup failure")
    } catch WebDAVTimelineSyncError.dailyBackupsIncomplete(let message) {
      XCTAssertTrue(message.contains("2026-09-30"))
      XCTAssertTrue(stub.requests.contains {
        $0.request.httpMethod == "PUT" && $0.request.url!.path == "/root/Dayflow/2026-09-29/timeline.json"
      })
    }
  }

  func testMediaFailureInOneDayStillUploadsOtherDays() async throws {
    let stub = snapshotStub(previous: nil)
    var config = configuration
    config.includeMedia = true
    let service = makeService(stub, snapshot: Self.twoDaySnapshot, media: { daily, _, _ in
      if daily.remoteFileURL!.path.contains("2026-09-30") {
        throw WebDAVTimelineSyncError.requestFailed(method: "PUT", statusCode: 507, message: nil)
      }
      return Self.manifest
    })
    do {
      try await service.sync(configuration: config)
      XCTFail("Expected incomplete media")
    } catch WebDAVTimelineSyncError.mediaIncomplete(let message) {
      XCTAssertTrue(message.contains("2026-09-30"))
      let snapshots = try publishedSnapshots(stub)
      XCTAssertEqual(snapshots.count, 3)
      XCTAssertEqual(snapshots.last?.standups.first?.day, "2026-09-29")
      XCTAssertEqual(snapshots.last?.media, Self.manifest)
    }
  }

  func testAuthenticationFailureStopsAllDailyRequests() async throws {
    let stub = DAVStub { request in
      request.request.httpMethod == "GET" ? .init(status: 401) : .init(status: 201)
    }
    do {
      try await makeService(stub, snapshot: Self.twoDaySnapshot).sync(configuration: configuration)
      XCTFail("Expected authentication failure")
    } catch {
      XCTAssertFalse(stub.methods.contains("PUT"))
      XCTAssertFalse(stub.requests.contains { $0.request.url!.path.contains("2026-09-29") })
    }
  }

  func testNoDataDoesNotWriteMixedOrEmptySnapshot() async throws {
    let empty = WebDAVTimelineSnapshot(schemaVersion: 1, generatedAt: Date(), source: Self.snapshot.source,
      categories: [], activities: [], standups: [])
    let stub = snapshotStub(previous: nil)
    let count = try await makeService(stub, snapshot: empty).sync(configuration: configuration)
    XCTAssertEqual(count, 0)
    XCTAssertFalse(stub.methods.contains("PUT"))
    XCTAssertFalse(stub.methods.contains("GET"))
  }

  func testPreviousMediaIndexesArePreservedSeparatelyPerDay() async throws {
    let stub = DAVStub { request in
      guard request.request.httpMethod == "GET" else { return .init(status: 201) }
      let day = request.request.url!.deletingLastPathComponent().lastPathComponent
      var old = Self.snapshot
      old.media = .init(version: 1,
        assets: [.init(id: day, path: "media/\(day).jpg", mimeType: "image/jpeg", byteCount: 3)],
        frames: [], thumbnails: [])
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      return .init(status: 200, body: try encoder.encode(old))
    }
    _ = try await makeService(stub, snapshot: Self.twoDaySnapshot).sync(configuration: configuration)
    let snapshots = try publishedSnapshots(stub)
    XCTAssertEqual(snapshots.map { $0.media?.assets.first?.id }, ["2026-09-30", "2026-09-29"])
    XCTAssertFalse(stub.requests.contains { $0.request.url!.path.contains("/media") })
  }

  func testCrossDayVideoIsUploadedToBothDateDirectories() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("cross-day.mp4")
    let bytes = Data("synthetic-video-payload".utf8)
    try bytes.write(to: file)
    let date = ISO8601DateFormatter().date(from: "2026-09-30T04:00:00Z")!
    let shots = [
      Screenshot(id: 1, capturedAt: Int(date.timeIntervalSince1970) - 1, filePath: file.path,
        fileSize: Int64(bytes.count), idleSecondsAtCapture: nil, isDeleted: false, frameIndex: 5),
      Screenshot(id: 2, capturedAt: Int(date.timeIntervalSince1970), filePath: file.path,
        fileSize: Int64(bytes.count), idleSecondsAtCapture: nil, isDeleted: false, frameIndex: 6),
    ]
    let stub = DAVStub { request in
      ["GET", "HEAD"].contains(request.request.httpMethod ?? "") ? .init(status: 404) : .init(status: 201)
    }
    var config = configuration
    config.includeMedia = true
    _ = try await makeService(stub, snapshot: Self.twoDaySnapshot, screenshots: shots).sync(configuration: config)
    let mediaWrites = stub.requests.filter { $0.request.httpMethod == "PUT" && $0.request.url!.pathExtension == "mp4" }
    XCTAssertEqual(mediaWrites.count, 2)
    XCTAssertEqual(Set(mediaWrites.map { $0.request.url!.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }),
      Set(["2026-09-29", "2026-09-30"]))
    XCTAssertTrue(mediaWrites.allSatisfy { $0.body == bytes })
    let manifests = try publishedSnapshots(stub).compactMap(\.media)
    XCTAssertEqual(manifests.count, 2)
    XCTAssertEqual(manifests[0].frames.map(\.frameIndex), [6])
    XCTAssertEqual(manifests[1].frames.map(\.frameIndex), [5])
    XCTAssertTrue(manifests.allSatisfy { $0.assets.allSatisfy { $0.path.hasPrefix("media/") } })
  }

  private static var twoDaySnapshot: WebDAVTimelineSnapshot {
    .init(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 0), source: snapshot.source,
      categories: [], activities: [], standups: [
        .init(day: "2026-09-29", payload: "{}", createdAt: nil, updatedAt: nil),
        .init(day: "2026-09-30", payload: "{}", createdAt: nil, updatedAt: nil),
      ])
  }

  private func makeService(_ stub: DAVStub,
    snapshot: WebDAVTimelineSnapshot = WebDAVReliabilityTests.snapshot,
    screenshots: [Screenshot] = [],
    media: (@Sendable (WebDAVConfiguration, [WebDAVTimelineSnapshot.Activity], [Screenshot]) async throws -> WebDAVMediaManifest)? = nil,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
  ) -> WebDAVTimelineSyncService {
    let id = UUID().uuidString
    DAVProtocol.register(stub, id: id)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DAVProtocol.self]
    config.httpAdditionalHeaders = ["X-Test-ID": id]
    let session = URLSession(configuration: config)
    sessions.append((session, id))
    return WebDAVTimelineSyncService(session: session, reportsStatus: false,
      snapshotProvider: { snapshot }, screenshotsProvider: { screenshots },
      mediaProvider: media, retrySleep: sleep)
  }

  private func snapshotStub(previous: WebDAVMediaManifest?) -> DAVStub {
    DAVStub { request in
      if request.request.httpMethod == "GET" {
        guard let previous else { return .init(status: 404) }
        var snapshot = Self.snapshot
        snapshot.media = previous
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return .init(status: 200, body: try encoder.encode(snapshot))
      }
      return .init(status: 201)
    }
  }

  private func publishedSnapshots(_ stub: DAVStub) throws -> [WebDAVTimelineSnapshot] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try stub.requests.filter {
      $0.request.httpMethod == "PUT" && $0.request.url?.lastPathComponent == "timeline.json"
    }
      .map { try decoder.decode(WebDAVTimelineSnapshot.self, from: $0.body) }
  }

  private static var snapshot: WebDAVTimelineSnapshot {
    .init(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 0),
      source: .init(app: "Dayflow", appVersion: "test-new", timeZone: "UTC"),
      categories: [], activities: [],
      standups: [.init(day: "1970-01-01", payload: "{}", createdAt: nil, updatedAt: nil)])
  }

  private static var manifest: WebDAVMediaManifest {
    .init(version: 1, assets: [.init(id: "old", path: "media/old.jpg", mimeType: "image/jpeg", byteCount: 3)],
      frames: [], thumbnails: [])
  }
}

private final class DAVStub: @unchecked Sendable {
  struct Request {
    let request: URLRequest
    let body: Data
    let index: Int
  }
  struct Response {
    let status: Int
    var headers: [String: String] = [:]
    var body = Data()
  }
  private let lock = NSLock()
  private var recorded: [Request] = []
  private let handler: (Request) throws -> Response
  init(_ handler: @escaping (Request) throws -> Response) { self.handler = handler }
  var requests: [Request] { lock.withLock { recorded } }
  var methods: [String] { requests.map { $0.request.httpMethod ?? "" } }
  func respond(to request: URLRequest) throws -> Response {
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(contentsOf: buffer.prefix(count))
      }
    }
    let record = lock.withLock {
      let entry = Request(request: request, body: body, index: recorded.count)
      recorded.append(entry)
      return entry
    }
    return try handler(record)
  }
}

private final class DAVProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var stubs: [String: DAVStub] = [:]
  static func register(_ stub: DAVStub, id: String) { lock.withLock { stubs[id] = stub } }
  static func remove(_ id: String) { _ = lock.withLock { stubs.removeValue(forKey: id) } }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let id = request.value(forHTTPHeaderField: "X-Test-ID") ?? ""
      guard let stub = Self.lock.withLock({ Self.stubs[id] }) else { throw URLError(.badURL) }
      let reply = try stub.respond(to: request)
      let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
        httpVersion: "HTTP/1.1", headerFields: reply.headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: reply.body)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  override func stopLoading() {}
}
