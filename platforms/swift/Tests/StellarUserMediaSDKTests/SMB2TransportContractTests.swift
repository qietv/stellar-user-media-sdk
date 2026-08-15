import Foundation
import StellarCore
import StellarSMB2Core
import Testing

@Suite("SMB2 transport contract")
struct SMB2TransportContractTests {
  @Test("Paths normalize separators and reject parent traversal")
  func paths() throws {
    let path = try SMB2Path("/Movies//Science Fiction/./Arrival.mkv")

    #expect(path.relativePath == "Movies/Science Fiction/Arrival.mkv")
    #expect(path.name == "Arrival.mkv")
    #expect(path.description == SensitiveDataRedactor.pathPlaceholder)
    #expect(throws: SDKError.self) { _ = try SMB2Path("Movies/../private") }
    #expect(throws: SDKError.self) { _ = try path.appending(component: "../private") }
  }

  @Test("Endpoint and credential inputs keep URL userinfo out of configuration")
  func credentialBoundary() throws {
    let endpoint = try SMB2Endpoint(
      server: "nas.example.test",
      port: 445,
      share: "Media",
      rootPath: "/Movies"
    )
    let credential = try SMB2Credential(domain: "STELLAR", username: "alice", password: "secret")

    #expect(endpoint.rootPath.relativePath == "Movies")
    #expect(endpoint.description.contains("nas.example.test") == false)
    #expect(endpoint.debugDescription.contains("Media") == false)
    #expect(credential.description == "<SMB2Credential redacted>")
    #expect(credential.debugDescription.contains("alice") == false)
    #expect(credential.debugDescription.contains("secret") == false)
    #expect(throws: SDKError.self) {
      _ = try SMB2Endpoint(server: "smb://alice:secret@nas.example.test", share: "Media")
    }
  }

  @Test("Dialect values preserve future negotiations and reject unknown exact requirements")
  func dialects() throws {
    let future = SMB2Dialect(wireValue: 0x0400)
    let endpoint = try SMB2Endpoint(server: "nas.example.test", share: "Media")
    let credential = try SMB2Credential(username: "alice", password: "secret")

    #expect(SMB2Dialect.smb311.wireValue == 0x0311)
    #expect(future == .unknown(0x0400))
    #expect(future.description == "unknown-0x400")
    #expect(throws: SDKError.self) {
      _ = try SMB2ConnectionRequest(
        endpoint: endpoint,
        credential: credential,
        versionPolicy: .exact(future)
      )
    }
  }

  @Test("A fake transport exercises list, stat, range read, and disconnect without a server")
  func fakeTransport() async throws {
    let moviePath = try SMB2Path("Movies/Arrival.mkv")
    let movie = try SMB2Entry(
      path: moviePath,
      kind: .file,
      size: 7,
      modifiedAtMilliseconds: 1_700_000_000_000,
      stableID: "file-1"
    )
    let session = FakeSMB2Session(entries: [movie], data: Data("arrival".utf8))
    let transport = FakeSMB2Transport(session: session)
    let request = try SMB2ConnectionRequest(
      endpoint: SMB2Endpoint(server: "nas.example.test", share: "Media"),
      credential: SMB2Credential(username: "alice", password: "secret"),
      versionPolicy: .smb3Only,
      signingPolicy: .required,
      encryptionPolicy: .required,
      timeoutMilliseconds: 5_000
    )

    #expect(request.description.contains("nas.example.test") == false)
    #expect(request.description.contains("alice") == false)
    #expect(movie.description.contains("Arrival.mkv") == false)
    #expect(movie.debugDescription.contains("file-1") == false)

    let connected = try await transport.connect(request)
    let info = await connected.connectionInfo
    let entries = try await connected.listDirectory(at: SMB2Path())
    let stat = try await connected.stat(moviePath)
    let bytes = try await connected.read(
      at: moviePath,
      range: SMB2ByteRange(offset: 1, length: 3)
    )
    await connected.disconnect()
    let connectionCount = await transport.connectionCount
    let disconnected = await session.isDisconnected

    #expect(info.dialect == .smb311)
    #expect(entries == [movie])
    #expect(stat == movie)
    #expect(String(decoding: bytes, as: UTF8.self) == "rri")
    #expect(connectionCount == 1)
    #expect(disconnected)
  }
}

private actor FakeSMB2Transport: SMB2Transport {
  private let session: any SMB2Session
  private(set) var connectionCount = 0

  init(session: any SMB2Session) {
    self.session = session
  }

  func connect(_: SMB2ConnectionRequest) async throws -> any SMB2Session {
    connectionCount += 1
    return session
  }
}

private actor FakeSMB2Session: SMB2Session {
  nonisolated let connectionInfo = SMB2ConnectionInfo(
    dialect: .smb311,
    signingPolicy: .required,
    encryptionPolicy: .required,
    implementationVersion: "fake-1"
  )
  private let entries: [SMB2Entry]
  private let data: Data
  private(set) var isDisconnected = false

  init(entries: [SMB2Entry], data: Data) {
    self.entries = entries
    self.data = data
  }

  func listDirectory(at _: SMB2Path) async throws -> [SMB2Entry] { entries }

  func stat(_ path: SMB2Path) async throws -> SMB2Entry {
    guard let entry = entries.first(where: { $0.path == path }) else {
      throw SDKError(code: .metadataNotFound, message: "entry not found")
    }
    return entry
  }

  func read(at _: SMB2Path, range: SMB2ByteRange) async throws -> Data {
    let lowerBound = Int(range.offset)
    let upperBound = min(data.count, lowerBound + range.length)
    guard lowerBound < upperBound else {
      return Data()
    }
    return data.subdata(in: lowerBound..<upperBound)
  }

  func disconnect() async {
    isDisconnected = true
  }
}
