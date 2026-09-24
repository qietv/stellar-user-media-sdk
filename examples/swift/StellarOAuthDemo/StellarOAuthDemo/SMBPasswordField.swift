import SwiftUI
import UIKit

/// Keep one UIKit secure responder with stable input traits while the scan model publishes progress.
/// In particular, do not use the one-time-code AutoFill mode for an SMB password.
struct SMBPasswordField: UIViewRepresentable {
  @Binding var text: String
  var isEnabled: Bool

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeUIView(context: Context) -> SMBPasswordTextField {
    let field = SMBPasswordTextField()
    field.placeholder = "Password"
    field.accessibilityLabel = "Password"
    field.accessibilityIdentifier = "smb.password"
    field.borderStyle = .roundedRect
    field.font = .preferredFont(forTextStyle: .body)
    field.adjustsFontForContentSizeCategory = true
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.isSecureTextEntry = true
    field.textContentType = .password
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.spellCheckingType = .no
    field.smartQuotesType = .no
    field.smartDashesType = .no
    field.returnKeyType = .done
    field.clearsOnBeginEditing = false
    field.delegate = context.coordinator
    field.addTarget(
      context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
    return field
  }

  func updateUIView(_ field: SMBPasswordTextField, context: Context) {
    context.coordinator.text = $text
    if !isEnabled, field.isFirstResponder { field.resignFirstResponder() }
    field.isEnabled = isEnabled
    // Reassigning text during unrelated SwiftUI updates disturbs selection and marked text.
    if field.text != text, field.markedTextRange == nil { field.text = text }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: SMBPasswordTextField, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 180, height: max(36, uiView.intrinsicContentSize.height))
  }

  static func dismantleUIView(_ field: SMBPasswordTextField, coordinator: Coordinator) {
    field.resignFirstResponder()
    field.delegate = nil
    field.removeTarget(coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
  }

  final class Coordinator: NSObject, UITextFieldDelegate {
    var text: Binding<String>
    init(text: Binding<String>) { self.text = text }

    @objc func edited(_ field: UITextField) {
      let value = field.text ?? ""
      if text.wrappedValue != value { text.wrappedValue = value }
    }

    func textFieldDidEndEditing(_ textField: UITextField) { edited(textField) }

    func textField(
      _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
      replacementString string: String
    ) -> Bool {
      // The secure editor can clear its old value on the first insertion after refocusing,
      // even with clearsOnInsertion disabled. Apply the requested range to the existing draft.
      // Let UIKit own an active input-method composition.
      guard textField.markedTextRange == nil else { return true }
      let current = textField.text ?? ""
      guard let replacement = Range(range, in: current) else { return false }
      textField.text = current.replacingCharacters(in: replacement, with: string)
      if let caret = textField.position(
        from: textField.beginningOfDocument, offset: range.location + string.utf16.count)
      {
        textField.selectedTextRange = textField.textRange(from: caret, to: caret)
      }
      edited(textField)
      return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      textField.resignFirstResponder()
      return false
    }
  }
}

final class SMBPasswordTextField: UITextField {
  @discardableResult override func becomeFirstResponder() -> Bool {
    guard !isFirstResponder else { return super.becomeFirstResponder() }
    #if DEBUG
      let startedAt = ProcessInfo.processInfo.systemUptime
      focusStartedAt = startedAt
      focusAttempt += 1
      probeCount = 0
      maximumMainQueueDelay = 0
      nextProbeAt = nil
      demoLaunchLogger.notice("phase=smb-password-focus-started")
    #endif
    let accepted = super.becomeFirstResponder()
    // UIKit enables replacement-on-insertion when a secure field regains focus.
    // Preserve the user's draft so switching to another SMB field does not erase it.
    if accepted {
      clearsOnInsertion = false
      selectedTextRange = textRange(from: endOfDocument, to: endOfDocument)
    }
    #if DEBUG
      let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
      demoLaunchLogger.notice(
        "phase=smb-password-focus-returned elapsed-seconds=\(elapsed, privacy: .public) accepted=\(accepted, privacy: .public)"
      )
      if accepted, focusStartedAt != nil {
        // Measure responsiveness after the synchronous focus call separately from its duration.
        nextProbeAt = ProcessInfo.processInfo.systemUptime
        let attempt = focusAttempt
        DispatchQueue.main.async { [weak self] in self?.probeMainQueue(attempt: attempt) }
      } else {
        focusStartedAt = nil
      }
    #endif
    return accepted
  }

  #if DEBUG
    static let diagnosticFocusNotification = Notification.Name("DemoSMBPasswordFocusRequested")
    private var focusStartedAt: TimeInterval?
    private var focusAttempt = 0
    private var probeCount = 0
    private var nextProbeAt: TimeInterval?
    private var maximumMainQueueDelay: TimeInterval = 0
    private var diagnosticFocusDeadline: TimeInterval?

    override init(frame: CGRect) {
      super.init(frame: frame)
      NotificationCenter.default.addObserver(
        self, selector: #selector(keyboardDidShow), name: UIResponder.keyboardDidShowNotification,
        object: nil)
      NotificationCenter.default.addObserver(
        self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification,
        object: nil)
      NotificationCenter.default.addObserver(
        self, selector: #selector(applicationWillResignActive),
        name: UIApplication.willResignActiveNotification, object: nil)
      NotificationCenter.default.addObserver(
        self, selector: #selector(requestDiagnosticFocus),
        name: Self.diagnosticFocusNotification, object: nil)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    @objc private func requestDiagnosticFocus() {
      guard ProcessInfo.processInfo.arguments.contains("--smb-keyboard-probe") else { return }
      let now = ProcessInfo.processInfo.systemUptime
      if diagnosticFocusDeadline == nil { diagnosticFocusDeadline = now + 10 }
      let attached = window != nil
      let active = UIApplication.shared.applicationState == .active
      guard attached, isEnabled, active else {
        guard now < (diagnosticFocusDeadline ?? now) else {
          demoLaunchLogger.notice(
            "phase=smb-keyboard-probe-unavailable attached=\(attached, privacy: .public) enabled=\(self.isEnabled, privacy: .public) active=\(active, privacy: .public)"
          )
          return
        }
        // A debugger launch can finish mounting the form before the app becomes active.
        // Wait for an eligible first focus; do not count an inactive launch as a fast keyboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          self?.requestDiagnosticFocus()
        }
        return
      }
      becomeFirstResponder()
    }

    @discardableResult override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned { finishFocusProbe(reason: "focus-ended") }
      return resigned
    }

    @objc private func keyboardWillShow() {
      guard isFirstResponder, let startedAt = focusStartedAt else { return }
      let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
      demoLaunchLogger.notice(
        "phase=smb-password-keyboard-will-show elapsed-seconds=\(elapsed, privacy: .public)"
      )
    }

    @objc private func keyboardDidShow() {
      guard isFirstResponder, let startedAt = focusStartedAt else { return }
      let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
      demoLaunchLogger.notice(
        "phase=smb-password-keyboard-visible elapsed-seconds=\(elapsed, privacy: .public)"
      )
      finishFocusProbe(reason: "keyboard-visible")
    }

    @objc private func applicationWillResignActive() {
      // Backgrounding or an authentication sheet must not count as an input-service stall.
      finishFocusProbe(reason: "app-inactive")
    }

    private func probeMainQueue(attempt: Int) {
      guard attempt == focusAttempt, let startedAt = focusStartedAt else { return }
      let now = ProcessInfo.processInfo.systemUptime
      let delay = max(0, now - (nextProbeAt ?? now))
      maximumMainQueueDelay = max(maximumMainQueueDelay, delay)
      probeCount += 1
      if delay >= 0.25 {
        demoLaunchLogger.notice(
          "phase=smb-password-main-queue-delayed delay-seconds=\(delay, privacy: .public)"
        )
      }
      // Refocusing an already visible keyboard, or using a hardware keyboard, need not send
      // another didShow notification. Bound this Debug-only probe to 15 seconds per focus.
      guard now - startedAt < 15 else {
        finishFocusProbe(reason: "observation-timeout")
        return
      }
      nextProbeAt = now + 0.1
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.probeMainQueue(attempt: attempt)
      }
    }

    private func finishFocusProbe(reason: String) {
      guard let startedAt = focusStartedAt else { return }
      let now = ProcessInfo.processInfo.systemUptime
      // A keyboard notification can arrive before an overdue queued probe. Include that wait.
      if let nextProbeAt {
        maximumMainQueueDelay = max(maximumMainQueueDelay, max(0, now - nextProbeAt))
      }
      let elapsed = now - startedAt
      demoLaunchLogger.notice(
        "phase=smb-password-focus-observed reason=\(reason, privacy: .public) elapsed-seconds=\(elapsed, privacy: .public) main-queue-max-delay-seconds=\(self.maximumMainQueueDelay, privacy: .public) probe-count=\(self.probeCount, privacy: .public)"
      )
      focusStartedAt = nil
      nextProbeAt = nil
    }
  #endif
}
