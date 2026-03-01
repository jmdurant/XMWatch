import SwiftUI

struct XMSignInView: View {
    @Environment(XMRadioService.self) private var radioService

    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "radio")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)

                    Text("XMWatch")
                        .font(.title3)
                        .fontWeight(.bold)

                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $password)
                        .textContentType(.password)

                    Button {
                        Task { await signIn() }
                    } label: {
                        Label("Sign In", systemImage: "person.crop.circle")
                    }
                    .disabled(isSigningIn || username.isEmpty || password.isEmpty)

                    if isSigningIn {
                        ProgressView()
                    }

                    if let errorMessage = radioService.errorMessage {
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .navigationTitle("Sign In")
        }
    }

    private func signIn() async {
        isSigningIn = true
        _ = await radioService.signIn(username: username, password: password)
        isSigningIn = false
    }
}
