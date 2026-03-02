import SwiftUI
import StarPlayrRadioKit

struct XMSettingsView: View {
    @Environment(XMRadioService.self) private var radioService

    @State private var selectedRegion = appRegion
    @State private var resumeLastChannel = UserDefaults.standard.bool(forKey: "xm_resume_last_channel")

    var body: some View {
        List {
            Section("Playback") {
                Toggle("Resume Last Channel", isOn: $resumeLastChannel)
                    .onChange(of: resumeLastChannel) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "xm_resume_last_channel")
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
