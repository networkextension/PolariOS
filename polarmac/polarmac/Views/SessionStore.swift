import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published var currentUser: AuthResponse?
    @Published var bootstrapState: BootstrapState = .checking
    @Published var lastError: String?
    /// Mirrors AppEnvironment.currentWorkspaceID so SwiftUI views can observe
    /// the change reactively. Writing here also writes UserDefaults.
    @Published var currentWorkspaceID: String? = AppEnvironment.currentWorkspaceID {
        didSet {
            AppEnvironment.currentWorkspaceID = currentWorkspaceID
        }
    }

    enum BootstrapState: Equatable {
        case checking
        case loggedOut
        case loggedIn
    }

    private let authService = AuthService()

    init() {
        bootstrap()
    }

    func bootstrap() {
        bootstrapState = .checking
        authService.fetchCurrentUser { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let user):
                    self.currentUser = user
                    self.bootstrapState = .loggedIn
                case .failure:
                    self.currentUser = nil
                    self.bootstrapState = .loggedOut
                }
            }
        }
    }

    func login(email: String, password: String, completion: @escaping (Bool) -> Void) {
        authService.login(email: email, password: password) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let user):
                    self.currentUser = user
                    self.bootstrapState = .loggedIn
                    self.lastError = nil
                    // Persist only after the server says these creds are good.
                    AppEnvironment.lastLoginEmail = email
                    KeychainStore.save(password: password, account: email)
                    completion(true)
                case .failure(let err):
                    self.lastError = err.localizedDescription
                    completion(false)
                }
            }
        }
    }

    func logout() {
        authService.logout { _ in }
        currentUser = nil
        bootstrapState = .loggedOut
        currentWorkspaceID = nil
        // Forget the saved password on explicit sign-out (email stays
        // pre-filled so re-login is quick).
        if let email = AppEnvironment.lastLoginEmail {
            KeychainStore.delete(account: email)
        }
        // Drop session cookies so the next login is clean.
        if let cookies = HTTPCookieStorage.shared.cookies {
            cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
    }
}
