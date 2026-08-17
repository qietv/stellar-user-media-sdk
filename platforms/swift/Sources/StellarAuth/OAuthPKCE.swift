import Foundation
import StellarCore

protocol OAuthRandomGenerating: Sendable {
  func randomBytes(count: Int) throws -> [UInt8]
}

struct SystemOAuthRandomGenerator: OAuthRandomGenerating {
  func randomBytes(count: Int) throws -> [UInt8] {
    guard count > 0 && count <= 1_024 else {
      throw SDKError(code: .invalidConfiguration, message: "OAuth random byte count is invalid")
    }
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }
}

struct OAuthAuthorizationAttempt: Sendable {
  let state: String
  let verifier: String
  let challenge: String
  let presentationRequest: OAuthAuthorizationPresentationRequest
}

enum OAuthAuthorizationBuilder {
  static func makeAttempt(
    endpoint: URL,
    configuration: StellarOAuthConfiguration,
    random: any OAuthRandomGenerating
  ) throws -> OAuthAuthorizationAttempt {
    let state = base64URLEncoded(try random.randomBytes(count: 32))
    let verifier = base64URLEncoded(try random.randomBytes(count: 32))
    let challenge = base64URLEncoded(SHA256.hash(Array(verifier.utf8)))
    guard state.utf8.count == 43, verifier.utf8.count == 43, challenge.utf8.count == 43 else {
      throw SDKError(code: .unknown, message: "OAuth PKCE generation failed")
    }

    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw SDKError(
        code: .invalidConfiguration, message: "OAuth authorization endpoint is invalid")
    }
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: configuration.clientID),
      URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
      URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    guard let authorizationURL = components.url else {
      throw SDKError(code: .invalidConfiguration, message: "OAuth authorization URL is invalid")
    }
    return OAuthAuthorizationAttempt(
      state: state,
      verifier: verifier,
      challenge: challenge,
      presentationRequest: OAuthAuthorizationPresentationRequest(
        authorizationURL: authorizationURL,
        redirectURI: configuration.redirectURI
      )
    )
  }

  static func authorizationCode(
    from callbackURL: URL,
    redirectURI: URL,
    expectedState: String
  ) throws -> String {
    guard
      let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
      let redirect = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
      callback.scheme == redirect.scheme,
      callback.host == redirect.host,
      callback.port == redirect.port,
      callback.path == redirect.path,
      callback.user == nil,
      callback.password == nil,
      callback.fragment == nil
    else {
      throw SDKError(code: .unauthorized, message: "OAuth callback URI is invalid")
    }

    let allowedNames = Set(["state", "code", "error", "error_description", "error_uri"])
    let items = callback.queryItems ?? []
    guard items.allSatisfy({ allowedNames.contains($0.name) }) else {
      throw SDKError(code: .unauthorized, message: "OAuth callback parameters are invalid")
    }
    let grouped = Dictionary(grouping: items, by: \.name)
    guard grouped.values.allSatisfy({ $0.count == 1 }),
      let state = grouped["state"]?.first?.value,
      constantTimeEqual(state, expectedState)
    else {
      throw SDKError(code: .unauthorized, message: "OAuth callback state is invalid")
    }

    let code = grouped["code"]?.first?.value
    let error = grouped["error"]?.first?.value
    guard (code?.isEmpty == false) != (error?.isEmpty == false) else {
      throw SDKError(code: .unauthorized, message: "OAuth callback result is invalid")
    }
    if let error {
      guard isSafeOAuthError(error) else {
        throw SDKError(code: .unauthorized, message: "OAuth callback error is invalid")
      }
      if error == "access_denied" {
        throw SDKError(code: .cancelled, message: "OAuth authorization was cancelled")
      }
      throw SDKError(code: .unauthorized, message: "OAuth authorization failed")
    }
    guard let code, code.utf8.count <= 8_192 else {
      throw SDKError(code: .unauthorized, message: "OAuth authorization code is invalid")
    }
    return code
  }

  private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
    for index in 0..<max(left.count, right.count) {
      let leftByte = index < left.count ? left[index] : 0
      let rightByte = index < right.count ? right[index] : 0
      difference |= leftByte ^ rightByte
    }
    return difference == 0
  }

  private static func isSafeOAuthError(_ value: String) -> Bool {
    guard (1...64).contains(value.utf8.count) else { return false }
    return value.utf8.allSatisfy { byte in
      (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x5F
    }
  }
}

private func base64URLEncoded(_ bytes: [UInt8]) -> String {
  Data(bytes).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

/// Small dependency-free SHA-256 implementation used to keep PKCE portable across Swift targets.
private enum SHA256 {
  private static let initialHash: [UInt32] = [
    0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
    0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
  ]

  private static let constants: [UInt32] = [
    0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1,
    0x923F_82A4, 0xAB1C_5ED5, 0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3,
    0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174, 0xE49B_69C1, 0xEFBE_4786,
    0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
    0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147,
    0x06CA_6351, 0x1429_2967, 0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13,
    0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85, 0xA2BF_E8A1, 0xA81A_664B,
    0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
    0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A,
    0x5B9C_CA4F, 0x682E_6FF3, 0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208,
    0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
  ]

  static func hash(_ input: [UInt8]) -> [UInt8] {
    var message = input
    let bitCount = UInt64(message.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    message.append(contentsOf: withUnsafeBytes(of: bitCount.bigEndian, Array.init))

    var hash = initialHash
    for chunkStart in stride(from: 0, to: message.count, by: 64) {
      var words = [UInt32](repeating: 0, count: 64)
      for index in 0..<16 {
        let offset = chunkStart + index * 4
        words[index] =
          UInt32(message[offset]) << 24 | UInt32(message[offset + 1]) << 16
          | UInt32(message[offset + 2]) << 8 | UInt32(message[offset + 3])
      }
      for index in 16..<64 {
        let s0 =
          rotateRight(words[index - 15], by: 7) ^ rotateRight(words[index - 15], by: 18)
          ^ (words[index - 15] >> 3)
        let s1 =
          rotateRight(words[index - 2], by: 17) ^ rotateRight(words[index - 2], by: 19)
          ^ (words[index - 2] >> 10)
        words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
      }

      var a = hash[0]
      var b = hash[1]
      var c = hash[2]
      var d = hash[3]
      var e = hash[4]
      var f = hash[5]
      var g = hash[6]
      var h = hash[7]
      for index in 0..<64 {
        let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
        let choice = (e & f) ^ (~e & g)
        let temporary1 = h &+ sum1 &+ choice &+ constants[index] &+ words[index]
        let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
        let majority = (a & b) ^ (a & c) ^ (b & c)
        let temporary2 = sum0 &+ majority
        h = g
        g = f
        f = e
        e = d &+ temporary1
        d = c
        c = b
        b = a
        a = temporary1 &+ temporary2
      }
      hash[0] &+= a
      hash[1] &+= b
      hash[2] &+= c
      hash[3] &+= d
      hash[4] &+= e
      hash[5] &+= f
      hash[6] &+= g
      hash[7] &+= h
    }
    return hash.flatMap { word in
      let value = word.bigEndian
      return withUnsafeBytes(of: value, Array.init)
    }
  }

  private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
    (value >> count) | (value << (32 - count))
  }
}
