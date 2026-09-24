# WebDAV timeline sync

Dayflow can publish a read-only, web-friendly snapshot of timeline data to WebDAV. Configure it under **Settings → Export → WebDAV timeline sync**.

Enter a **Remote sync folder**, relative to the WebDAV server URL (default: `Dayflow`). Dayflow manages `timeline.json` and `media/` within that folder. An empty folder or `/` uses the server URL's root. Missing folders are created with `MKCOL`, then the snapshot is replaced with `PUT`. Existing JSON-path settings automatically migrate to their parent directory and preserve the original filename so existing readers keep working. The password is stored in macOS Keychain; it is never written to preferences or the JSON file.

## Intended use

This first version is one-way: Dayflow for macOS is the writer, while a web app or another device is a reader. It is suitable for backup, dashboards, and recreating the day/week timeline. It is deliberately not a multi-writer database sync protocol.

The snapshot includes:

- timeline activities with stable database IDs and ISO 8601 start/end timestamps;
- card titles, summaries, categories, subcategories, distractions, and app/site labels;
- category names and colors;
- daily standup JSON payloads;
- the source time zone and Dayflow version.

By default it excludes media. Enable **Sync screenshots and videos** to include finalized HEVC recording segments, legacy JPEG captures, and 640-pixel card thumbnails. Raw observations, model requests/responses, API keys, credentials, and separately generated timelapse videos remain excluded.

## Media contract (optional, additive to schemaVersion 1)

`media.version` is 1. When media sync is disabled, the `media` property is absent. Existing text-only readers can ignore this property.

- `media.assets`: `{ id, path, mimeType, byteCount }`. `id` is SHA-256 of the exact file bytes. `path` is relative to the timeline JSON URL, e.g. `media/<sha256>.mp4` or `.jpg`.
- `media.frames`: `{ id, capturedAt, assetID, frameIndex? }`. `capturedAt` is ISO 8601 wall-clock time. In HEVC segments, frame N has presentation time N seconds; this is not wall-clock playback speed. A missing `frameIndex` identifies a standalone JPEG.
- `media.thumbnails`: `{ activityID, assetID }`. Join to activities by ID and assets by assetID. Missing thumbnails are valid (e.g. recordings already purged locally).

To display an activity, find its thumbnail and resolve the asset path against the JSON URL. To inspect captures, select frames within `[activity.startAt, activity.endAt)`, load their assets on demand, and seek to `frameIndex` seconds. Cache immutable assets by hash. HEVC playback depends on browser/OS support; use native decoding or an authenticated server-side H.264/JPEG conversion for unsupported clients. JPEG thumbnails work independently of HEVC support.

Media files upload before the timeline JSON. Each sync checks remote files with HEAD and skips successful responses with matching Content-Length; missing or wrong-sized files are PUT again. A failed run leaves the last published index unchanged until the final JSON PUT; retrying skips completed assets. There is no byte-range resume or automatic retry loop: an interrupted individual file is uploaded again. The server must support HEAD, MKCOL, and PUT. No credentials or local absolute file paths are exported.

The initial sync uploads all retained local captures. Subsequent runs still check their metadata, but transfer only missing media. Open segments are deferred until finalized (normally within ten minutes). This is a view of currently retained local media, not a complete restorable backup: local purging removes frames from future indexes. Uploaded files are never automatically deleted from WebDAV, including when media sync is turned off; remote retention/cleanup is manual in this version. Do not sync multiple recording Macs to the same JSON path, as the last writer replaces the snapshot.

Screen content is not end-to-end encrypted; use HTTPS and a private WebDAV account. The application does not enable media upload automatically for existing text-only users. There is no bidirectional editing or mobile/web client bundled in this change.

## JSON contract

`schemaVersion` is the compatibility boundary. Readers should reject unsupported future major schema versions rather than guessing.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-09-17T02:30:00Z",
  "source": {
    "app": "Dayflow",
    "appVersion": "1.4.0",
    "timeZone": "Asia/Shanghai"
  },
  "categories": [
    {
      "id": "F4C2906D-02D8-476E-86CA-26C05C1F6FBB",
      "name": "Coding / Debugging",
      "colorHex": "#6677F5",
      "description": "Implementation and debugging",
      "order": 0,
      "isSystem": false,
      "isIdle": false
    }
  ],
  "activities": [
    {
      "id": 42,
      "startAt": "2026-09-17T02:00:00Z",
      "endAt": "2026-09-17T02:30:00Z",
      "day": "2026-09-17",
      "startTime": "10:00 AM",
      "endTime": "10:30 AM",
      "category": "Coding / Debugging",
      "subcategory": "Implementation",
      "title": "Build WebDAV timeline sync",
      "summary": "Implemented JSON snapshot upload.",
      "detailedSummary": "Added settings, authentication, export, and upload.",
      "appSites": { "primary": "Xcode", "secondary": null }
    }
  ],
  "standups": []
}
```

Swift's JSON encoder omits optional keys whose value is `null`, so readers must treat optional fields as absent or null. Each standup's `payload` is itself a serialized JSON string and should be parsed only if the web UI needs daily standups.

## Minimal web reader

Most WebDAV servers do not expose cross-origin credentials safely to browser JavaScript. Fetch the file from a small server-side route and return only the snapshot to the signed-in web client.

```ts
const response = await fetch(process.env.DAYFLOW_WEBDAV_FILE!, {
  headers: {
    authorization: `Basic ${Buffer.from(
      `${process.env.DAYFLOW_WEBDAV_USER}:${process.env.DAYFLOW_WEBDAV_PASSWORD}`
    ).toString("base64")}`,
  },
  cache: "no-store",
});

if (!response.ok) throw new Error(`WebDAV returned ${response.status}`);
const snapshot = await response.json();
if (snapshot.schemaVersion !== 1) throw new Error("Unsupported Dayflow schema");
```

To render a weekly calendar, group `activities` by local date in `source.timeZone`, place each card using `startAt` and `endAt`, and map `activity.category` to the matching category's `colorHex`.
