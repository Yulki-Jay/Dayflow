# LLM HTTP API timeout

## Configuration

Settings → Providers → API request timeout (Chinese: API 请求超时).
Default: **300 seconds**. Range: **30–1800 seconds**, in 30-second UI steps.
Stored in the existing `UserDefaults.standard` under `llmAPIRequestTimeoutSeconds`.
Missing, nonnumeric, nonfinite or out-of-range values fall back to 300 seconds.
Changes apply to newly constructed requests; active requests retain their original limit.

`LLMRequestTimeout.request` reads the preference into `URLRequest.timeoutInterval`.
`LLMHTTPSession.session(for:)` uses that request's timeout to configure both
`timeoutIntervalForRequest` (waiting for data) and `timeoutIntervalForResource`
(the entire transfer, including streaming). It reuses dedicated sessions for selected
values and does not mutate `URLSession.shared`. The limit is per attempt, not per batch;
existing retries can make total batch processing take longer.

## Root cause and call paths

Timeline processing starts in `AnalysisManager.queueLLMRequest` → `LLMService.processBatch` →
provider routing → screenshot transcription / activity-card generation.

- OpenAI-compatible: `OpenAICompatibleProvider` → `OllamaProvider.callChatAPI` →
  `makeChatURLRequest` → Foundation URLSession. The request builder explicitly set
  **60 seconds**, also affecting Ollama / LM Studio / custom endpoints and text generation.
- Dayflow hosted backend: three HTTP request paths had no explicit timeout, inheriting
  URLRequest's **60-second default**.
- Gemini: transcription, cards and text explicitly used 120 seconds; dashboard streaming
  and fallback generation used 180 seconds. Upload initiation, upload data, file status
  and connection tests inherited 60 seconds.
- Gemma backup inference explicitly used 120 seconds.
- Local/custom connection tests explicitly used 35 seconds.

All of these HTTP paths now use the preference. There is no third-party HTTP client
in these model transports. The previous shared session's default resource timeout is
7 days, not the observed 60-second boundary. The new session explicitly bounds the
resource duration using the same user preference.

Independent limits retained: Codex/Claude CLI processes use a 300-second process limit;
Gemini file processing polls on a separate 180-second cycle deadline (a pending status
request may finish after that deadline); local performance qualification tests still
apply their latency requirement. Login, update/reporting and favicon networking are
unchanged. Reverse proxies and API providers may impose their own shorter limits.

## Error handling audit

No HTTP errors are reclassified as timeout by this change. Foundation transport errors
retain their domain/code; HTTP responses retain status and response bodies.

- Gemini inference has bounded retries, short exponential backoff for 5xx/connection
  errors and no retry for ordinary authentication errors, plus capacity/model fallback.
- Ollama transport uses up to three attempts with 2/4-second backoff. OpenAI-compatible
  screenshot/card generation uses three outer attempts with 1/2-second waits and one
  HTTP attempt per outer iteration. These existing loops retry permanent errors too;
  prompt correction is also applied to transport failures. They do not respect Retry-After.
- Dayflow backend has no retry loop at the HTTP layer; orchestration may fail over.
- Gemini upload has nested bounded retry cycles; the inner classifier retries transport
  errors, not HTTP 5xx. Gemma and dashboard streaming do not have the same inference retry loop.
- `auth_unavailable` is an upstream authentication/credential-service error; the actual
  HTTP status and response body must guide diagnosis. A longer client timeout cannot fix it.

## Changed source files

Under `Dayflow/Dayflow/`:

- `Core/AI/LLMRequestTimeout.swift` (new preference / request factory / LLM sessions)
- `Core/AI/OllamaProvider+Networking.swift`
- `Core/AI/DayflowBackendProvider.swift`
- `Core/AI/GemmaBackupProvider+Networking.swift`
- `Core/AI/GeminiDirectProvider+ActivityCards.swift`
- `Core/AI/GeminiDirectProvider+Transcription.swift`
- `Core/AI/GeminiDirectProvider+Text.swift`
- `Core/AI/GeminiDirectProvider+DashboardStreaming.swift`
- `Core/AI/GeminiDirectProvider+Upload.swift`
- `Utilities/GeminiAPIHelper.swift`
- `Views/Onboarding/LocalLLMTestView.swift`
- `Views/UI/Settings/SettingsProvidersTabView.swift`
- `Localizable.xcstrings` (new settings strings with Simplified Chinese translations)
- `Views/Components/ReferralSurveyView.swift`: existing initialization failed under the
  installed Xcode because State bindings were accessed before all stored properties
  were initialized. Resolve fallback State bindings after initialization instead;
  preserve external-binding and internal-state modes.

Tests: `Dayflow/DayflowTests/LLMRequestTimeoutTests.swift` (new).

## Validation

- Full Debug app build succeeded with Xcode 27, macOS destination, signing disabled.
- Three new unit tests passed: preference validation/updates, request and resource limits,
  session reuse, and OpenAI-compatible transport request/authentication construction.
- A compiled harness using the production timeout/session source called a local HTTP
  server that waited 65 seconds before sending headers. The old 60-second request failed
  with NSURLErrorDomain -1001 after **61.03 s**; the configured request succeeded after
  **65.06 s**. Separate 502/503 responses retained their HTTP status.
- No real upstream API request was sent. Installed Dayflow was not replaced.
- Full unit suite in the machine's Chinese environment: **178 passed, 8 failed**.
  A separate HEAD baseline (with only the SwiftUI compilation fix) reproduced the
  **same 8 failures**, with 175 passing. They are existing English-text expectations
  in OpenAI-compatible prompts, Claude coverage errors and agent connection errors.
  English-language execution removed the six coverage failures but also exposed an
  existing language-preference test assumption; the full suite is not entirely green.
- All model HTTP construction/send sites were scanned for residual shared-session or
  default URLRequest usage; none remain. `git diff --check` passed.

Build command from repository root:

```sh
xcodebuild -project Dayflow/Dayflow.xcodeproj -scheme Dayflow \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/dayflow-timeout-build CODE_SIGNING_ALLOWED=NO build
```

Use the same options with `-only-testing:DayflowTests test` for the unit suite.
Build artifact: `/tmp/dayflow-timeout-build/Build/Products/Debug/Dayflow.app`.
