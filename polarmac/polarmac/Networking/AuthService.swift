import Foundation

struct AuthResponse: Decodable {
    let message: String
    let userID: String
    let username: String
    let iconURL: String?
    let bio: String?

    enum CodingKeys: String, CodingKey {
        case message
        case userID = "user_id"
        case username
        case iconURL = "icon_url"
        case bio
    }
}

private struct CurrentUserResponse: Decodable {
    let userID: String
    let username: String
    let iconURL: String?
    let bio: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case username
        case iconURL = "icon_url"
        case bio
    }
}

final class AuthService {
    private let apiClient = APIClient.shared

    func login(email: String, password: String, completion: @escaping (Result<AuthResponse, Error>) -> Void) {
        let payload: [String: String] = [
            "email": email,
            "password": password
        ]
        apiClient.requestDecodable(
            path: "/api/login",
            method: "POST",
            jsonBody: payload,
            errorDomain: "AuthService",
            completion: completion
        )
    }

    func register(username: String, email: String, password: String, completion: @escaping (Result<AuthResponse, Error>) -> Void) {
        let payload: [String: String] = [
            "username": username,
            "email": email,
            "password": password
        ]
        apiClient.requestDecodable(
            path: "/api/register",
            method: "POST",
            jsonBody: payload,
            errorDomain: "AuthService",
            completion: completion
        )
    }

    func fetchCurrentUser(completion: @escaping (Result<AuthResponse, Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/me",
            errorDomain: "AuthService"
        ) { (result: Result<CurrentUserResponse, Error>) in
            completion(result.map {
                AuthResponse(message: "ok", userID: $0.userID, username: $0.username, iconURL: $0.iconURL, bio: $0.bio)
            })
        }
    }

    func logout(completion: @escaping (Result<Void, Error>) -> Void) {
        struct Empty: Decodable {}
        apiClient.requestDecodable(
            path: "/api/logout",
            method: "POST",
            errorDomain: "AuthService"
        ) { (result: Result<Empty, Error>) in
            completion(result.map { _ in () })
        }
    }
}
