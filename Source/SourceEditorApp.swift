import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@main
struct SourceEditorApp: App {
    @StateObject private var store = SourceStore()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: SourceStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var importProgress: Double?
    @State private var exporting = false
    @State private var exportDocument: JSONFile?
    @State private var showWelcome = true
    @State private var confirmingNewProject = false
    @State private var selectedSection: EditorSection? = .source
    @State private var selectedTab: EditorSection = .source
    @State private var splitVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if showWelcome {
                WelcomeScreen(
                    hasDraft: store.hasSavedDraft,
                    importAction: { importing = true },
                    newProjectAction: {
                        if store.hasSavedDraft {
                            confirmingNewProject = true
                        } else {
                            store.newProject()
                            showWelcome = false
                        }
                    },
                    continueAction: { showWelcome = false }
                )
            } else if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular {
                iPadLayout
            } else {
                compactLayout
            }
        }
        .sheet(isPresented: $importing) {
            JSONImportPicker(
                onPick: { url in
                    importing = false
                    beginImport(url)
                },
                onCancel: { importing = false }
            )
        }
        .overlay {
            if let importProgress {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        Text("JSON 불러오는 중…").font(.headline)
                        JSONTransferProgressIndicator(progress: importProgress, accessibilityTitle: "JSON 가져오기 진행률")
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .zIndex(1)
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "Source.json") { result in
            if case .failure(let error) = result { store.message = error.localizedDescription }
        }
        .alert("Source Editor", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("확인", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
        .confirmationDialog("현재 작업을 지우고 새 프로젝트를 만들까요?", isPresented: $confirmingNewProject) {
            Button("새 프로젝트 만들기", role: .destructive) {
                store.newProject()
                showWelcome = false
                selectedTab = .source
                selectedSection = .source
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.finishReorder()
            }
        }
    }

    private var compactLayout: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                SourceEditor(viewCodeAction: { selectedTab = .json }, addAppAction: {
                    store.source.apps.append(SourceApp())
                    selectedTab = .apps
                })
            }
                .tabItem { Label("소스", systemImage: "square.stack.3d.up") }
                .tag(EditorSection.source)
            NavigationStack { AppsScreen() }
                .tabItem { Label("앱", systemImage: "apps.iphone") }
                .tag(EditorSection.apps)
            NavigationStack { NewsScreen(viewCodeAction: { selectedTab = .json }) }
                .tabItem { Label("뉴스", systemImage: "newspaper") }
                .tag(EditorSection.news)
            NavigationStack { projectScreen }
                .tabItem { Label("Project", systemImage: "hammer.fill") }
                .tag(EditorSection.project)
            NavigationStack { jsonScreen }
                .tabItem { Label("JSON", systemImage: "curlybraces") }
                .tag(EditorSection.json)
        }
    }

    private var iPadLayout: some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            List(EditorSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Source Editor")
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                Text("앱 \(store.source.apps.count)개 · 뉴스 \(store.source.news.count)개")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } detail: {
            NavigationStack {
                switch selectedSection ?? .source {
                case .source: SourceEditor(viewCodeAction: { selectedSection = .json }, addAppAction: {
                    store.source.apps.append(SourceApp())
                    selectedSection = .apps
                })
                case .apps: AppsScreen()
                case .news: NewsScreen(viewCodeAction: { selectedSection = .json })
                case .project: projectScreen
                case .json: jsonScreen
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var jsonScreen: some View {
        JSONScreen(importAction: { importing = true }, exportAction: beginExport)
    }

    private var projectScreen: some View {
        ProjectScreen(
            newAction: {
                if store.hasSavedDraft { confirmingNewProject = true }
                else { store.newProject(); selectedTab = .source; selectedSection = .source }
            },
            importAction: { importing = true },
            exportAction: beginExport,
            viewCodeAction: { selectedTab = .json; selectedSection = .json }
        )
    }

    private func beginExport() {
        exportDocument = JSONFile(data: store.jsonData())
        exporting = true
    }

    private func beginImport(_ url: URL) {
        let started = Date()
        importProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<(Data, Source), Error> = Result {
                guard url.pathExtension.lowercased() == "json" else { throw JSONImportError.invalidExtension }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let expectedSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var data = Data()
                var readBytes: Int64 = 0
                while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                    data.append(chunk)
                    readBytes += Int64(chunk.count)
                    let fraction = expectedSize > 0 ? min(0.95, Double(readBytes) / Double(expectedSize) * 0.95) : 0.95
                    DispatchQueue.main.async {
                        withAnimation(.linear(duration: 0.25)) { importProgress = fraction }
                    }
                }
                return (data, try SourceStore.decodeJSON(data))
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let (data, source)):
                    withAnimation(.linear(duration: 0.5)) { importProgress = 1 }
                    let remaining = max(0.6, 0.8 - Date().timeIntervalSince(started))
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                        importProgress = nil
                        store.applyImportedJSON(source, data: data)
                        showWelcome = false
                    }
                case .failure(let error):
                    importProgress = nil
                    store.message = "JSON 파일을 불러오지 못했습니다: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct JSONTransferProgressIndicator: View, Animatable {
    var progress: Double
    let accessibilityTitle: String
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: progress, total: 1)
                .tint(.blue)
                .frame(width: 250)
            Text("\(Int((progress * 100).rounded()))%")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue("\(Int((progress * 100).rounded()))퍼센트")
    }
}

private enum JSONImportError: LocalizedError {
    case invalidExtension
    var errorDescription: String? { "확장자가 .json인 파일만 선택할 수 있습니다." }
}

struct JSONImportPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

struct WelcomeScreen: View {
    let hasDraft: Bool
    let importAction: () -> Void
    let newProjectAction: () -> Void
    let continueAction: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack {
                    Spacer(minLength: 24)
                    VStack(spacing: 24) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 25)
                                .fill(LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Text("{ }")
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 86, height: 86)
                        .accessibilityHidden(true)

                        Text("Welcome to Source Editor")
                            .font(.system(size: UIDevice.current.userInterfaceIdiom == .pad ? 34 : 28,
                                          weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("SideStore용 소스 JSON을 만들고 관리하세요. 앱과 뉴스 정보를 입력한 뒤 JSON 파일로 저장할 수 있습니다.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 22) {
                            feature("rectangle.split.2x1", "편리한 편집", "소스, 앱, 버전과 뉴스를 한곳에서 관리합니다.")
                            feature("arrow.down.doc", "기존 JSON 가져오기", "파일 앱에서 Source JSON을 선택해 계속 편집합니다.")
                            feature("ipad.and.iphone", "iPhone·iPad 지원", "화면 크기에 맞는 편집 화면으로 작업합니다.")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)

                        Button(action: importAction) {
                            Text("JSON 가져오기")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("새 프로젝트", action: newProjectAction)
                            .font(.headline)

                        if hasDraft {
                            Button("이전 작업 계속하기", action: continueAction)
                                .font(.subheadline)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 650)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26))
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                .padding(.horizontal, 18)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private enum EditorSection: String, CaseIterable, Identifiable {
    case source, apps, news, project, json
    var id: Self { self }
    var title: String {
        switch self {
        case .source: "소스 설정"
        case .apps: "앱"
        case .news: "뉴스"
        case .project: "Project"
        case .json: "JSON 미리보기"
        }
    }
    var icon: String {
        switch self {
        case .source: "square.stack.3d.up"
        case .apps: "apps.iphone"
        case .news: "newspaper"
        case .project: "hammer.fill"
        case .json: "curlybraces"
        }
    }
}

struct SourceEditor: View {
    @EnvironmentObject private var store: SourceStore
    @Environment(\.scenePhase) private var scenePhase
    let viewCodeAction: () -> Void
    let addAppAction: () -> Void
    @State private var searchText = ""
    @State private var rowFrameCache = ReorderFrameCache()
    @State private var dragFrames: [String: CGRect] = [:]
    @State private var autoScroller = ReorderAutoScroller()
    @State private var handleDragID: String?
    @State private var dragPosition = ReorderDragPosition()
    @State private var dragTouchOffset: CGFloat = 0
    @State private var previewFeaturedOrder: [String]?

    private var featuredOrder: [String] { previewFeaturedOrder ?? store.source.featuredApps }

    private var visibleApps: [SourceApp] {
        let apps = store.source.apps.filter { app in
            searchText.isEmpty || app.name.localizedCaseInsensitiveContains(searchText)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
        let selected = featuredOrder.compactMap { id in apps.first { $0.bundleIdentifier == id } }
        return selected + apps.filter { !featuredOrder.contains($0.bundleIdentifier) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Spacer()
                    Button(action: viewCodeAction) { Label("소스코드 보기", systemImage: "chevron.left.forwardslash.chevron.right") }
                        .font(.headline)
                }
                Text("소스")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.bottom, 8)

                SourceImageField(title: "헤더 이미지", url: $store.source.headerURL,
                                 isHeader: true, confirmDeletion: true)
                SourceImageField(title: "아이콘", url: $store.source.iconURL,
                                 isHeader: false, confirmDeletion: true)

                SourceTextField(title: "틴트 컬러", text: $store.source.tintColor) {
                    ColorPicker("틴트 컬러", selection: Binding(
                        get: { sourceTintColor(store.source.tintColor) },
                        set: { store.source.tintColor = sourceHexColor($0) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
                SourceTextField(title: "소스 이름", text: $store.source.name)
                SourceTextField(title: "소스 부제목 (선택 사항)", text: $store.source.subtitle)
                SourceTextField(title: "소스 설명 (선택 사항)", text: $store.source.sourceDescription, multiline: true)
                SourceTextField(title: "웹사이트 (선택 사항)", text: $store.source.website, isURL: true)
                Text("웹사이트는 NightFox JSON 변환 규칙에 따라 내보내기에서 제외됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, -18)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("대표 앱")
                        Spacer()
                        Button(action: addAppAction) { Label("추가", systemImage: "plus") }
                            .font(.headline)
                    }
                    featuredAppsPanel
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
            .background(ReorderScrollLocator { autoScroller.attach($0) })
        }
        .overlay(alignment: .topLeading) {
        if let handleDragID,
           let app = store.source.apps.first(where: { $0.bundleIdentifier == handleDragID }),
           let frame = dragFrames["featured:\(handleDragID)"],
           validReorderFrame(frame) {
            ReorderFloatingPreview(position: dragPosition, frame: frame, touchOffset: dragTouchOffset) {
                featuredRowContent(app, selected: true)
                    .frame(width: frame.width)
                    .scaleEffect(1.025)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
            }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .allowsHitTesting(false)
                .zIndex(1)
        }
        }
        .background(Color(uiColor: .systemBackground))
        .coordinateSpace(name: "featuredReorder")
        .onPreferenceChange(ReorderRowFrames.self) { frames in
            rowFrameCache.frames = frames
            if let handleDragID, autoScroller.isAutoScrolling {
                DispatchQueue.main.async {
                    guard self.handleDragID == handleDragID, self.autoScroller.isAutoScrolling else { return }
                    updateFeaturedDrag(handleDragID, y: dragPosition.fingerY)
                }
            }
        }
        .onDisappear {
            autoScroller.stop()
            commitFeaturedOrder()
            handleDragID = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                autoScroller.stop()
                commitFeaturedOrder()
                handleDragID = nil
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .keyboardDismissButton()
    }

    private var featuredAppsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("검색", text: $searchText,
                          prompt: Text("검색").foregroundColor(Color.primary.opacity(0.7)))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(12)

            if store.source.apps.isEmpty {
                Text("앱을 추가하면 이곳에서 추천 앱을 선택할 수 있습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else if visibleApps.isEmpty {
                Text("검색 결과가 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                ForEach(visibleApps, id: \.editorID) { app in
                    featuredRow(app)
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func featuredRow(_ app: SourceApp) -> some View {
        let selected = featuredOrder.contains(app.bundleIdentifier)
        if selected {
            featuredRowContent(app, selected: true)
                .contentShape(Rectangle())
                .reorderFrame(id: "featured:\(app.bundleIdentifier)", in: "featuredReorder")
                .opacity(handleDragID == app.bundleIdentifier ? 0.001 : 1)
        } else {
            featuredRowContent(app, selected: false)
        }
    }

    private func featuredRowContent(_ app: SourceApp, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if selected {
                ImmediateReorderHandle(
                    coordinateSpace: "featuredReorder",
                    label: "누른 채로 끌어 대표 앱 순서 변경",
                    onChange: { y in updateFeaturedDrag(app.bundleIdentifier, y: y) },
                    onEnd: { y in endFeaturedDrag(app.bundleIdentifier, y: y) }
                )
            } else {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.gray)
                    .frame(width: 24, height: 44)
                    .accessibilityLabel("대표 앱을 선택하면 순서를 바꿀 수 있습니다")
            }
            if selected {
                featuredAppDetails(app, selected: true)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            ReorderTouchSurface(
                                frame: geometry.frame(in: .named("featuredReorder")),
                                onTap: nil,
                                onChange: { y in updateFeaturedDrag(app.bundleIdentifier, y: y) },
                                onEnd: { y in endFeaturedDrag(app.bundleIdentifier, y: y) }
                            )
                            .frame(width: max(0, geometry.size.width - 52))
                        }
                    }
            } else {
                featuredAppDetails(app, selected: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func featuredAppDetails(_ app: SourceApp, selected: Bool) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: app.iconURL, systemName: "app", localData: app.iconPreviewData)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name.isEmpty ? "새 앱" : app.name).font(.body).lineLimit(1)
                Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { toggleFeatured(app.bundleIdentifier) } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? .blue : .gray)
            }
            .accessibilityLabel(selected ? "추천 앱에서 제거" : "추천 앱으로 선택")
        }
    }

    private func toggleFeatured(_ id: String) {
        guard !id.isEmpty else { return }
        let validIDs = Set(store.source.apps.map(\.bundleIdentifier))
        store.source.featuredApps.removeAll { !validIDs.contains($0) }
        if let index = store.source.featuredApps.firstIndex(of: id) {
            store.source.featuredApps.remove(at: index)
        } else if store.source.featuredApps.count < 5 {
            store.source.featuredApps.append(id)
        } else {
            store.message = "추천 앱은 최대 5개까지 선택할 수 있습니다."
        }
    }

    private func moveFeatured(_ sourceID: String, to targetIndex: Int) {
        guard var order = previewFeaturedOrder else { return }
        guard let sourceIndex = order.firstIndex(of: sourceID),
              order.indices.contains(targetIndex),
              sourceIndex != targetIndex else { return }
        order.remove(at: sourceIndex)
        order.insert(sourceID, at: targetIndex)
        withAnimation(ReorderMotion.shift) { previewFeaturedOrder = order }
    }

    private func commitFeaturedOrder() {
        guard let previewFeaturedOrder else { return }
        if previewFeaturedOrder != store.source.featuredApps {
            store.reorderFeaturedApps(previewFeaturedOrder)
            store.finishReorder()
        }
        self.previewFeaturedOrder = nil
    }

    private func updateFeaturedDrag(_ id: String, y: CGFloat) {
        guard y.isFinite else { return }
        if handleDragID == nil {
            dragFrames = rowFrameCache.frames.filter { validReorderFrame($0.value) }
            guard let frame = dragFrames["featured:\(id)"] else { return }
            previewFeaturedOrder = store.source.featuredApps
            dragTouchOffset = y - frame.midY
            dragPosition.update(to: y)
            withAnimation(ReorderMotion.lift) { handleDragID = id }
            autoScroller.start(at: y)
        }
        guard handleDragID == id else { return }
        dragPosition.update(to: y)
        autoScroller.update(to: y)
        guard let center = safeReorderY(y, offset: dragTouchOffset) else { return }
        let slots = rowFrameCache.frames.filter {
            $0.key.hasPrefix("featured:") && validReorderFrame($0.value)
                && featuredOrder.contains(String($0.key.dropFirst(9)))
        }.sorted { $0.value.midY < $1.value.midY }
        if let target = slots.enumerated().min(by: {
            abs($0.element.value.midY - center) < abs($1.element.value.midY - center)
        })?.offset,
           let slotIndex = featuredOrder.firstIndex(of: String(slots[target].key.dropFirst(9))) {
            moveFeatured(id, to: slotIndex)
        }
    }

    private func endFeaturedDrag(_ id: String, y: CGFloat) {
        updateFeaturedDrag(id, y: y)
        guard handleDragID == id else { return }
        autoScroller.stop()
        withAnimation(ReorderMotion.drop) { handleDragID = nil }
        dragFrames = [:]
        commitFeaturedOrder()
    }
}

struct SourceImageField: View {
    let title: String
    @Binding var url: String
    let isHeader: Bool
    var confirmDeletion = false
    var importedPreview: Data? = nil
    var clearImportedPreview: (() -> Void)? = nil
    var saveImportedPreview: (() -> Void)? = nil
    var isSavingImportedPreview = false
    @State private var selectedImage: PhotosPickerItem?
    @State private var localPreview: Data?
    @State private var urlPreviewImage: UIImage?
    @State private var loadingURLPreview = false
    @State private var showingDeleteAlert = false

    private var previewData: Data? { localPreview ?? importedPreview }
    private var previewURL: URL? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = URL(string: text),
              ["http", "https"].contains(candidate.scheme?.lowercased() ?? ""),
              candidate.host != nil else { return nil }
        return candidate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 14) {
                Group {
                    if let urlPreviewImage, !url.isEmpty {
                        Image(uiImage: urlPreviewImage).resizable().scaledToFill()
                    } else if url.isEmpty, let previewData, let image = UIImage(data: previewData) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color(uiColor: .secondarySystemBackground))
                            .overlay {
                                if loadingURLPreview {
                                    ProgressView()
                                } else {
                                    Image(systemName: "photo").foregroundStyle(.secondary)
                                }
                            }
                    }
                }
                .frame(width: isHeader ? 96 : 70, height: isHeader ? 76 : 70)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline)
                    TextField("이미지 URL", text: $url)
                        .urlField()
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    HStack {
                        PhotosPicker(selection: $selectedImage, matching: .images) {
                            Text("이미지 선택")
                        }
                        Spacer()
                        if !url.isEmpty || previewData != nil {
                            Button("삭제", role: .destructive) {
                                if confirmDeletion { showingDeleteAlert = true }
                                else { deleteImage() }
                            }
                            .foregroundStyle(.red)
                        }
                    }
                    .font(.subheadline)
                }
            }
            if previewData != nil {
                if importedPreview != nil, let saveImportedPreview {
                    Button(isSavingImportedPreview ? "사진 앱에 저장 중…" : "추출한 아이콘 저장") {
                        saveImportedPreview()
                    }
                        .disabled(isSavingImportedPreview)
                        .font(.subheadline)
                }
                Text("아이콘 파일은 미리보기용입니다. JSON에는 공개 이미지 URL이 필요합니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: selectedImage) { _, item in
            Task { localPreview = try? await item?.loadTransferable(type: Data.self) }
        }
        .alert(isHeader ? "헤더 이미지를 삭제하시겠습니까?" : "아이콘을 삭제하시겠습니까?",
               isPresented: $showingDeleteAlert) {
            Button("예", role: .destructive) { deleteImage() }
            Button("아니오", role: .cancel) {}
        }
        .onChange(of: url) { _, _ in localPreview = nil }
        .task(id: url) { await loadURLPreview() }
    }

    private func deleteImage() {
        url = ""
        localPreview = nil
        selectedImage = nil
        clearImportedPreview?()
    }

    private func loadURLPreview() async {
        urlPreviewImage = nil
        guard let previewURL else {
            loadingURLPreview = false
            return
        }
        loadingURLPreview = true
        defer {
            if self.previewURL == previewURL { loadingURLPreview = false }
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let (data, response) = try await URLSession.shared.data(from: previewURL)
            guard !Task.isCancelled, self.previewURL == previewURL,
                  data.count <= 10_000_000,
                  (response as? HTTPURLResponse).map({ 200...299 ~= $0.statusCode }) ?? false,
                  let image = UIImage(data: data) else { return }
            urlPreviewImage = image
        } catch { }
    }
}

struct RemoteImage: View {
    let url: String
    let systemName: String
    var localData: Data? = nil
    var body: some View {
        Group {
            if url.isEmpty, let localData, let image = UIImage(data: localData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                AsyncImage(url: URL(string: url)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color(uiColor: .secondarySystemBackground))
                            .overlay(Image(systemName: systemName).foregroundStyle(.secondary))
                    }
                }
            }
        }
        .clipped()
    }
}

struct SourceTextField<Accessory: View>: View {
    let title: String
    @Binding var text: String
    var multiline = false
    var isURL = false
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, text: Binding<String>, multiline: Bool = false, isURL: Bool = false,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self._text = text
        self.multiline = multiline
        self.isURL = isURL
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline)
            HStack(alignment: multiline ? .top : .center) {
                Group {
                    if multiline {
                        TextField("", text: $text, axis: .vertical).lineLimit(5...8)
                    } else {
                        TextField("", text: $text)
                            .textInputAutocapitalization(isURL ? .never : .sentences)
                            .autocorrectionDisabled(isURL)
                            .keyboardType(isURL ? .URL : .default)
                    }
                }
                .frame(maxWidth: .infinity)
                accessory()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, multiline ? 12 : 0)
            .frame(minHeight: multiline ? 92 : 38)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

extension SourceTextField where Accessory == EmptyView {
    init(title: String, text: Binding<String>, multiline: Bool = false, isURL: Bool = false) {
        self.init(title: title, text: text, multiline: multiline, isURL: isURL) { EmptyView() }
    }
}

func sourceTintColor(_ hex: String) -> Color {
    let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard value.count == 6, let number = Int(value, radix: 16) else { return .gray }
    return Color(red: Double((number >> 16) & 0xff) / 255,
                 green: Double((number >> 8) & 0xff) / 255,
                 blue: Double(number & 0xff) / 255)
}

func sourceHexColor(_ color: Color) -> String {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return String(format: "#%02x%02x%02x", Int(red * 255), Int(green * 255), Int(blue * 255))
}

struct VersionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var version: SourceVersion
    @State private var draft: SourceVersion
    @State private var sizeText = ""
    @State private var sizeUnit = "MB"
    @State private var didLoadSize = false
    private let units = ["bytes", "KB", "MB", "GB"]

    init(version: Binding<SourceVersion>) {
        _version = version
        _draft = State(initialValue: version.wrappedValue)
    }

    private var canSave: Bool {
        !draft.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.date.isEmpty && draft.size > 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AppInputField(title: "IPA/ADP 다운로드 URL *", text: $draft.downloadURL,
                              placeholder: "https://example.com/app.ipa", identifier: true)

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 2) {
                            Text("IPA/ADP 파일 크기")
                            Text("*").foregroundStyle(.red)
                        }
                        .font(.subheadline)
                        HStack(spacing: 8) {
                            TextField("0.0", text: $sizeText)
                                .keyboardType(.decimalPad)
                            if !sizeText.isEmpty {
                                Button { sizeText = "" } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("파일 크기 지우기")
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("단위").font(.subheadline)
                        Picker("단위", selection: $sizeUnit) {
                            ForEach(units, id: \.self) { Text($0 == "bytes" ? "바이트" : $0).tag($0) }
                        }
                        .labelsHidden()
                        .padding(.horizontal, 8)
                        .frame(height: 42)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                }

                AppInputField(title: "버전 번호 *", text: $draft.version, placeholder: "1.0.0")
                AppInputField(title: "빌드 번호 (선택 사항)", text: $draft.buildVersion, placeholder: "123")
                Text("빌드 번호는 현재 JSON 내보내기 형식에서 제외됩니다.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, -18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        Text("출시일")
                        Text("*").foregroundStyle(.red)
                    }
                    .font(.subheadline)
                    DatePicker("출시일", selection: dateBinding, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.locale, Locale(identifier: "ko_KR"))
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                AppInputField(title: "변경 사항 (선택 사항)", text: $draft.localizedDescription,
                              placeholder: "이번 버전의 변경 사항", multiline: true)
                AppInputField(title: "최소 iOS 버전 (선택 사항)", text: $draft.minOSVersion, placeholder: "16.1")

                DisclosureGroup("추가 설정") {
                    VStack(alignment: .leading, spacing: 18) {
                        AppInputField(title: "표시 버전 (선택 사항)", text: $draft.marketingVersion)
                        AppInputField(title: "최대 iOS 버전 (선택 사항)", text: $draft.maxOSVersion)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ADP 파일별 URL (선택 사항)").font(.subheadline)
                            TextField("파일명=URL 형식, 한 줄에 하나씩", text: Binding(
                                get: { draft.assetURLs.keys.sorted().map { "\($0)=\(draft.assetURLs[$0] ?? "")" }.joined(separator: "\n") },
                                set: { draft.assetURLs = parsePairs($0) }
                            ), axis: .vertical)
                            .lineLimit(2...6)
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(.top, 14)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .frame(maxWidth: 760)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("앱 버전 편집")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("편집 취소")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                version = draft
                dismiss()
            } label: {
                Text("저장").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
            .padding(16)
            .background(Color(uiColor: .systemBackground))
        }
        .onAppear {
            guard !didLoadSize else { return }
            didLoadSize = true
            if draft.size >= 1_000_000_000 { sizeUnit = "GB" }
            else if draft.size >= 1_000_000 { sizeUnit = "MB" }
            else if draft.size >= 1_000 { sizeUnit = "KB" }
            else { sizeUnit = "bytes" }
            sizeText = sizeDisplay(draft.size)
        }
        .onChange(of: sizeText) { _, _ in updateSize() }
        .onChange(of: sizeUnit) { _, _ in sizeText = sizeDisplay(draft.size) }
        .keyboardDismissButton()
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { appVersionPickerDate(draft.date) },
                set: { draft.date = appVersionISODate($0) })
    }

    private var sizeMultiplier: Double {
        switch sizeUnit {
        case "KB": 1_000
        case "MB": 1_000_000
        case "GB": 1_000_000_000
        default: 1
        }
    }

    private func sizeDisplay(_ bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        let value = Double(bytes) / sizeMultiplier
        return value.rounded() == value ? String(format: "%.0f", value) : String(value)
    }

    private func updateSize() {
        let value = (Double(sizeText.replacingOccurrences(of: ",", with: ".")) ?? 0) * sizeMultiplier
        draft.size = value.isFinite && value >= 0 && value <= Double(Int.max) ? Int(value.rounded()) : 0
    }
}

struct ScreenshotsEditor: View {
    @Binding var screenshots: AppScreenshots
    var body: some View {
        Form {
            screenshotSection("iPhone", items: $screenshots.iphone)
            screenshotSection("iPad", items: $screenshots.ipad)
        }
        .navigationTitle("스크린샷")
        .keyboardDismissButton()
    }
    private func screenshotSection(_ title: String, items: Binding<[Screenshot]>) -> some View {
        Section(title) {
            ForEach(items.wrappedValue.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    TextField("이미지 URL", text: items[index].imageURL).urlField()
                    HStack {
                        TextField("너비", text: items[index].width).keyboardType(.numberPad)
                        TextField("높이", text: items[index].height).keyboardType(.numberPad)
                    }
                }
            }
            .onDelete { items.wrappedValue.remove(atOffsets: $0) }
            Button { items.wrappedValue.append(Screenshot()) } label: { Label("추가", systemImage: "plus") }
        }
    }
}

struct PermissionsEditor: View {
    @Binding var permissions: AppPermissions
    var body: some View {
        Form {
            Section("앱 권한 설정") {
                TextField("한 줄에 하나씩", text: Binding(
                    get: { permissions.entitlements.joined(separator: "\n") },
                    set: { permissions.entitlements = $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ), axis: .vertical).lineLimit(4...10)
            }
            Section("개인정보 사용 설명") {
                TextField("키=설명 형식, 한 줄에 하나씩", text: Binding(
                    get: { permissions.privacy.keys.sorted().map { "\($0)=\(permissions.privacy[$0] ?? "")" }.joined(separator: "\n") },
                    set: { permissions.privacy = parsePairs($0) }
                ), axis: .vertical).lineLimit(4...10)
            }
        }
        .navigationTitle("권한")
        .keyboardDismissButton()
    }
}

extension View {
    func keyboardDismissButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Label("키보드 내리기", systemImage: "keyboard.chevron.compact.down")
                }
                .accessibilityLabel("키보드 내리기")
            }
        }
    }
}

struct JSONScreen: View {
    @EnvironmentObject private var store: SourceStore
    @State private var showingGitHubUpload = false
    let importAction: () -> Void
    let exportAction: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    actionButtons(uploadTitle: "GitHub에 업로드하기")
                        .fixedSize(horizontal: true, vertical: false)
                    actionButtons(uploadTitle: "GitHub 업로드")
                }
                if store.issues.isEmpty {
                    Label("필수 항목 검사를 통과했습니다", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("확인할 항목 \(store.issues.count)개", systemImage: "exclamationmark.triangle.fill").font(.headline)
                        ForEach(store.issues, id: \.self) { Text("• \($0)").font(.footnote) }
                    }
                    .foregroundStyle(.orange)
                }
                SelectableJSONTextView(text: store.jsonText)
                    .frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 680 : 520)
                    .background(.black, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
        .navigationTitle("JSON 미리보기")
        .sheet(isPresented: $showingGitHubUpload) { GitHubUploadSheet() }
    }

    private func actionButtons(uploadTitle: String) -> some View {
        HStack(spacing: 6) {
            Button(action: importAction) { Label("가져오기", systemImage: "square.and.arrow.down") }
                .buttonStyle(.bordered)
            Button(action: exportAction) { Label("JSON 저장", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
            Button { showingGitHubUpload = true } label: {
                Label(uploadTitle, systemImage: "arrow.up.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("GitHub에 업로드하기")
        }
        .font(.subheadline)
    }
}

private struct SelectableJSONTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .black
        view.indicatorStyle = .white
        view.tintColor = .systemBlue
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityLabel = "JSON 미리보기 내용"
        view.attributedText = JSONPreviewSyntax.attributedText(text)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        let selection = view.selectedRange
        let offset = view.contentOffset
        view.attributedText = JSONPreviewSyntax.attributedText(text)
        let location = min(selection.location, text.utf16.count)
        view.selectedRange = NSRange(location: location, length: min(selection.length, text.utf16.count - location))
        view.setContentOffset(offset, animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            let selectAll = UIAction(title: "전체 선택") { [weak textView] _ in
                guard let textView else { return }
                textView.selectedRange = NSRange(location: 0, length: textView.text.utf16.count)
            }
            let copyAll = UIAction(title: "전체 복사", image: UIImage(systemName: "doc.on.doc")) { [weak textView] _ in
                UIPasteboard.general.string = textView?.text
            }
            return UIMenu(children: suggestedActions + [selectAll, copyAll])
        }
    }
}

private enum JSONPreviewSyntax {
    // AltStudio's code viewer uses Monaco, Menlo, Consolas at 14px.
    // Menlo is available on iOS; the token colors match its dark theme.
    private static let font = UIFont(name: "Menlo-Regular", size: 14)
        ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private static let tokens = try! NSRegularExpression(
        pattern: #""(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\b(?:true|false|null)\b"#
    )

    static func attributedText(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20
        paragraph.maximumLineHeight = 20
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph
        ])
        let source = text as NSString
        tokens.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let range = match?.range else { return }
            let token = source.substring(with: range)
            let color: UIColor
            if token.hasPrefix("\"") {
                var next = NSMaxRange(range)
                while next < source.length, [9, 10, 13, 32].contains(source.character(at: next)) { next += 1 }
                // A quoted token followed by a colon is a field name, not a string value.
                color = next < source.length && source.character(at: next) == 58
                    ? .white : UIColor(red: 0x13 / 255.0, green: 0xCE / 255.0, blue: 0x66 / 255.0, alpha: 1)
            } else if token == "null" {
                color = UIColor(red: 0xD5 / 255.0, green: 0x5F / 255.0, blue: 0xDE / 255.0, alpha: 1)
            } else {
                color = UIColor(red: 0x1D / 255.0, green: 0x8C / 255.0, blue: 0xE0 / 255.0, alpha: 1)
            }
            result.addAttribute(.foregroundColor, value: color, range: range)
        }
        return result
    }
}

private func parsePairs(_ value: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in value.components(separatedBy: .newlines) {
        guard let split = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<split]).trimmingCharacters(in: .whitespaces)
        let text = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
        if !key.isEmpty && !text.isEmpty { result[key] = text }
    }
    return result
}

private extension View {
    func urlField() -> some View { textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled() }
}
