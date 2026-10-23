import SwiftUI

struct SignInView: View {
    @Environment(XMRadioService.self) private var radioService

    @State private var isSigningIn = false
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .shadow(radius: 8)

            Text("XMWatch")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Satellite Radio")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("Username or email", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320)
            .disabled(isSigningIn)

            Button {
                Task { await signIn() }
            } label: {
                Label("Sign In", systemImage: "person.crop.circle")
                    .font(.headline)
                    .frame(maxWidth: 280)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)

            if isSigningIn {
                ProgressView()
            }

            if let errorMessage = radioService.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if UserDefaults.standard.bool(forKey: "xm_debug_mode"),
               !radioService.debugLog.isEmpty {
                ScrollView {
                    Text(radioService.debugLog)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                .frame(maxHeight: 200)
            }

            Spacer()
        }
        .padding()
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
