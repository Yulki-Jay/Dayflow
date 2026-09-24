import XCTest

@testable import Dayflow

final class WebDAVTimelineSyncTests: XCTestCase {
  func testWebDAVTranslationsAreBundled() throws {
    let keys = [
      "WebDAV timeline sync",
      "Publish a web-friendly backup that can be read on other devices.",
      "Server URL",
      "Username",
      "WebDAV username",
      "Password",
      "Stored in Keychain",
      "Remote sync folder",
      "Automatic sync",
      "Upload on launch and every 15 minutes",
      "Sync screenshots and videos",
      "Upload recorded screen content and card thumbnails. About 50–100 MB per 8-hour day at default settings.",
      "The sync folder contains timeline data and a media subfolder. Enabling media sync uploads retained recordings and thumbnails; completed files are skipped. Files are not end-to-end encrypted. Turning media sync off does not delete uploaded files. Use a separate folder for each recording Mac.",
      "Working…",
      "Sync now",
      "Save & test",
      "Last synced %@",
      "Enter a valid HTTP or HTTPS WebDAV URL.",
      "Enter your WebDAV username.",
      "Enter your WebDAV password.",
      "Enter a folder relative to the server URL, not a JSON filename.",
      "Couldn't save the WebDAV password to Keychain.",
      "The WebDAV server returned an invalid response.",
      "A WebDAV sync is already running. Please try again when it finishes.",
      "WebDAV %@ failed (HTTP %lld).",
      "WebDAV %@ failed (HTTP %lld): %@",
      "Connection successful. Settings saved.",
      "Synced %lld timeline activities."
]
    for language in ["zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "ru"] {
      let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
      let bundle = try XCTUnwrap(Bundle(path: path))
      for key in keys {
        XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "__missing__", table: nil),
          "__missing__", "\(language): \(key)")
      }
    }
  }
  func testLegacyLocationMigration() {
    let custom = WebDAVTimelinePreferences.migratedLocation(from: "/Dayflow/Mac/custom.json")
    XCTAssertEqual(custom.directory, "Dayflow/Mac")
    XCTAssertEqual(custom.filename, "custom.json")
    XCTAssertEqual(WebDAVTimelinePreferences.migratedLocation(from: "timeline.json").directory, "")
    XCTAssertEqual(WebDAVTimelinePreferences.migratedLocation(from: "Dayflow/").directory, "Dayflow")
  }

  func testMediaHashAndRelativePath() {
    let asset = WebDAVMediaManifest.asset(data: Data("abc".utf8), extension: "mp4", mimeType: "video/mp4")
    XCTAssertEqual(asset.id, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertEqual(asset.path, "media/\(asset.id).mp4")
    XCTAssertEqual(asset.byteCount, 3)
  }

  func testMediaUploadSkipsExistingAndRepairsWrongSize() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WebDAVTestProtocol.self]
    let service = WebDAVTimelineSyncService(session: URLSession(configuration: config))
    let configuration = WebDAVConfiguration(serverURL: "https://dav.example.com",
      username: "test", password: "test", remotePath: "Dayflow")
    let bytes = Data("abc".utf8)
    let asset = WebDAVMediaManifest.asset(data: bytes, extension: "mp4", mimeType: "video/mp4")
    for (size, expected) in [(3, ["HEAD"]), (1, ["HEAD", "PUT"]), (-1, ["HEAD", "PUT"])] {
      WebDAVTestProtocol.methods = []
      WebDAVTestProtocol.headSize = size
      try await service.uploadAsset(asset, data: bytes,
        base: configuration.remoteFileURL!.deletingLastPathComponent(), configuration: configuration)
      XCTAssertEqual(WebDAVTestProtocol.methods, expected)
    }
    WebDAVTestProtocol.methods = []
    WebDAVTestProtocol.headSize = -2
    do {
      try await service.uploadAsset(asset, data: bytes,
        base: configuration.remoteFileURL!.deletingLastPathComponent(), configuration: configuration)
      XCTFail("Authentication failure should stop upload")
    } catch {
      XCTAssertEqual(WebDAVTestProtocol.methods, ["HEAD"])
    }
  }

  func testBuildsRemoteFileURLWithoutEmbeddingCredentials() {
    let configuration = WebDAVConfiguration(
      serverURL: "https://dav.example.com/remote.php/dav/files/alice/",
      username: "alice",
      password: "secret",
      remotePath: "/Dayflow/"
    )

    XCTAssertEqual(
      configuration.remoteFileURL?.absoluteString,
      "https://dav.example.com/remote.php/dav/files/alice/Dayflow/timeline.json"
    )
    XCTAssertNil(configuration.remoteFileURL?.user)
    XCTAssertNil(configuration.remoteFileURL?.password)
  }

  func testRejectsUnsupportedURLAndJSONFilename() {
    var configuration = WebDAVConfiguration(
      serverURL: "ftp://dav.example.com",
      username: "alice",
      password: "secret",
      remotePath: "Dayflow/timeline.json"
    )
    XCTAssertNotNil(configuration.validationMessage)

    configuration.serverURL = "https://dav.example.com"
    configuration.remotePath = "Dayflow/timeline.json"
    XCTAssertNotNil(configuration.validationMessage)
    configuration.remotePath = "Dayflow/Mac"
    XCTAssertNil(configuration.validationMessage)
  }

  func testSanitizesRemotePathTraversalComponents() {
    let configuration = WebDAVConfiguration(
      serverURL: "https://dav.example.com/root",
      username: "alice",
      password: "secret",
      remotePath: "../Dayflow/./"
    )

    XCTAssertNotNil(configuration.validationMessage)
    XCTAssertEqual(configuration.normalizedRemotePathComponents, ["Dayflow"])
    XCTAssertEqual(
      configuration.remoteDirectoryURLs.map(\.absoluteString),
      ["https://dav.example.com/root/Dayflow/"]
    )
  }

  func testRootFolderAndPreservedCustomFilename() {
    var configuration = WebDAVConfiguration(serverURL: "https://dav.example.com/root/",
      username: "alice", password: "secret", remotePath: "/")
    XCTAssertNil(configuration.validationMessage)
    XCTAssertEqual(configuration.remoteFileURL?.absoluteString, "https://dav.example.com/root/timeline.json")
    XCTAssertTrue(configuration.remoteDirectoryURLs.isEmpty)
    configuration.remotePath = "Dayflow/My Mac"
    configuration.snapshotFilename = "custom.json"
    XCTAssertEqual(configuration.remoteFileURL?.lastPathComponent, "custom.json")
    XCTAssertEqual(configuration.remoteDirectoryURLs.count, 2)
  }

  func testSnapshotUsesISO8601DatesAndStableSchemaVersion() throws {
    let activity = WebDAVTimelineSnapshot.Activity(
      id: 42,
      startAt: Date(timeIntervalSince1970: 1_700_000_000),
      endAt: Date(timeIntervalSince1970: 1_700_000_900),
      day: "2023-11-14",
      startTime: "10:13 PM",
      endTime: "10:28 PM",
      category: "Coding",
      subcategory: "Tests",
      title: "Verify WebDAV export",
      summary: "Added coverage",
      detailedSummary: "Added deterministic export coverage.",
      distractions: nil,
      appSites: AppSites(primary: "Xcode", secondary: nil)
    )
    let snapshot = WebDAVTimelineSnapshot(
      schemaVersion: 1,
      generatedAt: Date(timeIntervalSince1970: 1_700_000_901),
      source: .init(app: "Dayflow", appVersion: "1.0", timeZone: "UTC"),
      categories: [],
      activities: [activity],
      standups: []
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]

    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any]
    )
    XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    let activities = try XCTUnwrap(object["activities"] as? [[String: Any]])
    XCTAssertEqual(activities.first?["startAt"] as? String, "2023-11-14T22:13:20Z")
  }
}

private final class WebDAVTestProtocol: URLProtocol {
  static var methods: [String] = []
  static var headSize = 3
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.methods.append(request.httpMethod ?? "")
    let isHead = request.httpMethod == "HEAD"
    let status = isHead ? (Self.headSize == -2 ? 401 : (Self.headSize == -1 ? 404 : 200)) : 201
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": String(max(0, Self.headSize))])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
