import Foundation

/// Privacy treatment for a structured log metadata value.
public enum SDKLogPrivacy: Equatable, Sendable {
  case plain
  case url
  case path
  case username
  case password
  case token
  case header(name: String)
}

/// Central redaction policy for logs, diagnostics, and CLI error output.
public struct SensitiveDataRedactor: Sendable {
  public static let placeholder = "<redacted>"
  public static let pathPlaceholder = "<redacted-path>"

  public init() {}

  public func redact(_ value: String, as privacy: SDKLogPrivacy) -> String {
    switch privacy {
    case .plain:
      redact(message: value)
    case .url:
      redact(url: value)
    case .path:
      redact(path: value)
    case .username, .password, .token:
      Self.placeholder
    case .header(let name):
      redact(headerValue: value, named: name)
    }
  }

  /// Removes URL userinfo, path, fragments, and secret-bearing query values.
  public func redact(url: String) -> String {
    guard var components = URLComponents(string: url), components.scheme != nil else {
      return Self.placeholder
    }

    components.user = nil
    components.password = nil
    if !components.path.isEmpty && components.path != "/" {
      components.path = "/REDACTED_PATH"
    }
    components.fragment = nil
    components.queryItems = components.queryItems?.map { item in
      guard isSensitiveName(item.name) else { return item }
      return URLQueryItem(name: item.name, value: "REDACTED")
    }
    return components.string ?? Self.placeholder
  }

  /// Hides a local or remote path in diagnostic output.
  public func redact(path _: String) -> String { Self.pathPlaceholder }

  /// Redacts credential-bearing HTTP and connector headers while preserving safe headers.
  public func redact(headers: [String: String]) -> [String: String] {
    headers.reduce(into: [:]) { result, item in
      result[item.key] = redact(headerValue: item.value, named: item.key)
    }
  }

  public func redact(headerValue value: String, named name: String) -> String {
    isSensitiveName(name) ? Self.placeholder : redact(message: value)
  }

  /// Best-effort protection for unstructured diagnostics. Structured metadata should be preferred.
  public func redact(message: String) -> String {
    var output = replacingMatches(
      pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s<>\"']+"#,
      in: message
    ) { match, source in
      guard let range = Range(match.range, in: source) else { return Self.placeholder }
      return redact(url: String(source[range]))
    }

    output = replacingMatches(
      pattern:
        #"(?im)^(\s*(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key)\s*:\s*).*$"#,
      in: output
    ) { match, source in
      guard let prefixRange = Range(match.range(at: 1), in: source) else {
        return Self.placeholder
      }
      return String(source[prefixRange]) + Self.placeholder
    }

    return replacingMatches(
      pattern:
        #"(?i)\b(username|user|password|passwd|pwd|token|access_token|refresh_token|api[_-]?key|secret)\b(\s*(?:=|:)\s*|\s+)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
      in: output
    ) { match, source in
      guard let keyRange = Range(match.range(at: 1), in: source),
        let separatorRange = Range(match.range(at: 2), in: source)
      else {
        return Self.placeholder
      }
      return String(source[keyRange]) + String(source[separatorRange]) + Self.placeholder
    }
  }

  /// Applies URL, path, and key-value rules to an argument before echoing it to stderr.
  public func redact(commandLineArgument argument: String) -> String {
    if argument.contains("://") {
      return redact(url: argument)
    }
    if argument.hasPrefix("/") || argument.hasPrefix("./") || argument.hasPrefix("../")
      || argument.contains("\\")
    {
      return redact(path: argument)
    }
    return redact(message: argument)
  }

  private func isSensitiveName(_ name: String) -> Bool {
    let normalized = name.lowercased().replacingOccurrences(
      of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    return normalized == "authorization" || normalized == "proxyauthorization"
      || normalized == "cookie" || normalized == "setcookie" || normalized == "username"
      || normalized == "user" || normalized == "password" || normalized == "passwd"
      || normalized == "pwd" || normalized.contains("token") || normalized.contains("apikey")
      || normalized.contains("secret") || normalized.contains("credential")
  }

  private func replacingMatches(
    pattern: String,
    in input: String,
    transform: (NSTextCheckingResult, String) -> String
  ) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
    let matches = expression.matches(
      in: input, range: NSRange(input.startIndex..<input.endIndex, in: input))
    var output = input
    for match in matches.reversed() {
      guard let range = Range(match.range, in: output) else { continue }
      output.replaceSubrange(range, with: transform(match, output))
    }
    return output
  }
}
