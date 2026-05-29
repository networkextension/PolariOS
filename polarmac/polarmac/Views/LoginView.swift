import SwiftUI
import PolarKit

struct LoginView: View {
    @EnvironmentObject var session: SessionStore
    @State private var baseURL: String = AppEnvironment.apiBaseURLString()
    @State private var email: String = AppEnvironment.lastLoginEmail ?? ""
    @State private var password: String = {
        if let email = AppEnvironment.lastLoginEmail {
            return KeychainStore.loadPassword(account: email) ?? ""
        }
        return ""
    }()
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Polar")
                .font(.system(size: 36, weight: .bold))

            VStack(alignment: .leading, spacing: 8) {
                Text("接口地址").font(.caption).foregroundStyle(.secondary)
                TextField("http://host[:port]/", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: baseURL) { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        UserDefaults.standard.set(trimmed, forKey: AppEnvironment.baseURLUserDefaultsKey)
                    }

                Text("邮箱").font(.caption).foregroundStyle(.secondary)
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .onChange(of: email) { newValue in
                        // Pull the matching password from keychain when the
                        // user types / pastes a different email. Empty result
                        // means we don't have one — leave whatever they typed.
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let saved = KeychainStore.loadPassword(account: trimmed), !saved.isEmpty {
                            password = saved
                        }
                    }

                Text("密码").font(.caption).foregroundStyle(.secondary)
                SecureField("•••••••", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }

            if let err = session.lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                HStack {
                    if isSubmitting { ProgressView().controlSize(.small) }
                    Text(isSubmitting ? "正在登录…" : "登录")
                        .frame(maxWidth: .infinity)
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting || email.isEmpty || password.isEmpty)
        }
        .padding(40)
        .frame(width: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        guard !isSubmitting, !email.isEmpty, !password.isEmpty else { return }
        isSubmitting = true
        session.login(email: email, password: password) { _ in
            isSubmitting = false
        }
    }
}
