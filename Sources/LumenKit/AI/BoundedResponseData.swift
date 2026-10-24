import Foundation

enum BoundedResponseData {
    static let modelListLimit = 2 * 1024 * 1024
    static let literatureLimit = 4 * 1024 * 1024
    static func read(_ bytes: URLSession.AsyncBytes, response: URLResponse, maximum: Int) async throws -> Data {
        guard response.expectedContentLength <= maximum else { throw AIError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximum else { throw AIError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}

/// Redirects must not forward document bodies or authorization to another origin.
final class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static func permits(from source: URL?, to destination: URL?) -> Bool {
        guard let source, let destination,
              source.scheme?.lowercased() == destination.scheme?.lowercased(),
              source.host?.lowercased() == destination.host?.lowercased(),
              destination.user == nil, destination.password == nil else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return port(source) == port(destination)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.permits(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }
}
