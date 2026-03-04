import SwiftUI

struct AuthView: View {
    @StateObject private var fm = FirebaseManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = true
    @State private var info: String?

    var body: some View {
        Form {
            Picker("Mode", selection: $isSignUp) {
                Text("Sign Up").tag(true)
                Text("Log In").tag(false)
            }
            .pickerStyle(.segmented)

            TextField("Email", text: $email)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)

            SecureField("Password", text: $password)

            Button(isSignUp ? "Create Account" : "Log In") {
                Task {
                    do {
                        if isSignUp {
                            try await fm.signUpOrLink(email: email, password: password)
                        } else {
                            try await fm.signIn(email: email, password: password)
                        }
                        dismiss()
                    } catch {
                        info = error.localizedDescription
                    }
                }
            }
        }
        .navigationTitle("Account")
        .alert("Error", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
            Button("OK", role: .cancel) { info = nil }
        } message: {
            Text(info ?? "")
        }
    }
}

