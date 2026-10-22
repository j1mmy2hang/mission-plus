import AppKit
import Combine
import ServiceManagement
import SwiftUI

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var settings = Settings.shared
    @State private var accessibility = Permissions.accessibility
    @State private var screenRecording = Permissions.screenRecording
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !accessibility || !screenRecording {
                Section("Permissions") {
                    permissionRow("Accessibility", detail: "Needed to close, minimize and focus windows.",
                                  granted: accessibility, action: Permissions.requestAccessibility)
                    permissionRow("Screen Recording", detail: "Needed for live window thumbnails. Without it, app icons are shown.",
                                  granted: screenRecording, action: Permissions.requestScreenRecording)
                }
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }

            Section("Swipe up with three or four fingers opens") {
                Picker("Swipe up opens", selection: $settings.swipeOpensOverview) {
                    choice("Window Overview",
                           detail: "Mission Plus's overview, with search. Swipe down closes it. Mission Control stays on ⌃↑ and F3.")
                        .tag(true)
                    choice("Mission Control",
                           detail: "The macOS default. Open the overview with its shortcut below or from the menu bar icon.")
                        .tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section("Window Overview") {
                LabeledContent("Shortcut") { ShortcutRecorder(spec: $settings.hotKey, isRecording: $settings.isRecordingHotKey) }
                Toggle("Show all window titles", isOn: $settings.alwaysShowTitles)
            }

            Section {
                ForEach(Shortcut.allCases) { shortcut in
                    Toggle(isOn: Binding(get: { settings.isEnabled(shortcut) },
                                         set: { settings.setEnabled(shortcut, $0) })) {
                        HStack {
                            Text(shortcut.keys).monospaced().frame(width: 52, alignment: .leading)
                            Text(shortcut.label)
                        }
                    }
                }
            } header: {
                Text("Shortcuts for the highlighted window")
            } footer: {
                Text("Work in Mission Control and the overview, along with the close and minimize buttons. Also: arrow keys to move, ↵ to open, middle-click to close.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .frame(width: 540, height: 720)
        .onReceive(timer) { _ in
            accessibility = Permissions.accessibility
            screenRecording = Permissions.screenRecording
        }
    }

    private func choice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    private func permissionRow(_ name: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: action) }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Click, then press the new key combination. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var spec: HotKeySpec
    @Binding var isRecording: Bool
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        HStack(spacing: 8) {
            if spec != .standard && !isRecording {
                Button("Reset") { spec = .standard }
                    .buttonStyle(.link)
            }
            Button(action: { isRecording ? stop() : start() }) {
                Text(isRecording ? (rejected ? "Add ⌃, ⌥ or ⌘" : "Press keys…") : spec.label)
                    .monospaced()
                    .frame(minWidth: 96)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        rejected = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stop()
            } else if let new = HotKeySpec(event: event) {
                spec = new
                stop()
            } else {
                rejected = true // a plain key would steal normal typing
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
