import Foundation
import Security
import SwiftUI

struct GitHubUploadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SourceStore
    @State private var token = ""
    @State private var isUploading = false
    @State private var resultMessage: String?
    @State private var uploadedURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("업로드 위치") {
                    Text("kes158/NightFox_Repository")
                    Text("main / NightFox.json")
                    Text("현재 JSON 미리보기에 표시된 내용을 기존 파일에 덮어씁니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("GitHub 인증") {
                    SecureField("Fine-grained personal access token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("NightFox_Repository만 선택하고 Contents 권한을 Read and write로 설정한 토큰을 입력하세요. 토큰은 이 기기의 키체인에 저장됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let settingsURL = URL(string: "https://github.com/settings/personal-access-tokens/new") {
                        Link("GitHub에서 토큰 만들기", destination: settingsURL)
                    }
                }
                Section {
                    Button {
                        upload()
                    } label: {
                        HStack {
                            Spacer()
                            if isUploading { ProgressView().padding(.trailing, 8) }
                            Text(isUploading ? "업로드 중…" : "NightFox.json 덮어쓰기")
                            Spacer()
                        }
                    }
                    .disabled(isUploading || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let resultMessage {
                    Section {
                        Text(resultMessage)
                        if let uploadedURL {
                            Link("GitHub에서 파일 보기", destination: uploadedURL)
                        }
                    }
                }
            }
            .navigationTitle("GitHub에 업로드")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("닫기") { dismiss() }.disabled(isUploading) }
        }
        .task { token = GitHubUploadToken.load() ?? "" }
        .keyboardDismissButton()
    }

    private func upload() {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        resultMessage = nil
        uploadedURL = nil
        let json: Data
        do {
            json = try store.jsonDataForUpload()
        } catch {
            resultMessage = "JSON을 만들지 못했습니다: \(error.localizedDescription)"
            return
        }
        isUploading = true
        Task {
            do {
                try GitHubUploadToken.save(trimmedToken)
                uploadedURL = try await GitHubJSONUploader.upload(json, token: trimmedToken)
                resultMessage = "NightFox.json 업로드를 완료했습니다."
            } catch {
                resultMessage = "업로드하지 못했습니다: \(error.localizedDescription)"
            }
            isUploading = false
        }
    }
}

private enum GitHubUploadToken {
    private static let service = "app.altstudio.sourcecreator.github-upload"
    private static let account = "kes158/NightFox_Repository"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw UploadFailure.invalidToken }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var item = query
        item.merge(attributes) { _, new in new }
        let status = SecItemAdd(item as CFDictionary, nil)
        let finalStatus = status == errSecDuplicateItem
            ? SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            : status
        guard finalStatus == errSecSuccess else { throw UploadFailure.keychain }
    }
}

private enum GitHubJSONUploader {
    private static let owner = "kes158"
    private static let repository = "NightFox_Repository"
    private static let branch = "main"
    private static let file = "NightFox.json"
    private static let endpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/contents/\(file)")!
    private static let fileURL = URL(string: "https://github.com/\(owner)/\(repository)/blob/\(branch)/\(file)")!

    private struct ExistingFile: Decodable { let sha: String }
    private struct UpdateRequest: Encodable {
        let message: String
        let content: String
        let sha: String
        let branch: String
    }

    static func upload(_ data: Data, token: String) async throws -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        var lookup = request(url: components.url!, token: token)
        lookup.httpMethod = "GET"
        let (fileData, lookupResponse) = try await URLSession.shared.data(for: lookup)
        try check(lookupResponse)
        let existing = try JSONDecoder().decode(ExistingFile.self, from: fileData)

        var update = request(url: endpoint, token: token)
        update.httpMethod = "PUT"
        update.httpBody = try JSONEncoder().encode(UpdateRequest(
            message: "Update NightFox.json from AltSource Studio",
            content: data.base64EncodedString(),
            sha: existing.sha,
            branch: branch
        ))
        update.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, updateResponse) = try await URLSession.shared.data(for: update)
        try check(updateResponse)
        return fileURL
    }

    private static func request(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw UploadFailure.invalidResponse }
        switch http.statusCode {
        case 200: return
        case 401: throw UploadFailure.unauthorized
        case 403: throw UploadFailure.forbidden
        case 404: throw UploadFailure.notFound
        case 409: throw UploadFailure.conflict
        default: throw UploadFailure.http(http.statusCode)
        }
    }
}

private enum UploadFailure: LocalizedError {
    case invalidToken, keychain, invalidResponse, unauthorized, forbidden, notFound, conflict, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidToken: "토큰을 입력하세요."
        case .keychain: "토큰을 기기 키체인에 저장하지 못했습니다."
        case .invalidResponse: "GitHub 응답을 확인하지 못했습니다."
        case .unauthorized: "GitHub 토큰이 올바르지 않거나 만료되었습니다."
        case .forbidden: "토큰에 NightFox_Repository의 Contents 쓰기 권한이 없습니다."
        case .notFound: "저장소 또는 main/NightFox.json을 찾지 못했습니다. 토큰의 저장소 접근 권한도 확인하세요."
        case .conflict: "다른 변경과 충돌했습니다. 다시 업로드해 주세요."
        case .http(let code): "GitHub 서버 오류 (HTTP \(code))."
        }
    }
}
