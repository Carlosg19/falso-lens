import Foundation

struct AnalyzerRequest: Codable, Equatable {
    let text: String
    let capturedAt: Date
    let sourceApplication: String?
}

struct AnalyzerResult: Codable, Equatable {
    let summary: String
    let manipulationScore: Double
    let evidence: [String]
}

enum AnalyzerServiceError: Error {
    case invalidResponse
}

@MainActor
final class AnalyzerService {
    private let endpoint: URL
    private let session: URLSession

    init(
        endpoint: URL? = nil,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint ?? AnalyzerDependencies.defaultLocalhostEndpoint
        self.session = session
    }

    func analyze(text: String, sourceApplication: String? = nil) async throws -> AnalyzerResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AnalyzerRequest(
                text: text,
                capturedAt: Date(),
                sourceApplication: sourceApplication
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AnalyzerServiceError.invalidResponse
        }

        return try JSONDecoder().decode(AnalyzerResult.self, from: data)
    }
}
