import Foundation
import StellarUserMediaSDK
import Testing

@Suite("Umbrella SDK module")
struct UmbrellaModuleTests {
  @Test("Preserves the original SDK and CLI import surface")
  func compatibilityAliases() throws {
    let parsed: ParsedMediaFilename = MediaFilenameParser().parse("Arrival.2016.mkv")
    let error = SDKError(code: .parseFailure, message: "example")

    #expect(StellarUserMediaSDK.version == "0.1.0-dev")
    #expect(parsed.kind == .movie)
    #expect(parsed.year == 2016)
    #expect(error.code == SDKErrorCode.parseFailure)
  }
}
