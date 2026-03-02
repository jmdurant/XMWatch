import SwiftUI

struct XMSignInView: View {
    @Environment(XMRadioService.self) private var radioService

    @State private var isSigningIn = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "radio")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)

                Text("XMWatch")
                    .font(.title3)
                    .fontWeight(.bold)

                Button {
                    Task { await signIn() }
                } label: {
                    Label("Sign In", systemImage: "person.crop.circle")
                }
                .disabled(isSigningIn)

                if isSigningIn {
                    ProgressView()
                }

                if let errorMessage = radioService.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                // Live debug log
                if !radioService.debugLog.isEmpty {
                    Text(radioService.debugLog)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.green)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }

    private func signIn() async {
        isSigningIn = true
        _ = await radioService.signIn(
            username: "jamesdurantjr2016@gmail.com",
            password: "JMD2isme!"
        )
        isSigningIn = false
    }
}
