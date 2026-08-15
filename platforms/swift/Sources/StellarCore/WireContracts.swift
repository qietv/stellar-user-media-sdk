/// Unix time represented as signed milliseconds since 1970-01-01T00:00:00Z.
public typealias EpochMilliseconds = Int64

/// Distinguishes an omitted patch field from an explicit JSON `null` and a concrete value.
public enum FieldPresence<Value: Sendable>: Sendable {
  case missing
  case null
  case value(Value)
}

extension FieldPresence: Equatable where Value: Equatable {}

extension KeyedDecodingContainer {
  /// Decodes a field while retaining the semantic difference between absence and JSON `null`.
  public func decodePresence<Value: Decodable & Sendable>(
    _ type: Value.Type,
    forKey key: Key
  ) throws -> FieldPresence<Value> {
    guard contains(key) else { return .missing }
    guard try !decodeNil(forKey: key) else { return .null }
    return .value(try decode(type, forKey: key))
  }
}

extension KeyedEncodingContainer {
  /// Omits `.missing`, encodes `.null` as JSON `null`, and encodes concrete values normally.
  public mutating func encodePresence<Value: Encodable & Sendable>(
    _ presence: FieldPresence<Value>,
    forKey key: Key
  ) throws {
    switch presence {
    case .missing:
      break
    case .null:
      try encodeNil(forKey: key)
    case .value(let value):
      try encode(value, forKey: key)
    }
  }
}

/// A stable cursor page. Writers encode `next_cursor: null` for a terminal page.
public struct CursorPage<Element: Codable & Sendable>: Codable, Sendable {
  public let items: [Element]
  public let nextCursor: String?

  public init(items: [Element], nextCursor: String?) throws {
    guard nextCursor?.isEmpty != true else {
      throw SDKError(code: .invalidConfiguration, message: "next cursor must not be empty")
    }
    self.items = items
    self.nextCursor = nextCursor
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    items = try container.decode([Element].self, forKey: .items)
    let nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    guard nextCursor?.isEmpty != true else {
      throw DecodingError.dataCorruptedError(
        forKey: .nextCursor,
        in: container,
        debugDescription: "next_cursor must be null, missing, or a non-empty string"
      )
    }
    self.nextCursor = nextCursor
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(items, forKey: .items)
    try container.encode(nextCursor, forKey: .nextCursor)
  }

  private enum CodingKeys: String, CodingKey {
    case items
    case nextCursor = "next_cursor"
  }
}

extension CursorPage: Equatable where Element: Equatable {}
