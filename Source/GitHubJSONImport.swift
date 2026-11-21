import Foundation
import SwiftUI

enum JSONImportDestination: String, Identifiable {
    case file, publicRepository, privateRepository
    var id: String { rawValue }
}

struct ImportedSourceDocument {
    let data: Data
    let source: Source
}

/// Accepts GitHub file links and Raw links. Tokens are sent only to api.github.com.
struct GitHubJSONImportTarget {
    let rawURL: URL
    let apiURL: URL

    init(address: String, branchOverride: String = "") throws {
        guard let input = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              input.scheme?.lowercased() == "https", input.user == nil, input.password == nil,
              input.port == nil || input.port == 443,
              let host = input.host?.lowercased() else { throw GitHubImportError.invalidAddress }
        let parts = input.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst().map { String($0).removingPercentEncoding ?? "" }
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GitHubImportError.invalidAddress
        }
        let override = branchOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner: String
        let repository: String
        let branch: String
        let path: [String]
        if host == "api.github.com" {
            guard parts.count >= 5, parts[0] == "repos", parts[3] == "contents" else {
                throw GitHubImportError.invalidAddress
            }
            owner = parts[1]; repository = parts[2]
            branch = override.isEmpty ? (input.queryItems?.first { $0.name == "ref" }?.value ?? "HEAD") : override
            path = Array(parts.dropFirst(4))
        } else {
            guard parts.count >= 4 else { throw GitHubImportError.invalidAddress }
            owner = parts[0]; repository = parts[1]
            var remainder: [String]
            if host == "github.com" || host == "www.github.com" {
                guard parts[2] == "blob" || parts[2] == "raw" else { throw GitHubImportError.invalidAddress }
                remainder = Array(parts.dropFirst(3))
            } else if host == "raw.githubusercontent.com" {
                remainder = Array(parts.dropFirst(2))
            } else { throw GitHubImportError.invalidAddress }
            if remainder.starts(with: ["refs", "heads"]) { remainder.removeFirst(2) }
            guard remainder.count >= 2 else { throw GitHubImportError.invalidAddress }
            if override.isEmpty {
                branch = remainder.removeFirst()
            } else {
                let branchParts = override.split(separator: "/").map(String.init)
                if remainder.first == override { remainder.removeFirst() }
                else if !branchParts.isEmpty, remainder.starts(with: branchParts) { remainder.removeFirst(branchParts.count) }
                else { throw GitHubImportError.branchMismatch }
                branch = override
            }
            path = remainder
        }
        guard owner.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
              repository.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              !branch.isEmpty, !path.isEmpty,
              path.allSatisfy({ !$0.contains("/") && !$0.contains("\\") }),
              path.last?.lowercased().hasSuffix(".json") == true else { throw GitHubImportError.invalidAddress }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed)! }
        let filePath = path.map(encoded).joined(separator: "/")
        var api = URLComponents()
        api.scheme = "https"; api.host = "api.github.com"
        api.percentEncodedPath = "/repos/\(encoded(owner))/\(encoded(repository))/contents/\(filePath)"
        api.queryItems = [URLQueryItem(name: "ref", value: branch)]
        var raw = URLComponents()
        raw.scheme = "https"; raw.host = "raw.githubusercontent.com"
        raw.percentEncodedPath = "/\(encoded(owner))/\(encoded(repository))/\(encoded(branch))/\(filePath)"
        guard let apiURL = api.url, let rawURL = raw.url else { throw GitHubImportError.invalidAddress }
        self.apiURL = apiURL; self.rawURL = rawURL
    }
}

enum GitHubJSONImporter {
    private static let maximumBytes = 32 * 1024 * 1024

    static func load(target: GitHubJSONImportTarget, token: String?,
                     progress: @escaping (Double?) -> Void) async throws -> ImportedSourceDocument {
        let isPrivate = token != nil
        let url = isPrivate ? target.apiURL : target.rawURL
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Source-Editor", forHTTPHeaderField: "User-Agent")
        request.setValue(isPrivate ? "application/vnd.github.raw+json" : "application/json", forHTTPHeaderField: "Accept")
        if let token {
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  value.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw GitHubImportError.invalidToken
            }
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: GitHubImportRedirectPolicy(host: url.host!), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubImportError.invalidResponse }
        guard http.statusCode == 200 else { throw GitHubImportError.http(http.statusCode) }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw GitHubImportError.tooLarge }
        var data = Data()
        data.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 256 * 1024)
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw GitHubImportError.tooLarge }
            data.append(byte)
            if data.count.isMultiple(of: 64 * 1024) {
                try Task.checkCancellation()
                progress(response.expectedContentLength > 0 ? min(0.95, Double(data.count) / Double(response.expectedContentLength) * 0.95) : nil)
            }
        }
        try Task.checkCancellation()
        progress(0.95)
        let source: Source
        do { source = try SourceStore.decodeJSON(data) }
        catch { throw GitHubImportError.invalidJSON }
        progress(1)
        return ImportedSourceDocument(data: data, source: source)
    }
}

private final class GitHubImportRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let host: String
    init(host: String) { self.host = host }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.port == nil || request.url?.port == 443,
              request.url?.user == nil, request.url?.password == nil else {
            completionHandler(nil)
            return
        }
        if request.url?.host?.lowercased() == host {
            completionHandler(request)
        } else if host == "api.github.com", request.url?.host?.lowercased() == "raw.githubusercontent.com" {
            // GitHub may redirect to a short-lived Raw download link. Never forward the PAT.
            var download = request
            download.setValue(nil, forHTTPHeaderField: "Authorization")
            download.setValue(nil, forHTTPHeaderField: "X-GitHub-Api-Version")
            completionHandler(download)
        } else { completionHandler(nil) }
    }
}

private enum GitHubImportError: LocalizedError {
    case invalidAddress, branchMismatch, invalidToken, invalidResponse, tooLarge, invalidJSON, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "GitHub의 JSON 파일 주소 또는 Raw 주소를 입력하세요. 파일 경로는 .json으로 끝나야 합니다."
        case .branchMismatch: "주소의 브랜치와 직접 지정한 브랜치가 일치하지 않습니다."
        case .invalidToken: "공백 없이 올바른 GitHub 토큰을 입력하세요."
        case .invalidResponse: "GitHub 응답을 확인하지 못했습니다."
        case .tooLarge: "JSON 파일은 최대 32MB까지 불러올 수 있습니다."
        case .invalidJSON: "올바른 소스 JSON이 아닙니다. name과 apps 항목이 있는 JSON 파일인지 확인하세요."
        case .http(401): "토큰이 올바르지 않거나 만료되었습니다."
        case .http(403): "저장소 읽기 권한, 조직 승인 또는 GitHub 요청 제한을 확인하세요."
        case .http(404): "JSON 파일을 찾지 못했습니다. 주소·브랜치·파일 경로와 저장소 접근 권한을 확인하세요."
        case .http(429): "GitHub 요청 한도를 초과했습니다. 잠시 후 다시 시도하세요."
        case .http(let status): "JSON을 불러오지 못했습니다 (HTTP \(status))."
        }
    }
}

struct GitHubJSONImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isPrivate: Bool
    let onImport: (ImportedSourceDocument) -> Void
    @State private var address = ""
    @State private var branch = ""
    @State private var token = ""
    @State private var loading = false
    @State private var progress: Double?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var showingTokenGuide = false

    var body: some View {
        NavigationStack {
            Form {
                Section("JSON 파일 주소") {
                    TextField("https://raw.githubusercontent.com/소유자/저장소/main/Source.json", text: $address, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(loading)
                    Text("JSON의 Raw 주소 또는 GitHub 파일 보기 주소를 입력하세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("브랜치 직접 지정 (선택 사항)") {
                        TextField("예: feature/source", text: $branch)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(loading)
                        Text("보통 비워 둡니다. 브랜치 이름에 /가 있으면 전체 이름을 입력하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if isPrivate {
                    Section("GitHub 토큰") {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField("Fine-grained personal access token", text: $token)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(loading)
                            Button("토큰 만드는 방법") { showingTokenGuide = true }
                                .font(.caption).foregroundStyle(.blue).buttonStyle(.plain).disabled(loading)
                        }
                        Text("대상 저장소의 Contents 읽기 권한이 필요합니다. 입력한 토큰은 저장하지 않습니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("JSON 불러오기", action: beginImport)
                        .disabled(loading || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (isPrivate && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    Text("불러오기가 완료되면 현재 작업을 대체합니다. 필요한 작업은 먼저 JSON으로 저장하세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if loading {
                        if let progress { JSONTransferProgressIndicator(progress: progress, accessibilityTitle: "JSON 불러오기 진행률") }
                        else { ProgressView("JSON 불러오는 중…") }
                    }
                }
            }
            .navigationTitle(isPrivate ? "비공개 저장소에서 불러오기" : "공개 저장소에서 불러오기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("취소") { task?.cancel(); loading = false; dismiss() }
            }
            .keyboardDismissButton()
            .sheet(isPresented: $showingTokenGuide) { GitHubImportTokenGuide() }
            .alert("JSON을 불러오지 못했습니다", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(loading)
        .onDisappear { task?.cancel() }
    }

    private func beginImport() {
        let target: GitHubJSONImportTarget
        do { target = try GitHubJSONImportTarget(address: address, branchOverride: branch) }
        catch { errorMessage = error.localizedDescription; return }
        loading = true; progress = nil; errorMessage = nil
        let credential = isPrivate ? token : nil
        task = Task { @MainActor in
            do {
                let document = try await GitHubJSONImporter.load(target: target, token: credential) { fraction in
                    DispatchQueue.main.async { if loading { progress = fraction } }
                }
                try Task.checkCancellation()
                loading = false
                onImport(document)
            } catch {
                if !Task.isCancelled { loading = false; errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct GitHubImportTokenGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("비공개 JSON 불러오기용 토큰") {
                    Text("1. 아래 링크에서 GitHub의 Fine-grained personal access token 생성 화면을 엽니다.")
                    Text("2. Resource owner를 확인하고 Repository access에서 불러올 비공개 저장소를 선택합니다.")
                    Text("3. Repository permissions → Contents를 Read-only로 설정합니다.")
                    Text("4. Generate token으로 생성한 값을 복사해 이전 화면의 토큰 입력란에 붙여 넣습니다.")
                    Text("조직 저장소는 관리자 승인이 추가로 필요할 수 있습니다. 토큰을 JSON이나 공유 주소에 넣지 마세요.")
                }
                Section {
                    Link("GitHub에서 토큰 만들기", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    Link("GitHub 공식 토큰 가이드", destination: URL(string: "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens")!)
                }
            }
            .navigationTitle("토큰 만드는 방법")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("닫기") { dismiss() } }
        }
    }
}
