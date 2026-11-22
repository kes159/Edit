import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private func linkedApp(for news: SourceNews, in apps: [SourceApp]) -> SourceApp? {
    let appID = news.appID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !appID.isEmpty else { return nil }
    return apps.first { $0.bundleIdentifier == appID }
}

struct NewsScreen: View {
    @EnvironmentObject private var store: SourceStore
    let viewCodeAction: () -> Void
    @State private var search = ""
    @State private var editing = false
    @State private var newsToDeleteIndex: Int?
    @State private var showingDeleteAlert = false
    @State private var newEditorIndex: Int?
    @State private var showingNewEditor = false

    private var indices: [Int] {
        store.source.news.indices.filter { index in
            let item = store.source.news[index]
            let appName = linkedApp(for: item, in: store.source.apps)?.name ?? ""
            return search.isEmpty || [item.title, item.caption, appName].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("뉴스").font(.title2.bold()).frame(maxWidth: .infinity).padding(.top, 10).id("newsTop")
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("검색", text: $search)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 15))
                Divider().padding(.top, 3)
                HStack {
                    Text("전체 \(store.source.news.count)개").font(.headline)
                    Spacer()
                    Button {
                        var item = SourceNews()
                        item.identifier = "news_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
                        item.tintColor = store.source.tintColor.isEmpty ? "#00b39e" : store.source.tintColor
                        store.source.news.insert(item, at: 0)
                        search = ""
                        scrollProxy.scrollTo("newsTop", anchor: .top)
                        newEditorIndex = 0
                        showingNewEditor = true
                    } label: { EditorListActionIcon(systemName: "plus.circle") }
                    .accessibilityLabel("뉴스 추가")
                    Button { editing.toggle() } label: {
                        EditorListActionIcon(systemName: editing ? "checkmark.circle" : "square.and.pencil")
                    }
                    .accessibilityLabel(editing ? "편집 완료" : "뉴스 편집")
                }
                if indices.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "뉴스가 없습니다" : "검색 결과가 없습니다", systemImage: "newspaper")
                }
                ForEach(indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        if editing {
                            Button(role: .destructive) {
                                newsToDeleteIndex = index
                                showingDeleteAlert = true
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .accessibilityLabel("뉴스 삭제")
                        }
                        NavigationLink {
                            editor(at: index)
                        } label: {
                            NewsCard(news: store.source.news[index], number: index + 1, apps: store.source.apps)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingNewEditor) {
            if let newEditorIndex { editor(at: newEditorIndex) }
        }
        .alert("뉴스를 삭제하시겠습니까?", isPresented: $showingDeleteAlert) {
            Button("예", role: .destructive) {
                if let newsToDeleteIndex, store.source.news.indices.contains(newsToDeleteIndex) {
                    store.source.news.remove(at: newsToDeleteIndex)
                }
                newsToDeleteIndex = nil
            }
            Button("아니오", role: .cancel) { newsToDeleteIndex = nil }
        }
        .keyboardDismissButton()
        }
    }

    @ViewBuilder private func editor(at index: Int) -> some View {
        if store.source.news.indices.contains(index) {
            NewsEditor(news: $store.source.news[index], apps: store.source.apps,
                       viewCodeAction: viewCodeAction,
                       deleteAction: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if store.source.news.indices.contains(index) { store.source.news.remove(at: index) }
                }
            })
        }
    }
}

private struct NewsCard: View {
    let news: SourceNews
    let number: Int
    let apps: [SourceApp]
    private var app: SourceApp? { linkedApp(for: news, in: apps) }
    private var tint: Color { sourceTintColor(news.tintColor.isEmpty ? (app?.tintColor ?? "#00b39e") : news.tintColor) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("뉴스 \(number)")
                    Text("·")
                    if news.notify { Image(systemName: "bell.fill") }
                    Text(newsDisplayDate(news.date)).font(.caption)
                }
                Text(news.title.isEmpty ? "새 소식" : news.title)
                    .font(.title3.bold()).lineLimit(2)
                if !news.caption.isEmpty { Text(news.caption).font(.subheadline).lineLimit(2) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(tint)
            if !news.imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Color.clear
                    .aspectRatio(5.0 / 3.0, contentMode: .fit)
                    .overlay { RemoteImage(url: news.imageURL, systemName: "photo") }
                    .clipped()
            }
            if let app {
                HStack(spacing: 12) {
                    RemoteImage(url: app.iconURL, systemName: "app.fill", localData: app.iconPreviewData)
                        .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.22))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct NewsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var news: SourceNews
    let apps: [SourceApp]
    let viewCodeAction: () -> Void
    let deleteAction: () -> Void
    @State private var choosingApp = false
    @State private var deleting = false

    private var dateBinding: Binding<Date> {
        Binding(get: { newsDate(news.date) }, set: { news.date = newsISODate($0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Spacer()
                    Button(action: viewCodeAction) { Label("소스코드 보기", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Divider().frame(height: 20)
                    Button(role: .destructive) { deleting = true } label: { Image(systemName: "trash") }
                        .accessibilityLabel("뉴스 삭제")
                }
                NewsPosterField(url: $news.imageURL)
                AppInputField(title: "제목", text: $news.title)
                AppInputField(title: "식별자", text: $news.identifier, identifier: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("틴트 컬러").font(.subheadline)
                    HStack {
                        TextField("#00b39e", text: $news.tintColor)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        ColorPicker("틴트 컬러", selection: Binding(
                            get: { sourceTintColor(news.tintColor) },
                            set: { news.tintColor = sourceHexColor($0) }
                        )).labelsHidden()
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                AppInputField(title: "뉴스 내용", text: $news.caption, multiline: true)
                AppInputField(title: "뉴스 URL (선택 사항)", text: $news.url, identifier: true)
                Text("현재 JSON 저장 형식에서는 뉴스 URL이 제외됩니다.")
                    .font(.caption2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("게시일").font(.subheadline)
                    DatePicker("게시일", selection: dateBinding, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.locale, Locale(identifier: "ko_KR"))
                        .labelsHidden().frame(maxWidth: .infinity)
                        .padding(8)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("알림").font(.subheadline)
                    Toggle(isOn: $news.notify) { Label("알림 보내기", systemImage: "bell.fill") }
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("연결된 앱 (선택 사항)").font(.subheadline)
                    if let app = linkedApp(for: news, in: apps) {
                        AssociatedAppCard(app: app, actionTitle: "연결 해제") { news.appID = "" }
                    } else {
                        Button { choosingApp = true } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "plus.app")
                                    .font(.system(size: 34, weight: .regular))
                                    .foregroundStyle(.blue)
                                    .frame(width: 72, height: 72)
                                    .background(Color(uiColor: .tertiarySystemBackground),
                                                in: RoundedRectangle(cornerRadius: 18))
                                Text("애플리케이션 연결하기")
                                    .font(.title3)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .background(Color(uiColor: .secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 22))
                            .contentShape(RoundedRectangle(cornerRadius: 22))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }
        .navigationTitle("뉴스 편집")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $choosingApp) {
            AssociatedAppPicker(apps: apps) { news.appID = $0.bundleIdentifier; choosingApp = false }
        }
        .alert("뉴스를 삭제하시겠습니까?", isPresented: $deleting) {
            Button("예", role: .destructive) { dismiss(); deleteAction() }
            Button("아니오", role: .cancel) {}
        }
        .keyboardDismissButton()
    }
}

private struct NewsPosterField: View {
    @Binding var url: String
    @State private var showingImageOptions = false
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingURLSheet = false
    @State private var urlDraft = ""
    @State private var uploading = false
    @State private var uploadError: String?
    @State private var framingRequest: ImageFramingRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("포스터 이미지 (선택 사항)").font(.subheadline)
            Button { showingImageOptions = true } label: {
                ZStack {
                    if url.isEmpty {
                        Label("이미지 추가", systemImage: "photo").font(.headline)
                    } else {
                        RemoteImage(url: url, systemName: "photo")
                    }
                    if uploading {
                        Color.black.opacity(0.18)
                        ProgressView("이미지 업로드 중…")
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(width: 180, height: 108)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .disabled(uploading)
            if !url.isEmpty {
                Button("이미지 삭제", role: .destructive) { url = "" }
                    .font(.caption).disabled(uploading)
            }
        }
        .confirmationDialog("포스터 이미지 추가", isPresented: $showingImageOptions, titleVisibility: .visible) {
            Button("사진 앱에서 선택") { showingPhotos = true }
            Button("파일 앱에서 선택") { showingFiles = true }
            Button("이미지 URL 입력") {
                urlDraft = url
                showingURLSheet = true
            }
        }
        .photosPicker(isPresented: $showingPhotos, selection: $selectedPhoto, matching: .images)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let fileURL):
                uploading = true
                Task {
                    do {
                        let data = try await Task.detached(priority: .userInitiated) {
                            let access = fileURL.startAccessingSecurityScopedResource()
                            defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
                            return try Data(contentsOf: fileURL)
                        }.value
                        await prepareImage(data)
                    } catch {
                        uploading = false
                        uploadError = "파일 앱에서 이미지를 읽지 못했습니다: \(error.localizedDescription)"
                    }
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    uploadError = "파일 앱에서 이미지를 선택하지 못했습니다: \(error.localizedDescription)"
                }
            }
        }
        .onChange(of: selectedPhoto) { _, photo in
            guard let photo else { return }
            showingPhotos = false
            uploading = true
            Task {
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self) else {
                        uploading = false
                        uploadError = "사진 앱에서 이미지를 읽지 못했습니다."
                        selectedPhoto = nil
                        return
                    }
                    await prepareImage(data)
                } catch {
                    uploading = false
                    uploadError = "사진 앱에서 이미지를 읽지 못했습니다: \(error.localizedDescription)"
                }
                selectedPhoto = nil
            }
        }
        .sheet(isPresented: $showingURLSheet) { urlEditingSheet }
        .sheet(item: $framingRequest) { request in
            ImageFramingEditor(image: request.image, profile: .poster,
                               onCancel: { framingRequest = nil }, onApply: { data in
                framingRequest = nil
                uploading = true
                Task { await uploadImage(data) }
            })
        }
        .alert("이미지를 추가하지 못했습니다", isPresented: Binding(
            get: { uploadError != nil },
            set: { if !$0 { uploadError = nil } }
        )) {
            Button("확인", role: .cancel) { uploadError = nil }
        } message: {
            Text(uploadError ?? "")
        }
    }

    private var urlEditingSheet: some View {
        NavigationStack {
            Form {
                TextField("https://example.com/poster.jpg", text: $urlDraft)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                Text("JSON에 저장할 공개 이미지 주소를 입력하세요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("포스터 이미지 URL")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { showingURLSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("적용") {
                        url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        showingURLSheet = false
                    }
                    .disabled(!validImageURL(urlDraft))
                }
            }
        }
    }

    private func prepareImage(_ data: Data) async {
        defer { uploading = false }
        do { framingRequest = try await ImageFramingRequest.prepare(data) }
        catch { uploadError = error.localizedDescription }
    }

    private func uploadImage(_ data: Data) async {
        uploading = true
        defer { uploading = false }
        do {
            url = try await CloudinaryImageUploader.upload(data).absoluteString
        } catch {
            uploadError = error.localizedDescription
        }
    }

    private func validImageURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
}

private struct AssociatedAppPicker: View {
    @Environment(\.dismiss) private var dismiss
    let apps: [SourceApp]
    let select: (SourceApp) -> Void
    @State private var search = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(apps.indices.filter { index in
                        guard !apps[index].bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                        return search.isEmpty || apps[index].name.localizedCaseInsensitiveContains(search)
                            || apps[index].bundleIdentifier.localizedCaseInsensitiveContains(search)
                    }, id: \.self) { index in
                        AssociatedAppCard(app: apps[index], actionTitle: "연결") { select(apps[index]) }
                    }
                }.padding(16)
            }
            .searchable(text: $search, prompt: "검색")
            .navigationTitle("연결할 앱 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("닫기") { dismiss() } }
        }
    }
}

private struct AssociatedAppCard: View {
    let app: SourceApp
    let actionTitle: String
    let action: () -> Void
    private var tint: Color { sourceTintColor(app.tintColor) }
    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: app.iconURL, systemName: "app.fill", localData: app.iconPreviewData)
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .font(.caption.bold()).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(tint, in: Capsule())
        }
        .padding(12).background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 19))
    }
}

private func newsDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    if let parsed = formatter.date(from: value) { return parsed }
    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: String(value.prefix(10))) ?? .now
}

private func newsISODate(_ value: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    return formatter.string(from: value)
}

private func newsDisplayDate(_ value: String) -> String {
    let parts = String(value.prefix(10)).split(separator: "-")
    guard parts.count == 3 else { return value }
    return "\(parts[0])년 \(Int(parts[1]) ?? 0)월 \(Int(parts[2]) ?? 0)일"
}

struct FileScreen: View {
    @State private var showingGitHubUpload = false
    let newAction: () -> Void
    let importAction: () -> Void
    let exportAction: () -> Void
    private let green = Color(red: 0.02, green: 0.71, blue: 0.57)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 10) {
                    Image(systemName: "folder").font(.title2).foregroundStyle(.purple)
                    Text("파일").font(.title2.bold())
                }
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(LinearGradient(colors: [Color.mint.opacity(0.1), Color.mint.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
                actionGroup("Actions", rows: [
                    ("folder.badge.plus", "소스 새로 만들기", newAction),
                    ("folder", "JSON 불러오기", importAction),
                    ("square.and.arrow.up", "JSON 내보내기", exportAction),
                    ("arrow.up.circle", "GitHub에 업로드하기", { showingGitHubUpload = true })
                ])
                JSONPreviewContent()
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: 780).frame(maxWidth: .infinity)
            .padding(.bottom, 30)
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingGitHubUpload) { GitHubUploadSheet() }
    }

    private func actionGroup(_ title: String, rows: [(String, String, () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    Button(action: rows[index].2) {
                        HStack(spacing: 16) {
                            Image(systemName: rows[index].0).frame(width: 24)
                            Text(rows[index].1)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .font(.title3).foregroundStyle(green)
                        .frame(height: 57).padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    if index < rows.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(Color.mint.opacity(0.24), in: RoundedRectangle(cornerRadius: 22))
        }
        .padding(.horizontal, 16)
    }
}
