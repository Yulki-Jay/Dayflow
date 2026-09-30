import XCTest

@testable import Dayflow

final class WebDAVDailyBackupTests: XCTestCase {
  func testTimelineAndStandupsUseTheirSavedDay() throws {
    let activity = Self.activity(day: "2026-09-29", start: "2026-09-30T01:00:00+08:00")
    let snapshot = Self.snapshot(activities: [activity], standups: [
      .init(day: "2026-09-28", payload: "{}", createdAt: nil, updatedAt: nil)
    ])
    let backups = try WebDAVDailyBackup.group(snapshot: snapshot, screenshots: [])
    XCTAssertEqual(backups.map(\.day), ["2026-09-29", "2026-09-28"])
    XCTAssertEqual(backups[0].snapshot.activities.map(\.id), [activity.id])
    XCTAssertTrue(backups[0].snapshot.standups.isEmpty)
    XCTAssertTrue(backups[1].snapshot.activities.isEmpty)
    XCTAssertEqual(backups[1].snapshot.standups.map(\.day), ["2026-09-28"])
    XCTAssertEqual(backups[0].snapshot.source, snapshot.source)
    XCTAssertEqual(backups[0].snapshot.generatedAt, snapshot.generatedAt)
  }

  func testFramesSplitAtFourAMNotMidnight() throws {
    let frames = [
      Self.shot(1, at: "2026-09-30T00:00:00+08:00"),
      Self.shot(2, at: "2026-09-30T03:59:59+08:00"),
      Self.shot(3, at: "2026-09-30T04:00:00+08:00"),
    ]
    let backups = try WebDAVDailyBackup.group(snapshot: Self.snapshot(), screenshots: frames)
    XCTAssertEqual(backups.map(\.day), ["2026-09-30", "2026-09-29"])
    XCTAssertEqual(backups[0].screenshots.map(\.id), [3])
    XCTAssertEqual(backups[1].screenshots.map(\.id), [1, 2])
    XCTAssertTrue(backups.allSatisfy { $0.snapshot.activities.isEmpty })
  }

  func testFrameGroupingUsesSnapshotTimeZone() throws {
    let snapshot = Self.snapshot(timeZone: "America/Los_Angeles")
    let backups = try WebDAVDailyBackup.group(snapshot: snapshot, screenshots: [
      Self.shot(1, at: "2026-01-02T11:59:59Z"),
      Self.shot(2, at: "2026-01-02T12:00:00Z"),
    ])
    XCTAssertEqual(backups.map(\.day), ["2026-01-02", "2026-01-01"])
    XCTAssertEqual(backups[0].screenshots.map(\.id), [2])
    XCTAssertEqual(backups[1].screenshots.map(\.id), [1])
  }

  func testFourAMIntervalsRespectDaylightSavingTime() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let spring = Self.date("2026-03-07T12:00:00-05:00").getDayInfoFor4AMBoundary(calendar: calendar)
    XCTAssertEqual(spring.dayString, "2026-03-07")
    XCTAssertEqual(spring.endOfDay.timeIntervalSince(spring.startOfDay), 23 * 3600)
    let autumn = Self.date("2026-10-31T12:00:00-04:00").getDayInfoFor4AMBoundary(calendar: calendar)
    XCTAssertEqual(autumn.dayString, "2026-10-31")
    XCTAssertEqual(autumn.endOfDay.timeIntervalSince(autumn.startOfDay), 25 * 3600)
    let before = Self.date("2026-03-08T03:59:59-04:00").getDayInfoFor4AMBoundary(calendar: calendar)
    XCTAssertEqual(before.dayString, "2026-03-07")
    let after = Self.date("2026-03-08T04:00:00-04:00").getDayInfoFor4AMBoundary(calendar: calendar)
    XCTAssertEqual(after.dayString, "2026-03-08")
  }

  func testNewYearBeforeFourAMBelongsToPreviousYear() throws {
    let backups = try WebDAVDailyBackup.group(snapshot: Self.snapshot(), screenshots: [
      Self.shot(1, at: "2026-01-01T03:00:00+08:00")
    ])
    XCTAssertEqual(backups.map(\.day), ["2025-12-31"])
  }

  func testCrossDayVideoKeepsOriginalFrameOffsetsInEachDay() throws {
    let first = Self.shot(1, at: "2026-09-30T03:59:59+08:00", path: "/recordings/shared.mp4", frameIndex: 20)
    let second = Self.shot(2, at: "2026-09-30T04:00:00+08:00", path: "/recordings/shared.mp4", frameIndex: 21)
    let backups = try WebDAVDailyBackup.group(snapshot: Self.snapshot(), screenshots: [second, first])
    XCTAssertEqual(backups.count, 2)
    XCTAssertEqual(backups[0].screenshots.map(\.frameIndex), [21])
    XCTAssertEqual(backups[1].screenshots.map(\.frameIndex), [20])
    XCTAssertEqual(backups[0].screenshots.first?.filePath, backups[1].screenshots.first?.filePath)
  }

  func testEmptySnapshotDoesNotInventBackupDays() throws {
    XCTAssertTrue(try WebDAVDailyBackup.group(snapshot: Self.snapshot(), screenshots: []).isEmpty)
  }

  func testActiveAndDeletedMediaAreExcluded() throws {
    let timestamp = Int(Self.date("2026-09-30T08:00:00+08:00").timeIntervalSince1970)
    let active = Screenshot(id: 1, capturedAt: timestamp, filePath: "/active.mp4",
      fileSize: nil, idleSecondsAtCapture: nil, isDeleted: false, frameIndex: 0)
    let deleted = Screenshot(id: 2, capturedAt: timestamp, filePath: "/deleted.mp4",
      fileSize: 1, idleSecondsAtCapture: nil, isDeleted: true, frameIndex: 0)
    XCTAssertTrue(try WebDAVDailyBackup.group(snapshot: Self.snapshot(), screenshots: [active, deleted]).isEmpty)
  }

  func testMalformedStoredDaysCannotEscapeBackupDirectory() {
    for day in ["../other", "2026-09-30/other", "2026-02-30", "2026-9-3", ""] {
      let snapshot = Self.snapshot(activities: [Self.activity(day: day)])
      XCTAssertThrowsError(try WebDAVDailyBackup.group(snapshot: snapshot, screenshots: [])) {
        XCTAssertEqual($0 as? WebDAVTimelineSyncError, .invalidBackupDay)
      }
    }
  }

  func testDailyURLsKeepConfiguredRootAndSnapshotName() {
    let configuration = WebDAVConfiguration(serverURL: "https://dav.invalid/root/", username: "test",
      password: "test", remotePath: "google/My Mac", snapshotFilename: "custom.json")
    let daily = configuration.forDay("2026-09-30")
    XCTAssertEqual(daily.remoteFileURL?.absoluteString,
      "https://dav.invalid/root/google/My%20Mac/2026-09-30/custom.json")
    XCTAssertEqual(daily.remoteDirectoryURLs.last?.lastPathComponent, "2026-09-30")
    XCTAssertEqual(configuration.remotePath, "google/My Mac")
  }

  func testManifestMergeRetainsArchivedMediaAndPrefersNewFrames() {
    let before = Self.date("2026-09-30T08:00:00+08:00")
    let previous = WebDAVMediaManifest(version: 1,
      assets: [.init(id: "old", path: "media/old.jpg", mimeType: "image/jpeg", byteCount: 3)],
      frames: [.init(id: 1, capturedAt: before, assetID: "old", frameIndex: nil)],
      thumbnails: [.init(activityID: 1, assetID: "old")])
    let fresh = WebDAVMediaManifest(version: 1,
      assets: [.init(id: "new", path: "media/new.jpg", mimeType: "image/jpeg", byteCount: 4)],
      frames: [.init(id: 2, capturedAt: before.addingTimeInterval(1), assetID: "new", frameIndex: nil)],
      thumbnails: [.init(activityID: 1, assetID: "new")])
    let merged = previous.merging(fresh)
    XCTAssertEqual(merged.assets.map(\.id), ["new", "old"])
    XCTAssertEqual(merged.frames.map(\.id), [1, 2])
    XCTAssertEqual(merged.thumbnails.map(\.assetID), ["new"])
    XCTAssertEqual(previous.merging(.init(version: 1, assets: [], frames: [], thumbnails: [])), previous)
    XCTAssertEqual(merged.merging(fresh), merged)
  }

  private static func snapshot(activities: [WebDAVTimelineSnapshot.Activity] = [],
    standups: [WebDAVTimelineSnapshot.Standup] = [], timeZone: String = "Asia/Shanghai"
  ) -> WebDAVTimelineSnapshot {
    .init(schemaVersion: 1, generatedAt: date("2026-09-30T12:00:00+08:00"),
      source: .init(app: "Dayflow", appVersion: "test", timeZone: timeZone),
      categories: [], activities: activities, standups: standups)
  }

  private static func activity(day: String, start: String = "2026-09-30T08:00:00+08:00") -> WebDAVTimelineSnapshot.Activity {
    .init(id: 1, startAt: date(start), endAt: date(start).addingTimeInterval(60), day: day,
      startTime: "8:00 AM", endTime: "8:01 AM", category: "Work", subcategory: "",
      title: "Test", summary: "", detailedSummary: "", distractions: nil, appSites: nil)
  }

  private static func shot(_ id: Int64, at timestamp: String, path: String = "/recordings/test.jpg",
    frameIndex: Int? = nil
  ) -> Screenshot {
    .init(id: id, capturedAt: Int(date(timestamp).timeIntervalSince1970), filePath: path,
      fileSize: 3, idleSecondsAtCapture: nil, isDeleted: false, frameIndex: frameIndex)
  }

  private static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
