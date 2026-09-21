import Foundation

/// Uploads a clip to HALP/CDN and hands back the permalink.
///
/// The CDN takes three steps: ask for a presigned URL, PUT the bytes to storage, then
/// confirm so the file shows up in the browser. The key comes from the keychain, so an
/// upload is only attempted when one is saved.
enum CDNUploader {
    static let baseURL = URL(string: "https://cdn.haelp.dev")!

    /// Where clips land on the CDN. The API wants this without a leading slash.
    static let remoteFolder = "clips"

    enum UploadError: LocalizedError {
        case missingKey
        case rejected(Int, String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Add your HALP/CDN key in settings before uploading."
            case .rejected(let code, let message):
                if code == 401 || code == 403 {
                    return "The CDN turned down the key: \(message)"
                }
                return "The CDN returned \(code): \(message)"
            case .malformedResponse:
                return "The CDN sent back something unexpected."
            }
        }
    }

    private struct UploadTicket: Decodable {
        let uploadUrl: String
        let fileKey: String
    }

    /// Sends the file up and returns the public link to it.
    static func upload(fileURL: URL) async throws -> URL {
        guard let key = KeychainStore.apiKey else { throw UploadError.missingKey }

        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent

        let ticket = try await requestTicket(
            key: key,
            filename: filename,
            byteCount: data.count
        )
        try await putBytes(data, to: ticket.uploadUrl)
        try await confirm(fileKey: ticket.fileKey, key: key)

        // The file key comes back without a leading slash, which is what /obj expects.
        let permalink = baseURL
            .appendingPathComponent("obj")
            .appendingPathComponent(ticket.fileKey)
        Log.info("Uploaded \(filename)")
        return permalink
    }

    private static func requestTicket(
        key: String,
        filename: String,
        byteCount: Int
    ) async throws -> UploadTicket {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/upload"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": remoteFolder,
            "filename": filename,
            "fileType": "video/mp4",
            "size": byteCount
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        guard let ticket = try? JSONDecoder().decode(UploadTicket.self, from: data) else {
            throw UploadError.malformedResponse
        }
        return ticket
    }

    private static func putBytes(_ data: Data, to urlString: String) async throws {
        guard let url = URL(string: urlString) else { throw UploadError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        try check(response, data: body)
    }

    private static func confirm(fileKey: String, key: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/upload/confirm"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fileKey": fileKey])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw UploadError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = errorMessage(from: data)
            throw UploadError.rejected(http.statusCode, message)
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? String { return error }
            if let message = object["message"] as? String { return message }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "no detail given" : String(text.prefix(200))
    }

    /// Checks a key by asking the CDN to list the clips folder.
    static func verify(key: String) async -> Result<Void, Error> {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/list"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "path", value: remoteFolder),
            URLQueryItem(name: "limit", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try check(response, data: data)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
