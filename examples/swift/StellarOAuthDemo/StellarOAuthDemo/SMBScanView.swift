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
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("SMB Scan")
      .onAppear {
        demoLaunchLogger.notice("phase=smb-scan-appeared")
      }
    }
  }

  private var connectionCard: some View {
    GroupBox("Source") {
      VStack(spacing: 12) {
        if model.inputsAreDisabled {
          VStack(alignment: .leading, spacing: 8) {
            Label(
              model.scanState == .paused
                ? "Source locked for a paused scan"
                : "Source locked while scanning",
              systemImage: "lock.fill"
            )
            .font(.subheadline.weight(.medium))
            if model.canEditSource {
              Text(
                "Enter your username and password to resume, or edit the source. Saved progress is kept."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              Button("Edit source") { model.editSource() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("smb.editSource")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.isEditingSource {
          Text("Saved progress is kept. Starting the same source resumes its unfinished scan.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 12) {
          field("Server", text: $model.server)
          field("Port (optional)", text: $model.port, keyboard: .numberPad)
            .frame(maxWidth: 130)
        }
        field("Share", text: $model.share)
        field("Root path (optional)", text: $model.rootPath)
        Toggle("Scan one subdirectory only", isOn: $model.scansIncrementalScope)
          .disabled(model.inputsAreDisabled)
        if model.scansIncrementalScope {
          field("Incremental scope (root-relative)", text: $model.incrementalScope)
        }
        field("Username", text: $model.username, isCredential: true)
          .textContentType(.username)
        SMBPasswordField(text: $password, isEnabled: !model.credentialInputIsDisabled)

        Toggle("Prefetch video thumbnails while idle", isOn: $model.prefetchVideoThumbnailsWhenIdle)
          .disabled(model.credentialInputIsDisabled)
        Toggle("Inspect technical metadata (low priority)", isOn: $model.enableTechnicalProbe)
          .disabled(model.credentialInputIsDisabled)
        Toggle("Inspect optical-disc playlists", isOn: $model.enableDiscProbe)
          .disabled(model.credentialInputIsDisabled)
        Toggle("Rescan every 15 minutes while active", isOn: $model.automaticScanning)
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
    keyboard: UIKeyboardType = .default,
    isCredential: Bool = false
  ) -> some View {
    TextField(title, text: text)
      .keyboardType(keyboard)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .textFieldStyle(.roundedBorder)
      .disabled(isCredential ? model.credentialInputIsDisabled : model.inputsAreDisabled)
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
    case .preparing, .scanning, .enriching, .pausing, .partial: .orange
    case .paused: .blue
    case .idle: .secondary
    }
  }

  private var stateIcon: String {
    switch model.scanState {
    case .completed: "checkmark.circle.fill"
    case .failed, .partial: "exclamationmark.triangle.fill"
    case .paused: "pause.circle.fill"
    case .preparing, .scanning, .enriching, .pausing: "arrow.trianglehead.2.clockwise"
    case .idle: "circle.dashed"
    }
  }
}

#Preview {
  SMBScanView(model: MediaLibraryModel())
}
