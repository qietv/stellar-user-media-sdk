# SMB first-keyboard investigation

## Reproduction

Physical iPhone 17 Pro, iOS 26.6.1 (23G83), Xcode 26.6 (17F113), macOS 26.6.2.
The user reports a long first keyboard presentation after reinstalling or restarting the app.
Repeated focus in the same process is not a valid reproduction of that condition.

On 2026-09-09, three Xcode runs used the same Debug code and `--smb-keyboard-probe` entry point.
Each run replaced the previous app process. Normal OAuth restoration and media preparation
completed before Scan opened and requested the password's first responder. The physical
software keyboard produced both `keyboardWillShow` and `keyboardDidShow` notifications.
iPhone Mirroring was not used during these measurements. No password was entered and no scan
was started.

| Run | Debug executable | Focus call returned | Keyboard will show | Keyboard did show | Maximum main-queue delay |
| --- | --- | ---: | ---: | ---: | ---: |
| A1 | Enabled | 2.375998 s | 7.572529 s | 7.626857 s | 5.136637 s |
| B | Disabled | 0.077408 s | 0.119931 s | 0.165883 s | 0.000929 s |
| A2 | Enabled again | 2.946067 s | 9.048024 s | 12.006466 s | 6.003435 s |

Main Thread Checker, Thread Performance Checker and other scheme diagnostics were not toggled
between these trials. Media preparation took 0.054375, 0.054349 and 0.050243 seconds respectively,
and finished before password focus. `Reporter disconnected` messages also appeared in the fast
run, so that warning alone does not identify a hang.

An earlier independent process launch using `devicectl`, without a debugger, measured a
0.182880-second first keyboard presentation. A separate iPhone Mirroring trial had no keyboard
visibility event; it is excluded from the software-keyboard comparison.

## Finding and practical configuration

The slow first-keyboard behavior was reproduced with Xcode debugging enabled, disappeared
when Debug executable was disabled, and returned when it was enabled again. This strongly
isolates this reproduction to the attached-debugger execution environment. It does not identify
the exact LLDB, debugserver or input-service stack responsible; no successful stack capture
from the slow interval is available. Do not label it a proven application-side fix or assume
all first-install keyboard delays have the same cause.

Use **StellarOAuthDemo-Device** for interactive device runs without LLDB. It retains the Debug
build configuration and app logging. Use **StellarOAuthDemo** for breakpoints, memory inspection
and crash debugging. Both schemes start normally unless `--smb-keyboard-probe` is explicitly
added to Run > Arguments. The probe is compiled only in Debug and contains no credential data.

Apple DTS also recommends a Debug executable on/off comparison when investigating Xcode 26
startup stalls: [App Startup with Debugger in Xcode 26 is slow](https://developer.apple.com/forums/thread/800067).
That discussion describes multiple possible debugger causes; it is supporting context rather
than proof of the precise cause on this device.

## Limits

- These controlled trials used fresh app processes with the existing library intact. They did
  not erase the app's data, reset the phone, or clear system keyboard caches.
- Automatic focus uses the real secure password control, but does not measure physical touch
  delivery before `becomeFirstResponder` begins.
- Keyboard timing ends at UIKit's visibility notification, rather than a video frame analysis.
- The main-queue probe measures scheduling delay after the synchronous focus call separately
  from the focus call itself. A large delay establishes unresponsiveness, not the blocking stack.
- The earlier automatic LLDB breakpoint capture was removed after it left execution paused.
  It produced no usable hang stack. These A/B/A runs used no automatic-pausing capture script.
