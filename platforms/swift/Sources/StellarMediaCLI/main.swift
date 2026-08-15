import Foundation
import StellarUserMediaSDK

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private enum StellarMediaCLI {
  private static let redactor = SensitiveDataRedactor()

  static func run(arguments: [String]) -> Int32 {
    guard let command = arguments.first else {
      printUsage()
      return 0
    }

    switch command {
    case "version", "--version", "-v":
      print(StellarUserMediaSDK.version)
      return 0

    case "help", "--help", "-h":
      printUsage()
      return 0

    case "parse":
      guard arguments.count == 2 else {
        writeError("parse expects exactly one file path")
        return 2
      }
      return printParseResult(for: arguments[1])

    default:
      writeError("unknown command: \(redactor.redact(commandLineArgument: command))")
      printUsage(toStandardError: true)
      return 2
    }
  }

  private static func printParseResult(for path: String) -> Int32 {
    let result = MediaFilenameParser().parse(path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    do {
      let data = try encoder.encode(result)
      guard let output = String(data: data, encoding: .utf8) else {
        writeError("failed to encode UTF-8 output")
        return 1
      }
      print(output)
      return 0
    } catch {
      writeError("failed to encode parse result")
      return 1
    }
  }

  private static func printUsage(toStandardError: Bool = false) {
    let usage = """
      stellar-media \(StellarUserMediaSDK.version)

      Usage:
        stellar-media parse <file-path>
        stellar-media version
        stellar-media help
      """
    if toStandardError {
      writeError(usage, prefix: false)
    } else {
      print(usage)
    }
  }

  private static func writeError(_ message: String, prefix: Bool = true) {
    let safeMessage = redactor.redact(message: message)
    let output = prefix ? "error: \(safeMessage)\n" : "\(safeMessage)\n"
    FileHandle.standardError.write(Data(output.utf8))
  }
}

let exitCode = StellarMediaCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
if exitCode != 0 {
  exit(exitCode)
}
