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
            Section("Permissions") {
                permissionRow("Accessibility", detail: "Needed to close, minimize and focus windows.",
                              granted: accessibility, action: Permissions.requestAccessibility)
                permissionRow("Screen Recording", detail: "Needed for live window thumbnails. Without it, app icons are shown.",
                              granted: screenRecording, action: Permissions.requestScreenRecording)
            }

            Section {
                Toggle("Add buttons and shortcuts to Mission Control", isOn: $settings.enhanceMissionControl)
                Toggle("Show close and minimize buttons on the highlighted window", isOn: $settings.showButtonsOnHover)
            } header: {
                Text("Mission Control")
            } footer: {
                Text("Open Mission Control as usual (⌃↑, F3 or a swipe up), then hover a window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Open window overview with", selection: $settings.hotKey) {
                    ForEach(HotKeyChoice.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Always show window titles in the overview", isOn: $settings.alwaysShowTitles)
            } header: {
                Text("Window Overview")
            } footer: {
                Text("A Mission Control–style overview with search: type to filter windows by title or app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
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
                Text("Also: arrow keys to move · ↵ to open · middle-click a window to close it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 900)
        .onReceive(timer) { _ in
            accessibility = Permissions.accessibility
            screenRecording = Permissions.screenRecording
        }
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
