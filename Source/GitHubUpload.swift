import Foundation
import Security
import SwiftUI

struct GitHubUploadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SourceStore
    @AppStorage("githubUploadRepository") private var repository = ""
    @AppStorage("githubUploadBranch") private var branch = "main"
    @AppStorage("githubUploadPath") private var filePath = "Source.json"
    @State private var token = ""
    @State private var isUploading = false
    @State private var uploadProgress: Double?
    @State private var notice: UploadNotice?

    private enum Guide: String, CaseIterable, Identifiable {
        case publicRepository, privateRepository, common
        var id: Self { self }
        var title: String {
            switch self {
            case .publicRepository: "공개 저장소 사용 방법"
            case .privateRepository: "비공개 저장소 사용 방법"
            case .common: "앱에서 직접 업로드 — 공통"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Guide.allCases) { guide in
                                Button {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    withAnimation { proxy.scrollTo(guide, anchor: .top) }
                                } label: {
                                    Text(guide.title).font(.footnote).underline()
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)
                                .accessibilityAddTraits(.isLink)
                                .disabled(isUploading)
                            }
                        }
                    }
                    Section("업로드 위치") {
                        TextField("소유자/저장소", text: $repository)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("브랜치", text: $branch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("JSON 파일 경로", text: $filePath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("현재 JSON 미리보기 내용을 지정한 파일에 업로드합니다. 파일이 있으면 덮어쓰고 없으면 새로 만듭니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("GitHub 인증") {
                        SecureField("Fine-grained personal access token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("공개·비공개 저장소 모두 앱에서 직접 업로드하려면 Contents 읽기 및 쓰기 권한이 있는 토큰이 필요합니다. 토큰은 저장소별로 이 기기의 키체인에 저장됩니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section(Guide.publicRepository.title) {
                        Text("1. 토큰을 발급하지 않고 사용하려면 이 화면을 닫고 JSON 내보내기로 파일을 내보내세요.")
                        Text("2. GitHub 웹사이트에 로그인한 뒤 쓰기 권한이 있는 공개 저장소에서 Add file → Upload files로 JSON을 올리고 커밋하세요.")
                        Text("3. 파일의 Raw 주소를 SideStore에 등록하세요. 공개 파일을 읽을 때는 토큰이 필요하지 않습니다.")
                        Text("앱에서 직접 업로드하려면 공개 저장소도 아래와 같은 Fine-grained personal access token 설정이 필요합니다.")
                    }
                    .font(.footnote)
                    .id(Guide.publicRepository)
                    Section(Guide.privateRepository.title) {
                        Text("1. GitHub에서 Fine-grained personal access token을 만들고 Resource owner와 업로드할 비공개 저장소를 선택하세요.")
                        Text("2. Repository permissions → Contents를 Read and write로 설정한 뒤 토큰을 생성하세요.")
                        Text("3. 이 화면에 저장소·브랜치·JSON 파일 경로와 토큰을 입력하고 JSON 업로드하기를 누르세요.")
                        Text("비공개 파일은 공개 Raw 주소처럼 배포할 수 없습니다. SideStore가 접근할 수 있는 별도 배포 경로가 필요하며, 이 앱의 토큰은 SideStore에 전달되지 않습니다.")
                        Text("비공개 저장소도 GitHub 웹사이트에서 로그인 후 수동 업로드할 수 있습니다. 그 경우 별도 토큰 발급은 필요하지 않습니다.")
                        if let settingsURL = URL(string: "https://github.com/settings/personal-access-tokens/new") {
                            Link("GitHub에서 토큰 만들기", destination: settingsURL)
                        }
                    }
                    .font(.footnote)
                    .id(Guide.privateRepository)
                    Section(Guide.common.title) {
                        Text("1. 저장소를 소유자/저장소 형식으로 입력하고 브랜치와 JSON 파일 경로를 지정하세요. GitHub 저장소 URL도 붙여넣을 수 있습니다.")
                        Text("2. 업로드 대상 저장소의 Contents 읽기 및 쓰기 권한이 있는 토큰을 입력하고 JSON 업로드하기를 누르세요.")
                        Text("3. 완료 메시지의 GitHub에서 보기로 결과를 확인하세요. 다른 저장소로 바꾸면 해당 저장소에 저장된 토큰을 불러옵니다.")
                    }
                    .font(.footnote)
                    .id(Guide.common)
                }
            }
            .navigationTitle("GitHub에 업로드")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }.disabled(isUploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isUploading ? "업로드 중…" : "JSON 업로드하기") { upload() }
                        .font(.subheadline.weight(.semibold))
                        .disabled(isUploading || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .task { loadToken(for: repository) }
        .onChange(of: repository) { _, newValue in loadToken(for: newValue) }
        .keyboardDismissButton()
        .overlay {
            if let uploadProgress {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        Text("JSON 업로드 중…").font(.headline)
                        JSONTransferProgressIndicator(progress: uploadProgress, accessibilityTitle: "JSON 업로드 진행률")
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .zIndex(1)
            }
        }
        .alert(notice?.title ?? "알림", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            if let url = notice?.url {
                Button("GitHub에서 보기") { UIApplication.shared.open(url) }
            }
            Button("확인", role: .cancel) { notice = nil }
        } message: {
            Text(notice?.message ?? "")
        }
    }

    private func loadToken(for repository: String) {
        guard let identifier = GitHubUploadTarget.repositoryIdentifier(from: repository) else {
            token = ""
            return
        }
        token = GitHubUploadToken.load(repository: identifier) ?? ""
    }

    private func upload() {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        notice = nil
        let target: GitHubUploadTarget
        let json: Data
        do {
            target = try GitHubUploadTarget(repository: repository, branch: branch, path: filePath)
        } catch {
            notice = UploadNotice(title: "업로드 실패", message: error.localizedDescription)
            return
        }
        do {
            json = try store.jsonDataForUpload()
        } catch {
            notice = UploadNotice(title: "업로드 실패", message: "JSON을 만들지 못했습니다: \(error.localizedDescription)")
            return
        }
        let started = Date()
        isUploading = true
        uploadProgress = 0
        Task {
            do {
                try GitHubUploadToken.save(trimmedToken, repository: target.repositoryIdentifier)
                let url = try await GitHubJSONUploader.upload(json, token: trimmedToken, target: target) { fraction in
                    DispatchQueue.main.async {
                        guard isUploading, let current = uploadProgress else { return }
                        withAnimation(.linear(duration: 0.2)) {
                            uploadProgress = max(current, min(0.95, fraction))
                        }
                    }
                }
                withAnimation(.linear(duration: 0.3)) { uploadProgress = 1 }
                let remaining = max(0, 0.8 - Date().timeIntervalSince(started))
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                uploadProgress = nil
                notice = UploadNotice(title: "JSON 업로드 완료", message: "\(target.path) 파일을 업로드했습니다.", url: url)
            } catch {
                uploadProgress = nil
                notice = UploadNotice(title: "업로드 실패", message: error.localizedDescription)
            }
            isUploading = false
        }
    }
}

private struct UploadNotice {
    let title: String
    let message: String
    var url: URL? = nil
}

private struct GitHubUploadTarget {
    let owner: String
    let repository: String
    let branch: String
    let path: String

    var repositoryIdentifier: String { "\(owner)/\(repository)" }

    init(repository: String, branch: String, path: String) throws {
        guard let identifier = Self.repositoryIdentifier(from: repository) else {
            throw UploadFailure.invalidRepository
        }
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false)
        owner = String(parts[0])
        self.repository = String(parts[1])
        self.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.branch.isEmpty else { throw UploadFailure.invalidBranch }
        let pathParts = self.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !pathParts.isEmpty,
              pathParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              self.path.lowercased().hasSuffix(".json") else { throw UploadFailure.invalidPath }
    }

    static func repositoryIdentifier(from value: String) -> String? {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("https://github.com/") {
            name = String(name.dropFirst("https://github.com/".count))
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if name.lowercased().hasSuffix(".git") { name = String(name.dropLast(4)) }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
              parts[1].range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    var apiURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        let encodedPath = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "/")
        components.percentEncodedPath = "/repos/\(owner)/\(repository)/contents/\(encodedPath)"
        return components.url!
    }
}

private enum GitHubUploadToken {
    private static let service = "app.sourceeditor.github-upload"

    private static func query(repository: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: repository]
    }

    static func load(repository: String) -> String? {
        var lookup = query(repository: repository)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, repository: String) throws {
        guard let data = token.data(using: .utf8) else { throw UploadFailure.invalidToken }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var item = query(repository: repository)
        item.merge(attributes) { _, new in new }
        let status = SecItemAdd(item as CFDictionary, nil)
        let finalStatus = status == errSecDuplicateItem
            ? SecItemUpdate(query(repository: repository) as CFDictionary, attributes as CFDictionary)
            : status
        guard finalStatus == errSecSuccess else { throw UploadFailure.keychain }
    }
}

private final class GitHubUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

private enum GitHubJSONUploader {
    private struct ExistingFile: Decodable { let sha: String }
    private struct UpdatedFile: Decodable {
        let content: Content
        struct Content: Decodable { let html_url: URL }
    }
    private struct UpdateRequest: Encodable {
        let message: String
        let content: String
        let sha: String?
        let branch: String
    }

    static func upload(_ data: Data, token: String, target: GitHubUploadTarget,
                       progress: @escaping (Double) -> Void) async throws -> URL {
        var components = URLComponents(url: target.apiURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ref", value: target.branch)]
        var lookup = request(url: components.url!, token: token)
        lookup.httpMethod = "GET"
        let (fileData, lookupResponse) = try await URLSession.shared.data(for: lookup)
        let existingSHA: String?
        if (lookupResponse as? HTTPURLResponse)?.statusCode == 404 {
            existingSHA = nil
        } else {
            try check(lookupResponse, success: [200])
            existingSHA = try JSONDecoder().decode(ExistingFile.self, from: fileData).sha
        }
        progress(0.05)

        var update = request(url: target.apiURL, token: token)
        update.httpMethod = "PUT"
        let body = try JSONEncoder().encode(UpdateRequest(
            message: "Update \(target.path) from Source Editor",
            content: data.base64EncodedString(),
            sha: existingSHA,
            branch: target.branch
        ))
        update.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let delegate = GitHubUploadProgressDelegate { fraction in
            progress(0.05 + 0.90 * min(1, max(0, fraction)))
        }
        let (responseData, updateResponse) = try await URLSession.shared.upload(for: update, from: body, delegate: delegate)
        try check(updateResponse, success: [200, 201])
        return try JSONDecoder().decode(UpdatedFile.self, from: responseData).content.html_url
    }

    private static func request(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private static func check(_ response: URLResponse, success: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else { throw UploadFailure.invalidResponse }
        if success.contains(http.statusCode) { return }
        switch http.statusCode {
        case 401: throw UploadFailure.unauthorized
        case 403: throw UploadFailure.forbidden
        case 404: throw UploadFailure.notFound
        case 409: throw UploadFailure.conflict
        default: throw UploadFailure.http(http.statusCode)
        }
    }
}

private enum UploadFailure: LocalizedError {
    case invalidRepository, invalidBranch, invalidPath, invalidToken, keychain
    case invalidResponse, unauthorized, forbidden, notFound, conflict, http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRepository: "저장소를 소유자/저장소 형식으로 입력하세요."
        case .invalidBranch: "브랜치를 입력하세요."
        case .invalidPath: "JSON 파일 경로를 입력하세요. 경로는 .json으로 끝나야 합니다."
        case .invalidToken: "토큰을 입력하세요."
        case .keychain: "토큰을 기기 키체인에 저장하지 못했습니다."
        case .invalidResponse: "GitHub 응답을 확인하지 못했습니다."
        case .unauthorized: "GitHub 토큰이 올바르지 않거나 만료되었습니다."
        case .forbidden: "토큰에 선택한 저장소의 Contents 쓰기 권한이 없습니다."
        case .notFound: "저장소 또는 브랜치를 찾지 못했습니다. 토큰의 저장소 접근 권한도 확인하세요."
        case .conflict: "다른 변경과 충돌했습니다. 다시 업로드해 주세요."
        case .http(let code): "GitHub 서버 오류 (HTTP \(code))."
        }
    }
}
