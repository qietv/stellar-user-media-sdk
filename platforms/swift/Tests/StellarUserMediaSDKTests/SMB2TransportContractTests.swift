import Foundation
import StellarCore
import StellarMediaLibrary
import StellarRemoteMedia
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
    #expect(throws: SDKError.self) {
      _ = try SMB2Endpoint(server: "nas.example.test:1445", share: "Media")
    }
    #expect(try SMB2Endpoint(server: "[2001:db8::1]", port: 1445, share: "Media").port == 1445)
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
    #expect(throws: SDKError.self) {
      _ = try SMB2ConnectionRequest(
        endpoint: endpoint,
        credential: credential,
        versionPolicy: .smb2Only,
        encryptionPolicy: .required
      )
    }
  }

  @Test("POSIX failures map to stable, path-free SDK errors")
  func errorMapping() {
    let authentication = SMB2POSIXErrorMapper.map(
      status: -Int32(POSIXErrorCode.EACCES.rawValue),
      operation: .connect
    )
    let permission = SMB2POSIXErrorMapper.map(
      status: -Int32(POSIXErrorCode.EACCES.rawValue),
      operation: .listDirectory
    )
    let missing = SMB2POSIXErrorMapper.map(
      status: -Int32(POSIXErrorCode.ENOENT.rawValue),
      operation: .stat
    )
    let missingShare = SMB2POSIXErrorMapper.map(
      status: -Int32(POSIXErrorCode.ENOENT.rawValue),
      operation: .connect
    )
    let timeout = SMB2POSIXErrorMapper.map(
      status: -Int32(POSIXErrorCode.ETIMEDOUT.rawValue),
      operation: .read
    )
    let busy = SMB2POSIXErrorMapper.map(
      status: -Int32(POSIXErrorCode.EBUSY.rawValue),
      operation: .listDirectory
    )

    #expect(authentication.code == .unauthorized)
    #expect(permission.code == .forbidden)
    #expect(missing.code == .metadataNotFound)
    #expect(missingShare.code == .remoteUnavailable)
    #expect(timeout.code == .remoteUnavailable)
    #expect(busy.code == .conflict)
    #expect(busy.message == "SMB session is busy")
    #expect(authentication.message.contains("nas") == false)
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

  @Test("The SMB adapter runs through the shared connector and scanner contracts")
  func scannerAdapter() async throws {
    let rootPath = try SMB2Path()
    let moviesPath = try SMB2Path("Movies")
    let arrivalPath = try SMB2Path("Movies/Arrival.mkv")
    let notesPath = try SMB2Path("Notes.txt")
    let root = try SMB2Entry(path: rootPath, kind: .directory, stableID: "root")
    let movies = try SMB2Entry(path: moviesPath, kind: .directory, stableID: "movies")
    let arrival = try SMB2Entry(
      path: arrivalPath,
      kind: .file,
      size: 7,
      stableID: "arrival"
    )
    let notes = try SMB2Entry(path: notesPath, kind: .file, size: 5, stableID: "notes")
    let request = try SMB2ConnectionRequest(
      endpoint: SMB2Endpoint(server: "nas.example.test", share: "Media"),
      credential: SMB2Credential(username: "alice", password: "secret")
    )
    let configuration = try SMB2MediaSourceConfiguration(
      sourceUID: "smb-fixture-1",
      connectionRequest: request,
      stableIDScope: .persistent
    )
    let directSession = TreeSMB2Session(
      entriesByDirectory: [rootPath: [notes, movies], moviesPath: [arrival]],
      entriesByPath: [rootPath: root, moviesPath: movies, arrivalPath: arrival, notesPath: notes]
    )
    let directConnector = SMB2MediaSourceConnector(
      transport: FakeSMB2Transport(session: directSession),
      configuration: configuration
    )
    let connected = try await directConnector.connect()
    let rootLocator = try RemoteLocator(sourceUID: configuration.sourceUID, path: RemotePath())
    let firstPage = try await connected.listDirectory(
      RemoteDirectoryPageRequest(directory: rootLocator, limit: 1)
    )
    let secondPage = try await connected.listDirectory(
      RemoteDirectoryPageRequest(
        directory: rootLocator,
        cursor: firstPage.nextCursor,
        limit: 1
      )
    )
    let arrivalLocator = try RemoteLocator(
      sourceUID: configuration.sourceUID,
      path: RemotePath("Movies/Arrival.mkv")
    )
    let stat = try await connected.stat(arrivalLocator)
    let bytes = try await connected.read(
      at: arrivalLocator,
      range: RemoteByteRange(offset: 1, length: 3)
    )
    await connected.disconnect()

    #expect(firstPage.items.count == 1)
    #expect(secondPage.items.count == 1)
    #expect(secondPage.nextCursor == nil)
    #expect(stat.stableID == "arrival")
    #expect(String(decoding: bytes, as: UTF8.self) == "rri")
    #expect(await directSession.listCount(at: rootPath) == 1)

    let scannerSession = TreeSMB2Session(
      entriesByDirectory: [rootPath: [movies, notes], moviesPath: [arrival]],
      entriesByPath: [rootPath: root, moviesPath: movies, arrivalPath: arrival, notesPath: notes]
    )
    let scannerConnector = SMB2MediaSourceConnector(
      transport: FakeSMB2Transport(session: scannerSession),
      configuration: configuration
    )
    let sink = SMBScannerSink()
    let scanner = MediaScanner(
      configuration: try MediaScannerConfiguration(
        pageSize: 1,
        maxConcurrentDirectoryRequests: 2
      )
    )
    let result = try await scanner.scan(
      MediaScanRequest(
        runUID: "smb-full-scan",
        sourceUID: configuration.sourceUID,
        mode: .full,
        roots: [rootLocator]
      ),
      using: scannerConnector,
      sink: sink
    )

    #expect(result.checkpoint.phase == .completed)
    #expect(result.checkpoint.discoveredEntryCount == 3)
    #expect(result.checkpoint.processedPageCount == 3)
    #expect(result.completion.reconcileMissingEligible)
    #expect(await sink.paths == ["Movies", "Movies/Arrival.mkv", "Notes.txt"])
    #expect(await scannerSession.listCount(at: rootPath) == 1)
    #expect(await scannerSession.listCount(at: moviesPath) == 1)
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

private actor TreeSMB2Session: SMB2Session {
  nonisolated let connectionInfo = SMB2ConnectionInfo(
    dialect: .smb311,
    signingPolicy: .required,
    encryptionPolicy: .disabled,
    implementationVersion: "fake-tree-1"
  )
  private let entriesByDirectory: [SMB2Path: [SMB2Entry]]
  private let entriesByPath: [SMB2Path: SMB2Entry]
  private var listCounts: [SMB2Path: Int] = [:]
  private var disconnected = false

  init(
    entriesByDirectory: [SMB2Path: [SMB2Entry]],
    entriesByPath: [SMB2Path: SMB2Entry]
  ) {
    self.entriesByDirectory = entriesByDirectory
    self.entriesByPath = entriesByPath
  }

  func listDirectory(at path: SMB2Path) async throws -> [SMB2Entry] {
    try requireConnected()
    listCounts[path, default: 0] += 1
    guard let entries = entriesByDirectory[path] else {
      throw SDKError(code: .metadataNotFound, message: "fixture directory not found")
    }
    return entries
  }

  func listCount(at path: SMB2Path) -> Int {
    listCounts[path, default: 0]
  }

  func stat(_ path: SMB2Path) async throws -> SMB2Entry {
    try requireConnected()
    guard let entry = entriesByPath[path] else {
      throw SDKError(code: .metadataNotFound, message: "fixture entry not found")
    }
    return entry
  }

  func read(at path: SMB2Path, range: SMB2ByteRange) async throws -> Data {
    _ = try await stat(path)
    let data = Data("Arrival".utf8)
    let lowerBound = Int(range.offset)
    let upperBound = min(data.count, lowerBound + range.length)
    guard lowerBound < upperBound else { return Data() }
    return data.subdata(in: lowerBound..<upperBound)
  }

  func disconnect() async {
    disconnected = true
  }

  private func requireConnected() throws {
    guard !disconnected else {
      throw SDKError(code: .remoteUnavailable, message: "fixture SMB session disconnected")
    }
  }
}

private actor SMBScannerSink: MediaScanSink {
  private var entries: [String: RemoteEntry] = [:]

  var paths: [String] {
    entries.values.map(\.locator.path.relativePath).sorted()
  }

  func commit(_ batch: MediaScanBatch) async throws {
    for entry in batch.entries {
      entries[entry.stableID ?? entry.locator.path.relativePath] = entry
    }
  }
}
