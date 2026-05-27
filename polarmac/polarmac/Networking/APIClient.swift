import Foundation

final class APIClient {
    static let shared = APIClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        // Defaults are 60s / 7d which means a wrong base URL hangs the
        // "正在登录…" spinner for a full minute before bailing. 12s per
        // request + 30s total budget covers realistic slow links and
        // surfaces typos fast.
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    func requestDecodable<T: Decodable>(
        path: String,
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        rawBody: Data? = nil,
        contentType: String? = nil,
        errorDomain: String,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        guard let request = makeRequest(path: path, method: method, jsonBody: jsonBody, rawBody: rawBody, contentType: contentType, errorDomain: errorDomain, onError: { completion(.failure($0)) }) else {
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(Self.error(domain: errorDomain, code: -2, message: "无响应")))
                return
            }

            let responseData = data ?? Data()
            let decoder = JSONDecoder()

            if (200...299).contains(httpResponse.statusCode) {
                do {
                    let value = try decoder.decode(T.self, from: responseData)
                    completion(.success(value))
                } catch {
                    completion(.failure(Self.error(domain: errorDomain, code: -3, message: "返回数据格式不正确: \(error.localizedDescription)")))
                }
                return
            }

            if let apiError = Self.apiErrorMessage(from: responseData) {
                completion(.failure(Self.error(domain: errorDomain, code: httpResponse.statusCode, message: apiError)))
                return
            }

            let rawText = String(data: responseData, encoding: .utf8) ?? "请求失败"
            completion(.failure(Self.error(domain: errorDomain, code: httpResponse.statusCode, message: rawText)))
        }.resume()
    }

    private func makeRequest(
        path: String,
        method: String,
        jsonBody: [String: Any]?,
        rawBody: Data?,
        contentType: String?,
        errorDomain: String,
        onError: @escaping (Error) -> Void
    ) -> URLRequest? {
        guard let baseURL = AppEnvironment.apiBaseURL(),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            onError(Self.error(domain: errorDomain, code: -1, message: "无效接口地址"))
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        if let jsonBody {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } catch {
                onError(error)
                return nil
            }
        } else if let rawBody {
            request.httpBody = rawBody
        }

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if let workspaceID = AppEnvironment.currentWorkspaceID {
            request.setValue(workspaceID, forHTTPHeaderField: "X-Workspace-Id")
        }

        return request
    }

    private static func error(domain: String, code: Int, message: String) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func apiErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["error"] as? String
    }
}
