import SwiftUI

struct XMSignInView: View {
    @Environment(XMRadioService.self) private var radioService

    @State private var isSigningIn = false
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                Text("XMWatch")
                    .font(.title3)
                    .fontWeight(.bold)

                TextField("Username or email", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isSigningIn)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .disabled(isSigningIn)

                Button {
                    Task { await signIn() }
                } label: {
                    Label("Sign In", systemImage: "person.crop.circle")
                }
                .disabled(isSigningIn || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)

                if isSigningIn {
                    ProgressView()
                }

                if let errorMessage = radioService.errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                if UserDefaults.standard.bool(forKey: "xm_debug_mode"),
                   !radioService.debugLog.isEmpty {
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
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSigningIn, !user.isEmpty, !password.isEmpty else { return }
        isSigningIn = true
        defer {
            isSigningIn = false
            password = ""
        }
        _ = await radioService.signIn(username: user, password: password)
    }
}
