import SwiftUI

struct SMBScanView: View {
  @ObservedObject var model: MediaLibraryModel
  @State private var password = ""

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          connectionCard
          statusCard
        }
        .padding()
      }
      .navigationTitle("SMB Scan")
    }
  }

  private var connectionCard: some View {
    GroupBox("Source") {
      VStack(spacing: 12) {
        HStack(spacing: 12) {
          field("Server", text: $model.server)
          field("Port (optional)", text: $model.port, keyboard: .numberPad)
            .frame(maxWidth: 130)
        }
        field("Share", text: $model.share)
        field("Root path (optional)", text: $model.rootPath)
        field("Username", text: $model.username)
        SecureField("Password", text: $password)
          // SMB credentials are not web credentials. This prevents Password AutoFill from
          // doing an associated-domain lookup when the field first becomes focused.
          .textContentType(.oneTimeCode)
          .textFieldStyle(.roundedBorder)
          .disabled(model.credentialInputIsDisabled)

        Toggle("Prefetch video thumbnails while idle", isOn: $model.prefetchVideoThumbnailsWhenIdle)
          .disabled(model.credentialInputIsDisabled)
        Toggle("Inspect technical metadata (low priority)", isOn: $model.enableTechnicalProbe)
          .disabled(model.credentialInputIsDisabled)

        HStack(spacing: 10) {
          Button(model.primaryActionTitle) {
            model.password = password
            model.startOrResume()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canStartOrResume)

          Button("Pause") {
            model.pause()
          }
          .buttonStyle(.bordered)
          .disabled(!model.canPause)

          Button("Repair failed metadata") {
            model.password = password
            model.repairFailedMetadata()
          }
          .buttonStyle(.bordered)
          .disabled(!model.canRepair)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Label(MediaLibraryModel.mediaServiceOrigin, systemImage: "server.rack")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var statusCard: some View {
    GroupBox("Progress") {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label(model.scanState.label, systemImage: stateIcon)
            .font(.headline)
            .foregroundStyle(stateColor)
          Spacer()
          if [.preparing, .scanning, .enriching, .pausing].contains(model.scanState) {
            ProgressView()
          }
        }

        HStack(spacing: 8) {
          metric(title: "Found", value: model.discoveredEntryCount)
          metric(title: "Pages", value: model.processedPageCount)
          metric(title: "Pending", value: Int64(model.pendingPageCount))
        }

        HStack(spacing: 8) {
          metric(title: "Videos", value: Int64(model.mediaFileCount))
          metric(title: "Matched", value: Int64(model.matchedFileCount))
          metric(title: "Failed", value: Int64(model.failedFileCount))
        }

        if let currentFile = model.currentFile {
          Divider()
          Text("Current file")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(currentFile)
            .font(.caption.monospaced())
            .lineLimit(3)
            .textSelection(.enabled)
        }

        Text(model.notice)
          .font(.callout)
          .foregroundStyle(model.noticeIsError ? Color.red : Color.secondary)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func field(
    _ title: String,
    text: Binding<String>,
    keyboard: UIKeyboardType = .default
  ) -> some View {
    TextField(title, text: text)
      .keyboardType(keyboard)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .textFieldStyle(.roundedBorder)
      .disabled(model.inputsAreDisabled)
  }

  private func metric(title: String, value: Int64) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value.formatted())
        .font(.headline.monospacedDigit())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
  }

  private var stateColor: Color {
    switch model.scanState {
    case .completed: .green
    case .failed: .red
    case .preparing, .scanning, .enriching, .pausing: .orange
    case .paused: .blue
    case .idle: .secondary
    }
  }

  private var stateIcon: String {
    switch model.scanState {
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .paused: "pause.circle.fill"
    case .preparing, .scanning, .enriching, .pausing: "arrow.trianglehead.2.clockwise"
    case .idle: "circle.dashed"
    }
  }
}

#Preview {
  SMBScanView(model: MediaLibraryModel())
}
