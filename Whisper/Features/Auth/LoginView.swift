import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var username = ""
    @State private var password = ""
    @State private var loading = false
    @State private var error: String?
    @FocusState private var focused: Field?

    enum Field { case username, password }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.accentColor.opacity(0.35), Color(uiColor: .systemBackground), Color(uiColor: .systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.accentColor.gradient)
                        .symbolEffect(.bounce, value: loading)
                    Text("悄悄话")
                        .font(.largeTitle.bold())
                    Text("只属于我们两个人的地方")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    TextField("账号", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                        .padding(16)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(login)
                        .padding(16)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .transition(.opacity)
                }

                Button(action: login) {
                    ZStack {
                        if loading {
                            ProgressView().tint(.white)
                        } else {
                            Text("进入").font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(username.isEmpty || password.isEmpty || loading)

                Spacer()
                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 460)
        }
        .onAppear { focused = .username }
    }

    private func login() {
        guard !username.isEmpty, !password.isEmpty, !loading else { return }
        loading = true
        error = nil
        Task {
            do {
                try await app.login(username: username.trimmingCharacters(in: .whitespaces), password: password)
            } catch APIError.unauthorized {
                withAnimation { error = "账号或密码不对" }
                Haptics.warning()
            } catch {
                withAnimation { self.error = error.localizedDescription }
                Haptics.warning()
            }
            loading = false
        }
    }
}
