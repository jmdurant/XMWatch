import SwiftUI
import StarPlayrRadioKit

struct SettingsView: View {
    @Environment(XMRadioService.self) private var radioService

    @State private var selectedRegion = appRegion
    @State private var resumeLastChannel = UserDefaults.standard.bool(forKey: "xm_resume_last_channel")
    @State private var debugMode = UserDefaults.standard.bool(forKey: "xm_debug_mode")
    @AppStorage("xm_appearance") private var appearance = "system"

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Resume Last Channel", isOn: $resumeLastChannel)
                    .onChange(of: resumeLastChannel) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "xm_resume_last_channel")
                    }
            }

            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }

            Section("Region") {
                Picker("Region", selection: $selectedRegion) {
                    Text("United States").tag("US")
                    Text("Canada").tag("CA")
                }
                .onChange(of: selectedRegion) { _, newValue in
                    Task {
                        await radioService.configure(region: newValue)
                    }
                }
            }

            Section("Debug") {
                Toggle("Debug Mode", isOn: $debugMode)
                    .onChange(of: debugMode) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "xm_debug_mode")
                    }
            }

            Section("Account") {
                if let email = UserDefaults.standard.string(forKey: "email"), !email.isEmpty {
                    LabeledContent("Email", value: email)
                }

                if let user = UserDefaults.standard.string(forKey: "user"), !user.isEmpty {
                    LabeledContent("Username", value: user)
                }

                Button(role: .destructive) {
                    XMHLSProxyServer.shared.stop()
                    radioService.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("Settings")
    }
}
