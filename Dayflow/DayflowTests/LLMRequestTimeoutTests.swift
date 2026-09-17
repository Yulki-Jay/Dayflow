import XCTest

@testable import Dayflow

final class LLMRequestTimeoutTests: XCTestCase {
  func testDefaultsValidationAndUpdates() throws {
    let name = "LLMRequestTimeoutTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    XCTAssertEqual(LLMRequestTimeout.seconds(in: defaults), 300)
    for invalid: Any in [0, -1, 29, 1801, "invalid", Double.infinity, Double.nan] {
      defaults.set(invalid, forKey: LLMRequestTimeout.key)
      XCTAssertEqual(LLMRequestTimeout.seconds(in: defaults), 300)
    }
    for seconds in [30.0, 120, 600, 1800] {
      defaults.set(seconds, forKey: LLMRequestTimeout.key)
      XCTAssertEqual(LLMRequestTimeout.seconds(in: defaults), seconds)
      let request = LLMRequestTimeout.request(
        url: URL(string: "https://example.invalid")!, defaults: defaults)
      XCTAssertEqual(request.timeoutInterval, seconds)
      let configuration = LLMHTTPSession.session(for: request).configuration
      XCTAssertEqual(configuration.timeoutIntervalForRequest, seconds)
      XCTAssertEqual(configuration.timeoutIntervalForResource, seconds)
    }
  }

  func testBothSessionLimitsFollowRequestAndSessionsAreReused() {
    let url = URL(string: "https://example.invalid/v1/chat/completions")!
    let request = URLRequest(url: url, timeoutInterval: 600)
    let session = LLMHTTPSession.session(for: request)
    XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 600)
    XCTAssertEqual(session.configuration.timeoutIntervalForResource, 600)
    XCTAssertTrue(session === LLMHTTPSession.session(for: request))
    let changed = URLRequest(url: url, timeoutInterval: 900)
    let newSession = LLMHTTPSession.session(for: changed)
    XCTAssertFalse(session === newSession)
    XCTAssertEqual(newSession.configuration.timeoutIntervalForResource, 900)
    XCTAssertEqual(session.configuration.timeoutIntervalForResource, 600)
    XCTAssertEqual(URLSession.shared.configuration.timeoutIntervalForRequest, 60)
  }

  func testCompatibleTransportUsesConfiguredTimeout() throws {
    let configuration = OpenAICompatibleConfiguration(
      preset: .custom, baseURL: "https://example.invalid/v1", modelID: "model")
    let provider = OllamaProvider(openAICompatible: .init(
      configuration: configuration, bearerToken: "test-token"))
    let payload = OllamaProvider.ChatRequest(model: "model", messages: [])
    let request = try provider.makeChatURLRequest(payload)
    XCTAssertEqual(request.timeoutInterval, LLMRequestTimeout.seconds())
    XCTAssertEqual(
      LLMHTTPSession.session(for: request).configuration.timeoutIntervalForResource,
      request.timeoutInterval)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    XCTAssertEqual(try provider.makeChatURLRequest(payload, timeoutInterval: 750).timeoutInterval, 750)
  }
}
