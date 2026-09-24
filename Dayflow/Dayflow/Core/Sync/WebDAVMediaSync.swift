import CryptoKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// Paths are relative to timeline.json. Frame presentation time is frameIndex seconds,
/// while capturedAt records the actual wall-clock time.
struct WebDAVMediaManifest: Codable, Sendable, Equatable {
  struct Asset: Codable, Sendable, Equatable {
    let id: String
    let path: String
    let mimeType: String
    let byteCount: Int
  }
  struct Frame: Codable, Sendable, Equatable {
    let id: Int64
    let capturedAt: Date
    let assetID: String
    let frameIndex: Int?
  }
  struct Thumbnail: Codable, Sendable, Equatable {
    let activityID: Int64
    let assetID: String
  }
  let version: Int
  let assets: [Asset]
  let frames: [Frame]
  let thumbnails: [Thumbnail]

  static func asset(data: Data, extension suffix: String, mimeType: String) -> Asset {
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return Asset(id: hash, path: "media/\(hash).\(suffix)", mimeType: mimeType, byteCount: data.count)
  }
}

extension StorageManager {
  func webDAVScreenshots() throws -> [Screenshot] {
    try timedRead("webDAVScreenshots") { db in
      try Row.fetchAll(db, sql: """
        SELECT * FROM screenshots WHERE is_deleted = 0 AND file_size IS NOT NULL
        ORDER BY captured_at, id
        """).map { row in
          Screenshot(id: row["id"], capturedAt: row["captured_at"],
            filePath: row["file_path"], fileSize: row["file_size"],
            idleSecondsAtCapture: nil, isDeleted: false, frameIndex: row["frame_index"])
        }
    }
  }
}

extension WebDAVTimelineSyncService {
  func uploadMedia(configuration: WebDAVConfiguration,
    activities: [WebDAVTimelineSnapshot.Activity]) async throws -> WebDAVMediaManifest {
    guard let base = configuration.remoteFileURL?.deletingLastPathComponent() else {
      throw WebDAVTimelineSyncError.invalidResponse
    }
    let directory = base.appendingPathComponent("media", isDirectory: true)
    let request = authenticatedRequest(url: directory, method: "MKCOL", configuration: configuration)
    let (data, response) = try await session.data(for: request)
    if (response as? HTTPURLResponse)?.statusCode != 405 {
      try validateResponse(response, data: data, method: "MKCOL", accepted: 200..<300)
    }

    // Only finalized segments have file_size populated. Never upload the active writer.
    let screenshots = try StorageManager.shared.webDAVScreenshots()
    var assets: [String: WebDAVMediaManifest.Asset] = [:]
    var paths: [String: String] = [:]
    var frames: [WebDAVMediaManifest.Frame] = []
    var thumbnails: [WebDAVMediaManifest.Thumbnail] = []
    for screenshot in screenshots {
      try Task.checkCancellation()
      if paths[screenshot.filePath] == nil {
        // A segment can have been removed by storage maintenance since the DB read.
        guard FileManager.default.fileExists(atPath: screenshot.filePath) else { continue }
        let bytes = try Data(contentsOf: screenshot.fileURL)
        let isVideo = screenshot.frameIndex != nil
        let asset = WebDAVMediaManifest.asset(data: bytes,
          extension: isVideo ? "mp4" : "jpg", mimeType: isVideo ? "video/mp4" : "image/jpeg")
        if assets[asset.id] == nil {
          try await uploadAsset(asset, data: bytes, base: base, configuration: configuration)
          assets[asset.id] = asset
        }
        paths[screenshot.filePath] = asset.id
      }
      guard let assetID = paths[screenshot.filePath] else { continue }
      frames.append(.init(id: screenshot.id, capturedAt: screenshot.capturedDate,
        assetID: assetID, frameIndex: screenshot.frameIndex))
    }

    for activity in activities {
      try Task.checkCancellation()
      guard let shot = screenshots.first(where: {
        $0.capturedDate >= activity.startAt && $0.capturedDate < activity.endAt
          && paths[$0.filePath] != nil
      }), let image = FrameStore.shared.image(for: shot, maxPixelSize: 640) else { continue }
      let output = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
      else { continue }
      CGImageDestinationAddImage(destination, image,
        [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { continue }
      let bytes = output as Data
      let asset = WebDAVMediaManifest.asset(data: bytes, extension: "jpg", mimeType: "image/jpeg")
      if assets[asset.id] == nil {
        try await uploadAsset(asset, data: bytes, base: base, configuration: configuration)
        assets[asset.id] = asset
      }
      thumbnails.append(.init(activityID: activity.id, assetID: asset.id))
    }
    return .init(version: 1, assets: assets.values.sorted { $0.id < $1.id },
      frames: frames, thumbnails: thumbnails)
  }

  func uploadAsset(_ asset: WebDAVMediaManifest.Asset, data: Data, base: URL,
    configuration: WebDAVConfiguration) async throws {
    let url = base.appendingPathComponent(asset.path)
    var head = authenticatedRequest(url: url, method: "HEAD", configuration: configuration)
    head.cachePolicy = .reloadIgnoringLocalCacheData
    let (headData, response) = try await session.data(for: head)
    guard let http = response as? HTTPURLResponse else { throw WebDAVTimelineSyncError.invalidResponse }
    if http.statusCode == 200, http.expectedContentLength == Int64(asset.byteCount) { return }
    if http.statusCode != 404 && http.statusCode != 200 {
      try validateResponse(response, data: headData, method: "HEAD", accepted: 200..<300)
    }
    var put = authenticatedRequest(url: url, method: "PUT", configuration: configuration)
    put.timeoutInterval = 300
    put.setValue(asset.mimeType, forHTTPHeaderField: "Content-Type")
    let (body, result) = try await session.upload(for: put, from: data)
    try validateResponse(result, data: body, method: "PUT", accepted: 200..<300)
  }
}
