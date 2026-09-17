import Foundation

/// Shared by HTTP inference, uploads, streaming and provider connection tests.
/// CLI processes and unrelated app networking retain their own limits.
enum LLMRequestTimeout {
  static let key = "llmAPIRequestTimeoutSeconds"
  static let defaultSeconds: TimeInterval = 300
  static let range: ClosedRange<Double> = 30...1800

  static func seconds(in defaults: UserDefaults = .standard) -> TimeInterval {
    guard let value = defaults.object(forKey: key) as? NSNumber else { return defaultSeconds }
    let seconds = value.doubleValue
    guard seconds.isFinite, range.contains(seconds) else { return defaultSeconds }
    return seconds
  }

  static func request(url: URL, defaults: UserDefaults = .standard) -> URLRequest {
    URLRequest(url: url, timeoutInterval: seconds(in: defaults))
  }

  static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = timeout
    // Bound the entire transfer too, including streams that keep sending small chunks.
    configuration.timeoutIntervalForResource = timeout
    return configuration
  }
}

/// Sessions are reused for each selected timeout, without mutating URLSession.shared.
/// Taking the timeout from the request keeps both limits consistent even if settings
/// change between building and sending a request. In-flight requests keep their limit.
enum LLMHTTPSession {
  private static let lock = NSLock()
  private static var sessions: [TimeInterval: URLSession] = [:]

  static func session(for request: URLRequest) -> URLSession {
    lock.lock()
    defer { lock.unlock() }
    let timeout = request.timeoutInterval
    if let session = sessions[timeout] { return session }
    let session = URLSession(configuration: LLMRequestTimeout.configuration(timeout: timeout))
    sessions[timeout] = session
    return session
  }
}
