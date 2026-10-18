import SwiftUI

@MainActor
struct MetaGlassesIntegrationView: View {
    @Environment(\.scenePhase) private var scenePhase

    private var controller: MetaGlassesAudioPlayerController {
        .shared
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Registration", value: controller.registrationState)
                LabeledContent("Connection", value: controller.connectionState.rawValue)
                Text(controller.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let error = controller.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("Detected Glasses") {
                if controller.detectedDevices.isEmpty {
                    Text("No glasses detected.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.detectedDevices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name)
                        Text(device.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Glasses Player displays controls on Meta Ray-Ban Display. Keep the glasses on and unfolded, with Developer Mode enabled in Meta AI. Start a channel on your iPhone to show song information and control live radio here. For audio on glasses without a display, use the iPhone audio output picker.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    controller.startRegistration()
                } label: {
                    Label("Register with Meta AI", systemImage: "link")
                }
                .disabled(controller.isRegistered || controller.connectionState == .registering)

                Button {
                    controller.connect()
                } label: {
                    Label("Connect Glasses Player", systemImage: "eyeglasses")
                }
                .disabled(!controller.canConnect)

                Button(role: .destructive) {
                    Task { await controller.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .disabled(!controller.hasConnectionAttempt || controller.connectionState == .stopping)
            }

            Section {
                Button {
                    controller.openDATGlassesAppUpdate()
                } label: {
                    Label("Open DAT App Update", systemImage: "arrow.triangle.2.circlepath")
                }

                Button {
                    controller.openFirmwareUpdate()
                } label: {
                    Label("Open Glasses Firmware Update", systemImage: "arrow.down.circle")
                }

                Button(role: .destructive) {
                    controller.unregister()
                } label: {
                    Label("Remove Meta Registration", systemImage: "trash")
                }
            }
        }
        .disabled(!controller.isAvailable)
        .listStyle(.insetGrouped)
        .navigationTitle("Meta Glasses")
        .task { controller.refreshDevices() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.refreshDevices() }
        }
    }
}
