#if canImport(StellarSMB2Linux)
  import StellarSMB2Linux
  import Testing

  @Suite("Linux SMB2 transport")
  struct LinuxSMB2TransportTests {
    @Test("The production transport can be constructed without opening a connection")
    func construction() {
      _ = LinuxSMB2Transport()
    }
  }
#endif
