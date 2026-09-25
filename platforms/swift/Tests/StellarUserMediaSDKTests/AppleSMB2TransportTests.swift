import Darwin
import Foundation
import StellarCore
import StellarRemoteMedia
import StellarSMB2Apple
import StellarSMB2Core
import Testing

@Suite("Apple SMB2 transport")
struct AppleSMB2TransportTests {
  @Test("The Apple transport can be constructed without opening a connection")
  func construction() {
    _ = AppleSMB2Transport()
  }

  @Test("Policies that AMSMB2 cannot express fail before network access")
  func unsupportedPolicies() async throws {
    let endpoint = try SMB2Endpoint(server: "127.0.0.1", share: "policy-test")
    let credential = try SMB2Credential(username: "guest", password: "")
    let requests = [
      try SMB2ConnectionRequest(
        endpoint: endpoint,
        credential: credential,
        versionPolicy: .smb3Only
      ),
      try SMB2ConnectionRequest(
        endpoint: endpoint,
        credential: credential,
        signingPolicy: .required
      ),
    ]

    for request in requests {
      do {
        _ = try await AppleSMB2Transport().connect(request)
        Issue.record("unsupported AMSMB2 policy unexpectedly reached the network")
      } catch let error as SDKError {
        #expect(error.code == .invalidConfiguration)
      }
    }
  }

  @Test("Opt-in loopback SMB server exercises native bounded directory queries")
  func nativeDirectoryPaging() async throws {
    guard let value = ProcessInfo.processInfo.environment["STELLAR_SMB_PAGING_TEST_PORT"],
      let port = UInt16(value)
    else { return }
    let request = try SMB2ConnectionRequest(
      endpoint: SMB2Endpoint(server: "127.0.0.1", port: port, share: "fixture"),
      credential: SMB2Credential(username: "fixture", password: "fixture"),
      timeoutMilliseconds: 5_000
    )
    let session = try await AppleSMB2Transport().connect(request)
    let paging = try #require(session as? any SMB2DirectoryPagingSession)
    let root = try SMB2Path()
    let first = try await paging.listDirectoryPage(at: root, cursor: nil, limit: 7)
    #expect(first.items.count == 7)
    let savedCursor = try #require(first.nextCursor)
    #expect(RemoteDirectorySessionCursor.requiresRestart(savedCursor))
    let independent = try await paging.listDirectoryPage(at: root, cursor: nil, limit: 2_000)
    #expect(independent.items.count == 1_201 && independent.nextCursor == nil)
    #expect(try await session.stat(root).kind == .directory)
    let nested = try await paging.listDirectoryPage(at: SMB2Path("Nested"), cursor: nil, limit: 10)
    #expect(nested.items.map(\.path.name) == ["Unicode-中文.mkv"])
    #expect(nested.nextCursor == nil)
    var cursor: String? = savedCursor
    var names = Set(first.items.map(\.path.name))
    repeat {
      let page = try await paging.listDirectoryPage(at: root, cursor: cursor, limit: 37)
      #expect(page.items.count <= 37)
      for entry in page.items { #expect(names.insert(entry.path.name).inserted) }
      cursor = page.nextCursor
    } while cursor != nil
    #expect(names.count == 1_201)
    let file = try SMB2Path("Video-0000.mkv")
    let stat = try await session.stat(file)
    #expect(stat.size == 10)
    #expect(stat.modifiedAtMilliseconds != nil)
    let bytes = try await session.read(at: file, range: SMB2ByteRange(offset: 3, length: 4))
    #expect(bytes == Data("3456".utf8))
    await session.disconnect()
    let newSession = try await AppleSMB2Transport().connect(request)
    let newPaging = try #require(newSession as? any SMB2DirectoryPagingSession)
    do {
      _ = try await newPaging.listDirectoryPage(at: root, cursor: savedCursor, limit: 7)
      Issue.record("A cursor must not survive its native SMB directory handle")
    } catch let error as SDKError { #expect(error.code == .conflict) }
    let cleanup = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await newSession.disconnect()
    }
    await cleanup.value
    do {
      _ = try await newSession.stat(root)
      Issue.record("Cancelled cleanup must still close the native SMB context")
    } catch let error as SDKError { #expect(error.code == .remoteUnavailable) }

    let connector = SMB2MediaSourceConnector(
      transport: AppleSMB2Transport(),
      configuration: try SMB2MediaSourceConfiguration(
        sourceUID: "pooled", connectionRequest: request, directoryConnectionCount: 2
      ))
    let pooled = try await connector.connect()
    let pooledRoot = try RemoteLocator(sourceUID: "pooled", path: RemotePath())
    let outer = try await pooled.listDirectory(
      RemoteDirectoryPageRequest(directory: pooledRoot, limit: 7))
    let probe = try await pooled.listDirectory(
      RemoteDirectoryPageRequest(directory: pooledRoot, limit: 2_000))
    #expect(probe.items.count == 1_201)
    let rest = try await pooled.listDirectory(
      RemoteDirectoryPageRequest(directory: pooledRoot, cursor: outer.nextCursor, limit: 2_000))
    #expect(rest.items.count == 1_194 && rest.nextCursor == nil)
    await pooled.disconnect()
  }

  @Test("Swift task cancellation promptly resolves an in-flight AMSMB2 connect")
  func inFlightCancellation() async throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    try #require(listener >= 0)
    defer { _ = Darwin.close(listener) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Darwin.bind(listener, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(bindResult == 0)
    try #require(Darwin.listen(listener, 1) == 0)
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Darwin.getsockname(listener, socketAddress, &addressLength)
      }
    }
    try #require(nameResult == 0)

    let endpoint = try SMB2Endpoint(
      server: "127.0.0.1",
      port: UInt16(bigEndian: address.sin_port),
      share: "cancel-test"
    )
    let request = try SMB2ConnectionRequest(
      endpoint: endpoint,
      credential: SMB2Credential(username: "guest", password: ""),
      timeoutMilliseconds: 30_000
    )
    let connection = Task {
      try await AppleSMB2Transport().connect(request)
    }
    defer { connection.cancel() }

    var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    try #require(Darwin.poll(&ready, 1, 2_000) == 1)
    let accepted = Darwin.accept(listener, nil, nil)
    try #require(accepted >= 0)
    defer { _ = Darwin.close(accepted) }

    let started = ContinuousClock.now
    connection.cancel()
    do {
      _ = try await connection.value
      Issue.record("cancelled SMB connection unexpectedly succeeded")
    } catch let error as SDKError {
      #expect(error.code == .cancelled)
    }
    #expect(started.duration(to: .now) < .seconds(2))
  }
}
