#if canImport(StellarSMB2Apple) && os(macOS)
  import Darwin
  import StellarCore
  import StellarSMB2Apple
  import StellarSMB2Core
  import Testing

  @Suite("Apple SMB2 transport")
  struct AppleSMB2TransportTests {
    @Test("The Apple transport can be constructed without opening a connection")
    func construction() {
      _ = AppleSMB2Transport()
    }

    @Test("Swift task cancellation interrupts an in-flight Apple libsmb2 connect")
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
#endif
