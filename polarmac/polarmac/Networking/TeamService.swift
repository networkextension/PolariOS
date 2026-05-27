import Foundation

/// Teams = workspaces. Each user has at least one personal team auto-created
/// on first login. `/api/teams` returns the list; the chosen team id is sent
/// back on every subsequent request as the `X-Workspace-Id` header. See
/// doc/qunliao/api-ios.md §1.

struct Team: Decodable, Identifiable, Hashable {
    let id: String
    let slug: String
    let name: String
    let description: String
    let avatarURL: String
    let kind: String
    let ownerUserID: String
    let myRole: String

    enum CodingKeys: String, CodingKey {
        case id
        case slug
        case name
        case description
        case avatarURL = "avatar_url"
        case kind
        case ownerUserID = "owner_user_id"
        case myRole = "my_role"
    }
}

private struct TeamListResponse: Decodable { let teams: [Team] }

final class TeamService {
    private let apiClient = APIClient.shared

    func listTeams(completion: @escaping (Result<[Team], Error>) -> Void) {
        apiClient.requestDecodable(
            path: "/api/teams",
            errorDomain: "TeamService"
        ) { (result: Result<TeamListResponse, Error>) in
            completion(result.map { $0.teams })
        }
    }
}
