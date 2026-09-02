#if canImport(StellarSMB2Apple)
  import Foundation
  import StellarSMB2Apple
  import StellarSMB2Core
  import StellarUserMediaSDK

  private typealias SMBPlatformTransport = AppleSMB2Transport

  #if canImport(Darwin)
    import Darwin
  #endif

  enum SMBCLICommand {
    static func run(arguments: [String]) async -> Int32 {
      guard let command = arguments.first else {
        writeError("smb expects check, list, or scan")
        return 2
      }
      guard ["check", "list", "scan"].contains(command) else {
        writeError("smb expects check, list, or scan")
        return 2
      }

      let options: SMBCLIOptions
      do {
        options = try SMBCLIOptions(arguments: Array(arguments.dropFirst()))
      } catch let error as SDKError {
        writeError(error.message)
        return 2
      } catch {
        writeError("invalid SMB options")
        return 2
      }

      let request: SMB2ConnectionRequest
      do {
        request = try options.makeRequest()
      } catch let error as SDKError {
        writeError(error.message)
        return 2
      } catch {
        writeError("invalid SMB configuration")
        return 2
      }

      switch command {
      case "check":
        return await check(request: request)
      case "list":
        return await list(request: request, path: options.path)
      case "scan":
        return await scan(request: request)
      default:
        writeError("smb expects check, list, or scan")
        return 2
      }
    }

    private static func check(request: SMB2ConnectionRequest) async -> Int32 {
      do {
        let session = try await SMBPlatformTransport().connect(request)
        let info = await session.connectionInfo
        await session.disconnect()
        try printJSON(
          SMBCheckOutput(
            schema: "stellar.smb.check.v1",
            result: "success",
            dialect: info.dialect.description,
            signingPolicy: signingLabel(info.signingPolicy),
            encryptionPolicy: encryptionLabel(info.encryptionPolicy),
            implementation: info.implementationVersion
          ))
        return 0
      } catch {
        writeSDKError(error)
        return 1
      }
    }

    private static func list(request: SMB2ConnectionRequest, path: SMB2Path) async -> Int32 {
      do {
        let session = try await SMBPlatformTransport().connect(request)
        do {
          let entries = try await session.listDirectory(at: path)
            .sorted { $0.path.relativePath < $1.path.relativePath }
          for entry in entries {
            try printJSON(
              SMBListEntryOutput(
                path: entry.path.relativePath,
                kind: kindLabel(entry.kind),
                size: entry.size,
                modifiedAtMilliseconds: entry.modifiedAtMilliseconds,
                stableID: entry.stableID
              ))
          }
          await session.disconnect()
          return 0
        } catch {
          await session.disconnect()
          throw error
        }
      } catch {
        writeSDKError(error)
        return 1
      }
    }

    private static func scan(request: SMB2ConnectionRequest) async -> Int32 {
      let clock = SystemSDKClock()
      let startedAt = clock.nowMilliseconds()
      var entryCount = 0
      var directoryCount = 0
      var fileCount = 0
      var session: (any SMB2Session)?

      do {
        let connectedSession = try await SMBPlatformTransport().connect(request)
        session = connectedSession
        let info = await connectedSession.connectionInfo
        var directories = [try SMB2Path()]
        var nextDirectoryIndex = 0
        var visited = Set<SMB2Path>()

        while nextDirectoryIndex < directories.count {
          let directory = directories[nextDirectoryIndex]
          nextDirectoryIndex += 1
          guard visited.insert(directory).inserted else {
            continue
          }
          directoryCount += 1
          let entries = try await connectedSession.listDirectory(at: directory)
            .sorted { $0.path.relativePath < $1.path.relativePath }
          for entry in entries {
            entryCount += 1
            if entry.kind == .directory {
              directories.append(entry.path)
            } else if entry.kind == .file {
              fileCount += 1
            }
            try printJSON(
              SMBScanEntryOutput(
                schema: "stellar.smb.scan-entry.v1",
                ordinal: entryCount,
                depth: entry.path.relativePath.split(separator: "/").count,
                kind: kindLabel(entry.kind),
                size: entry.size,
                modifiedAtMilliseconds: entry.modifiedAtMilliseconds,
                stableID: entry.stableID
              ))
          }
        }

        await connectedSession.disconnect()
        try printJSON(
          SMBScanSummaryOutput(
            schema: "stellar.smb.scan-summary.v1",
            source: "smb-redacted",
            scope: "configured-root",
            startedAtMilliseconds: startedAt,
            finishedAtMilliseconds: clock.nowMilliseconds(),
            result: "complete",
            errorCode: nil,
            entryCount: entryCount,
            directoryCount: directoryCount,
            fileCount: fileCount,
            dialect: info.dialect.description,
            implementation: info.implementationVersion
          ))
        return 0
      } catch {
        if let session {
          await session.disconnect()
        }
        let sdkError = normalizedError(error)
        try? printJSON(
          SMBScanSummaryOutput(
            schema: "stellar.smb.scan-summary.v1",
            source: "smb-redacted",
            scope: "configured-root",
            startedAtMilliseconds: startedAt,
            finishedAtMilliseconds: clock.nowMilliseconds(),
            result: "failed",
            errorCode: sdkError.code.rawValue,
            entryCount: entryCount,
            directoryCount: directoryCount,
            fileCount: fileCount,
            dialect: nil,
            implementation: "AMSMB2-4.0.3@1726aaaf7adf"
          ))
        writeError(sdkError.message)
        return sdkError.code == .cancelled ? 130 : 1
      }
    }

    private static func normalizedError(_ error: Error) -> SDKError {
      error as? SDKError ?? SDKError(code: .unknown, message: "SMB operation failed")
    }

    private static func writeSDKError(_ error: Error) {
      writeError(normalizedError(error).message)
    }

    private static func writeError(_ message: String) {
      let safeMessage = SensitiveDataRedactor().redact(message: message)
      FileHandle.standardError.write(Data("error: \(safeMessage)\n".utf8))
    }

    private static func printJSON<Value: Encodable>(_ value: Value) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(value)
      guard let output = String(data: data, encoding: .utf8) else {
        throw SDKError(code: .parseFailure, message: "failed to encode SMB output")
      }
      print(output)
    }

    private static func kindLabel(_ kind: SMB2EntryKind) -> String {
      switch kind {
      case .file: "file"
      case .directory: "directory"
      case .symbolicLink: "symbolic_link"
      case .unknown(let value): "unknown-\(value)"
      }
    }

    private static func signingLabel(_ policy: SMB2SigningPolicy) -> String {
      switch policy {
      case .enabled: "enabled"
      case .required: "required"
      }
    }

    private static func encryptionLabel(_ policy: SMB2EncryptionPolicy) -> String {
      switch policy {
      case .disabled: "disabled"
      case .required: "required"
      }
    }
  }

  private struct SMBCLIOptions {
    let server: String
    let port: UInt16?
    let share: String
    let rootPath: String
    let domain: String?
    let username: String
    let path: SMB2Path
    let versionPolicy: SMB2VersionPolicy
    let signingPolicy: SMB2SigningPolicy
    let encryptionPolicy: SMB2EncryptionPolicy
    let timeoutMilliseconds: Int64
    let readsPasswordFromStandardInput: Bool

    init(arguments: [String]) throws {
      var values: [String: String] = [:]
      var passwordFromStandardInput = false
      var index = 0

      while index < arguments.count {
        let option = arguments[index]
        if option == "--password-stdin" {
          passwordFromStandardInput = true
          index += 1
          continue
        }
        if option == "--password" || option.hasPrefix("--password=") {
          throw SDKError(
            code: .invalidConfiguration,
            message: "credential values are not accepted in command arguments"
          )
        }
        let valueOptions: Set<String> = [
          "--server", "--port", "--share", "--root", "--domain", "--username", "--path",
          "--version", "--signing", "--encryption", "--timeout-ms",
        ]
        guard valueOptions.contains(option), index + 1 < arguments.count else {
          throw SDKError(code: .invalidConfiguration, message: "invalid SMB command option")
        }
        guard values[option] == nil else {
          throw SDKError(code: .invalidConfiguration, message: "duplicate SMB command option")
        }
        values[option] = arguments[index + 1]
        index += 2
      }

      guard let server = values["--server"], let share = values["--share"],
        let username = values["--username"], passwordFromStandardInput
      else {
        throw SDKError(
          code: .invalidConfiguration,
          message: "--server, --share, --username, and stdin credential input are required"
        )
      }
      self.server = server
      self.share = share
      self.username = username
      port = try values["--port"].map { value in
        guard let port = UInt16(value), port > 0 else {
          throw SDKError(code: .invalidConfiguration, message: "SMB port is invalid")
        }
        return port
      }
      rootPath = values["--root"] ?? ""
      domain = values["--domain"]
      path = try SMB2Path(values["--path"] ?? "")
      versionPolicy = try Self.parseVersion(values["--version"] ?? "any")
      signingPolicy = try Self.parseSigning(values["--signing"] ?? "enabled")
      encryptionPolicy = try Self.parseEncryption(values["--encryption"] ?? "disabled")
      timeoutMilliseconds =
        try values["--timeout-ms"].map { value in
          guard let timeout = Int64(value) else {
            throw SDKError(code: .invalidConfiguration, message: "SMB timeout is invalid")
          }
          return timeout
        } ?? 30_000
      readsPasswordFromStandardInput = passwordFromStandardInput
    }

    func makeRequest() throws -> SMB2ConnectionRequest {
      let endpoint = try SMB2Endpoint(
        server: server,
        port: port,
        share: share,
        rootPath: rootPath
      )
      _ = try SMB2ConnectionRequest(
        endpoint: endpoint,
        credential: SMB2Credential(domain: domain, username: username, password: ""),
        versionPolicy: versionPolicy,
        signingPolicy: signingPolicy,
        encryptionPolicy: encryptionPolicy,
        timeoutMilliseconds: timeoutMilliseconds
      )
      guard readsPasswordFromStandardInput, isatty(STDIN_FILENO) == 0,
        let password = readLine(strippingNewline: true)
      else {
        throw SDKError(code: .credentialRequired, message: "SMB credential is required on stdin")
      }
      return try SMB2ConnectionRequest(
        endpoint: endpoint,
        credential: SMB2Credential(domain: domain, username: username, password: password),
        versionPolicy: versionPolicy,
        signingPolicy: signingPolicy,
        encryptionPolicy: encryptionPolicy,
        timeoutMilliseconds: timeoutMilliseconds
      )
    }

    private static func parseVersion(_ value: String) throws -> SMB2VersionPolicy {
      switch value {
      case "any": .anySupported
      case "2": .smb2Only
      case "3": .smb3Only
      case "2.0.2": .exact(.smb202)
      case "2.1": .exact(.smb210)
      case "3.0": .exact(.smb300)
      case "3.0.2": .exact(.smb302)
      case "3.1.1": .exact(.smb311)
      default:
        throw SDKError(code: .invalidConfiguration, message: "SMB version is invalid")
      }
    }

    private static func parseSigning(_ value: String) throws -> SMB2SigningPolicy {
      switch value {
      case "enabled": .enabled
      case "required": .required
      default:
        throw SDKError(code: .invalidConfiguration, message: "SMB signing policy is invalid")
      }
    }

    private static func parseEncryption(_ value: String) throws -> SMB2EncryptionPolicy {
      switch value {
      case "disabled": .disabled
      case "required": .required
      default:
        throw SDKError(code: .invalidConfiguration, message: "SMB encryption policy is invalid")
      }
    }
  }

  private struct SMBCheckOutput: Encodable {
    let schema: String
    let result: String
    let dialect: String
    let signingPolicy: String
    let encryptionPolicy: String
    let implementation: String

    private enum CodingKeys: String, CodingKey {
      case schema
      case result
      case dialect
      case signingPolicy = "signing_policy"
      case encryptionPolicy = "encryption_policy"
      case implementation
    }
  }

  private struct SMBListEntryOutput: Encodable {
    let path: String
    let kind: String
    let size: Int64?
    let modifiedAtMilliseconds: Int64?
    let stableID: String?

    private enum CodingKeys: String, CodingKey {
      case path
      case kind
      case size
      case modifiedAtMilliseconds = "modified_at_ms"
      case stableID = "stable_id"
    }
  }

  private struct SMBScanEntryOutput: Encodable {
    let schema: String
    let ordinal: Int
    let depth: Int
    let kind: String
    let size: Int64?
    let modifiedAtMilliseconds: Int64?
    let stableID: String?

    private enum CodingKeys: String, CodingKey {
      case schema
      case ordinal
      case depth
      case kind
      case size
      case modifiedAtMilliseconds = "modified_at_ms"
      case stableID = "stable_id"
    }
  }

  private struct SMBScanSummaryOutput: Encodable {
    let schema: String
    let source: String
    let scope: String
    let startedAtMilliseconds: Int64
    let finishedAtMilliseconds: Int64
    let result: String
    let errorCode: String?
    let entryCount: Int
    let directoryCount: Int
    let fileCount: Int
    let dialect: String?
    let implementation: String

    private enum CodingKeys: String, CodingKey {
      case schema
      case source
      case scope
      case startedAtMilliseconds = "started_at_ms"
      case finishedAtMilliseconds = "finished_at_ms"
      case result
      case errorCode = "error_code"
      case entryCount = "entry_count"
      case directoryCount = "directory_count"
      case fileCount = "file_count"
      case dialect
      case implementation
    }
  }
#endif
