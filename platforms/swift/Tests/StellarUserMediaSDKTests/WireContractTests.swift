import Foundation
import StellarCore
import Testing

@Suite("JSON wire contracts")
struct WireContractTests {
  @Test("Cursor pages and epoch milliseconds match the shared fixture")
  func sharedWireFixture() throws {
    let fixture = try JSONDecoder().decode(
      WireFixture.self,
      from: Data(contentsOf: sharedFixtureURL)
    )

    #expect(fixture.schemaVersion == 1)
    #expect(fixture.epochMilliseconds == EpochMilliseconds(1_700_000_000_123))
    #expect(fixture.continuedPage.items == [WireItem(uid: "item-1")])
    #expect(fixture.continuedPage.nextCursor == "cursor-2")
    #expect(fixture.terminalPage.items.isEmpty)
    #expect(fixture.terminalPage.nextCursor == nil)
  }

  @Test("Terminal cursor pages explicitly encode null")
  func terminalCursorEncoding() throws {
    let page = try CursorPage<WireItem>(items: [], nextCursor: nil)
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any]
    )

    #expect(object.keys.contains("next_cursor"))
    #expect(object["next_cursor"] is NSNull)
  }

  @Test("Empty cursors are rejected")
  func emptyCursor() {
    #expect(throws: SDKError.self) {
      _ = try CursorPage<WireItem>(items: [], nextCursor: "")
    }
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(
        CursorPage<WireItem>.self,
        from: Data(#"{"items":[],"next_cursor":""}"#.utf8)
      )
    }
  }

  @Test("Patch fields distinguish missing, null, and value")
  func fieldPresence() throws {
    let decoder = JSONDecoder()
    let missing = try decoder.decode(WirePatch.self, from: Data("{}".utf8))
    let null = try decoder.decode(WirePatch.self, from: Data(#"{"title":null}"#.utf8))
    let value = try decoder.decode(WirePatch.self, from: Data(#"{"title":"Arrival"}"#.utf8))

    #expect(missing.title == .missing)
    #expect(null.title == .null)
    #expect(value.title == .value("Arrival"))
    #expect(String(decoding: try JSONEncoder().encode(missing), as: UTF8.self) == "{}")
    #expect(String(decoding: try JSONEncoder().encode(null), as: UTF8.self) == #"{"title":null}"#)
    #expect(
      String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        == #"{"title":"Arrival"}"#)
  }

  private var sharedFixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("specs/fixtures/core/wire-format-v1.json")
  }
}

private struct WireFixture: Decodable {
  let schemaVersion: Int
  let epochMilliseconds: EpochMilliseconds
  let continuedPage: CursorPage<WireItem>
  let terminalPage: CursorPage<WireItem>

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case epochMilliseconds = "epoch_ms"
    case continuedPage = "continued_page"
    case terminalPage = "terminal_page"
  }
}

private struct WireItem: Codable, Equatable, Sendable {
  let uid: String
}

private struct WirePatch: Codable, Equatable, Sendable {
  let title: FieldPresence<String>

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decodePresence(String.self, forKey: .title)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodePresence(title, forKey: .title)
  }

  private enum CodingKeys: String, CodingKey {
    case title
  }
}
