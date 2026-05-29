import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @State private var baseURL: String = AppEnvironment.apiBaseURLString()
    @StateObject private var teams = TeamPickerStore()
    @AppStorage(AppEnvironment.chatFontSizeUserDefaultsKey)
    private var chatFontSize: Double = Double(AppEnvironment.chatFontSizeDefault)

    var body: some View {
        TabView {
            Form {
                Section("接口地址") {
                    TextField("Base URL", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: baseURL) { newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            UserDefaults.standard.set(trimmed, forKey: AppEnvironment.baseURLUserDefaultsKey)
                        }
                    Text("改完后下次启动或重新登录生效。").font(.caption).foregroundStyle(.secondary)
                }

                Section("工作区") {
                    if teams.teams.isEmpty {
                        if let err = teams.error {
                            Text(err).font(.caption).foregroundStyle(.red)
                        } else {
                            HStack { ProgressView().controlSize(.small); Text("加载…").font(.caption) }
                        }
                    } else {
                        Picker("当前", selection: Binding(
                            get: { session.currentWorkspaceID ?? "" },
                            set: { newID in
                                session.currentWorkspaceID = newID.isEmpty ? nil : newID
                            }
                        )) {
                            Text("个人（默认）").tag("")
                            ForEach(teams.teams) { team in
                                Text("\(team.name) · \(team.myRole)").tag(team.id)
                            }
                        }
                        .pickerStyle(.menu)
                        Text("切换后会作为 X-Workspace-Id 发到服务端；下次拉群聊/私聊就会用这个 workspace。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("聊天") {
                    HStack {
                        Text("字号")
                        Slider(value: $chatFontSize,
                               in: Double(AppEnvironment.chatFontSizeMin)...Double(AppEnvironment.chatFontSizeMax),
                               step: 1)
                        Text("\(Int(chatFontSize))").monospacedDigit().frame(width: 28)
                        Button("默认") {
                            chatFontSize = Double(AppEnvironment.chatFontSizeDefault)
                        }
                    }
                    Text("快捷键：⌘+ 放大 / ⌘- 缩小 / ⌘0 重置。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("账号") {
                    if let u = session.currentUser {
                        LabeledContent("用户名", value: u.username)
                        LabeledContent("用户 ID", value: u.userID)
                    } else {
                        Text("未登录").foregroundStyle(.secondary)
                    }
                    Button("退出登录", role: .destructive, action: session.logout)
                        .disabled(session.currentUser == nil)
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("通用", systemImage: "gear") }
        }
        .frame(width: 480, height: 380)
        .onAppear { teams.refresh() }
    }
}

@MainActor
final class TeamPickerStore: ObservableObject {
    @Published var teams: [Team] = []
    @Published var error: String?

    private let service = TeamService()

    func refresh() {
        service.listTeams { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let list):
                    self?.teams = list
                    self?.error = nil
                case .failure(let err):
                    self?.error = err.localizedDescription
                }
            }
        }
    }
}
