import SwiftUI
import UniformTypeIdentifiers

func validReorderFrame(_ frame: CGRect) -> Bool {
    frame.origin.x.isFinite && frame.origin.y.isFinite
        && frame.width.isFinite && frame.height.isFinite
        && frame.midX.isFinite && frame.midY.isFinite
        && frame.width > 0 && frame.height > 0
        && abs(frame.midX) < 100_000 && abs(frame.midY) < 100_000
}

func safeReorderY(_ fingerY: CGFloat, offset: CGFloat) -> CGFloat? {
    let y = fingerY - offset
    return y.isFinite && abs(y) < 100_000 ? y : nil
}

struct ReorderTouchSurface: UIViewRepresentable {
    let frame: CGRect
    let onTap: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.4
        press.allowableMovement = 10
        press.delegate = context.coordinator
        press.cancelsTouchesInView = false
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.frame = frame
        context.coordinator.onTap = onTap
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var frame: CGRect = .zero
        var onTap: (() -> Void)?
        var onChange: ((CGFloat) -> Void)?
        var onEnd: ((CGFloat) -> Void)?

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { onTap?() }
        }

        @objc func pressed(_ gesture: UILongPressGestureRecognizer) {
            guard validReorderFrame(frame), let view = gesture.view else { return }
            let y = frame.minY + gesture.location(in: view).y
            guard y.isFinite else { return }
            switch gesture.state {
            case .began, .changed: onChange?(y)
            case .ended, .cancelled: onEnd?(y)
            default: break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

struct ReorderRowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct ImmediateReorderHandle: View {
    let coordinateSpace: String
    let label: String
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.blue)
            .frame(width: 24, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                    .onChanged { value in onChange(value.location.y) }
                    .onEnded { value in onEnd(value.location.y) }
            )
    }
}

extension View {
    func reorderFrame(id: String, in coordinateSpace: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: ReorderRowFrames.self,
                                       value: [id: geometry.frame(in: .named(coordinateSpace))])
            }
        }
    }

    func pressToReorder(in coordinateSpace: String,
                        onChange: @escaping (CGFloat) -> Void,
                        onEnd: @escaping (CGFloat) -> Void) -> some View {
        simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35, maximumDistance: 8)
                .sequenced(before: DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpace)))
                .onChanged { phase in
                    if case .second(true, let drag?) = phase { onChange(drag.location.y) }
                }
                .onEnded { phase in
                    if case .second(true, let drag?) = phase { onEnd(drag.location.y) }
                }
        )
    }
}

private final class ReorderFrameCache {
    var frames: [String: CGRect] = [:]
}

struct AppsScreen: View {
    @EnvironmentObject private var store: SourceStore
    @State private var search = ""
    @State private var editing = false
    @State private var editorAppID: UUID?
    @State private var showingEditor = false
    @State private var lastDraggedAppID: UUID?
    @State private var lastDragEndedAt: Date = .distantPast
    @State private var rowFrameCache = ReorderFrameCache()
    @State private var dragFrames: [String: CGRect] = [:]
    @State private var dragSlotIndices: [UUID: Int] = [:]
    @State private var draggedAppID: UUID?
    @State private var dragFingerY: CGFloat = 0
    @State private var dragTouchOffset: CGFloat = 0

    private var visibleApps: [AltApp] {
        store.source.apps.filter { app in
            return search.isEmpty || app.name.localizedCaseInsensitiveContains(search)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("앱").font(.system(size: 34, weight: .bold)).padding(.top, 14)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("검색", text: $search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Divider()
                HStack {
                    Text("전체 \(store.source.apps.count)개").font(.headline)
                    Spacer()
                    Button {
                        let app = AltApp()
                        store.source.apps.append(app)
                        openEditor(for: app.editorID)
                    } label: {
                        Image(systemName: "plus.circle")
                            .resizable().scaledToFit()
                            .frame(width: 26, height: 26)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("앱 추가")
                    Button { editing.toggle() } label: {
                        Image(systemName: editing ? "checkmark.circle" : "square.and.pencil")
                            .resizable().scaledToFit()
                            .frame(width: 26, height: 26)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(editing ? "편집 완료" : "앱 목록 편집")
                }

                if store.source.apps.isEmpty {
                    ContentUnavailableView("앱이 없습니다", systemImage: "apps.iphone", description: Text("앱을 추가해 주세요."))
                } else if visibleApps.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleApps, id: \.editorID) { app in
                            if let index = store.source.apps.firstIndex(where: { $0.editorID == app.editorID }) {
                            HStack(spacing: 7) {
                                if editing {
                                    Button(role: .destructive) { removeApp(index) } label: {
                                        Image(systemName: "minus.circle.fill")
                                    }
                                    ImmediateReorderHandle(
                                        coordinateSpace: "appsReorder",
                                        label: "누른 채로 끌어 앱 순서 변경",
                                        onChange: { y in updateDrag(app.editorID, y: y) },
                                        onEnd: { y in endDrag(app.editorID, y: y) }
                                    )
                                }
                                appCard(app)
                                    .overlay {
                                        GeometryReader { geometry in
                                            ReorderTouchSurface(
                                                frame: geometry.frame(in: .named("appsReorder")),
                                                onTap: { openEditor(for: app.editorID) },
                                                onChange: { y in updateDrag(app.editorID, y: y) },
                                                onEnd: { y in endDrag(app.editorID, y: y) }
                                            )
                                        }
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { openEditor(for: app.editorID) }
                            }
                            .contentShape(Rectangle())
                            .reorderFrame(id: "app:\(app.editorID.uuidString)", in: "appsReorder")
                            .opacity(draggedAppID == app.editorID ? 0.001 : 1)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        if let draggedAppID,
           let app = store.source.apps.first(where: { $0.editorID == draggedAppID }),
           let frame = dragFrames["app:\(draggedAppID.uuidString)"],
           validReorderFrame(frame),
           let previewY = safeReorderY(dragFingerY, offset: dragTouchOffset) {
            dragPreview(app)
                .frame(width: frame.width)
                .scaleEffect(1.025)
                .shadow(color: .black.opacity(0.22), radius: 12, y: 8)
                .position(x: frame.midX, y: previewY)
                .allowsHitTesting(false)
                .zIndex(1)
        }
        }
        .background(Color(uiColor: .systemBackground))
        .coordinateSpace(name: "appsReorder")
        .onPreferenceChange(ReorderRowFrames.self) { rowFrameCache.frames = $0 }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showingEditor) {
            if let editorAppID,
               let index = store.source.apps.firstIndex(where: { $0.editorID == editorAppID }) {
                AppEditor(app: $store.source.apps[index])
            }
        }
        .keyboardDismissButton()
    }

    private func appCard(_ app: AltApp) -> some View {
        let tint = sourceTintColor(app.tintColor)
        return HStack(spacing: 14) {
            RemoteImage(url: app.iconURL, systemName: "app", localData: app.iconPreviewData)
                .frame(width: 64, height: 64)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name.isEmpty ? "새 앱" : app.name)
                    .font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(app.bundleIdentifier.isEmpty ? "Bundle ID 입력 필요" : app.bundleIdentifier)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("편집")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(tint, in: Capsule())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.23), in: RoundedRectangle(cornerRadius: 18))
    }

    private func dragPreview(_ app: AltApp) -> some View {
        HStack(spacing: 7) {
            if editing {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.blue)
                    .frame(width: 24, height: 44)
            }
            appCard(app)
        }
    }

    private func removeApp(_ index: Int) {
        let id = store.source.apps[index].bundleIdentifier
        store.source.apps.remove(at: index)
        store.source.featuredApps.removeAll { $0 == id }
    }

    private func openEditor(for id: UUID) {
        guard draggedAppID == nil,
              !(lastDraggedAppID == id && Date().timeIntervalSince(lastDragEndedAt) < 0.5)
        else { return }
        editorAppID = id
        showingEditor = true
    }

    private func moveApp(_ id: UUID, to targetIndex: Int) {
        var apps = store.source.apps
        guard let sourceIndex = apps.firstIndex(where: { $0.editorID == id }),
              apps.indices.contains(targetIndex),
              sourceIndex != targetIndex else { return }
        let moved = apps.remove(at: sourceIndex)
        apps.insert(moved, at: targetIndex)
        withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.85)) { store.source.apps = apps }
    }

    private func updateDrag(_ id: UUID, y: CGFloat) {
        guard y.isFinite else { return }
        let key = "app:\(id.uuidString)"
        if draggedAppID == nil {
            dragFrames = rowFrameCache.frames.filter { validReorderFrame($0.value) }
            guard let frame = dragFrames[key] else { return }
            dragSlotIndices = Dictionary(uniqueKeysWithValues: store.source.apps.enumerated().map { ($0.element.editorID, $0.offset) })
            dragTouchOffset = y - frame.midY
            draggedAppID = id
        }
        guard draggedAppID == id else { return }
        dragFingerY = y
        guard let center = safeReorderY(y, offset: dragTouchOffset) else { return }
        let slots = dragFrames.filter { $0.key.hasPrefix("app:") }.sorted { $0.value.midY < $1.value.midY }
        guard let target = slots.enumerated().min(by: {
            abs($0.element.value.midY - center) < abs($1.element.value.midY - center)
        })?.offset else { return }
        let targetID = UUID(uuidString: String(slots[target].key.dropFirst(4)))
        if let targetID, let slotIndex = dragSlotIndices[targetID] {
            moveApp(id, to: slotIndex)
        }
    }

    private func endDrag(_ id: UUID, y: CGFloat) {
        updateDrag(id, y: y)
        guard draggedAppID == id else { return }
        lastDraggedAppID = id
        lastDragEndedAt = Date()
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86)) { draggedAppID = nil }
        dragFrames = [:]
        dragSlotIndices = [:]
    }
}

private enum AppSheet: String, Identifiable {
    case addVersion, addPrivacy, addEntitlement, packagePicker
    var id: String { rawValue }
}

private enum AppPackageType {
    static let ipa = UTType(filenameExtension: "ipa") ?? UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .data)
    static let adp = UTType(importedAs: "app.altstudio.sourcecreator.adp", conformingTo: .data)
    static let allowed = [ipa, adp]
}

private struct AppPackagePicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: AppPackageType.allowed, asCopy: true)
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
            controller.dismiss(animated: true) { [onPick] in onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

struct AppEditor: View {
    @EnvironmentObject private var store: SourceStore
    @Binding var app: AltApp
    @State private var sheet: AppSheet?
    @State private var versionDraft = AltVersion()
    @State private var versionSearch = ""
    @State private var showAllVersions = false
    @State private var showAllPrivacy = false
    @State private var editingVersions = false
    @State private var selectedFileName: String?
    @State private var scanningPackage = false
    @State private var newPrivacyKey = ""
    @State private var newPrivacyValue = ""
    @State private var newEntitlement = ""
    private let categories = ["developer", "entertainment", "games", "lifestyle", "other", "photo-video", "social", "utilities"]

    private func categoryLabel(_ value: String) -> String {
        switch value {
        case "developer": "개발자 도구"
        case "entertainment": "엔터테인먼트"
        case "games": "게임"
        case "lifestyle": "라이프스타일"
        case "other": "기타"
        case "photo-video": "사진 및 비디오"
        case "social": "소셜 네트워킹"
        case "utilities": "유틸리티"
        default: value
        }
    }

    private var matchingVersions: [Int] {
        app.versions.indices.filter { index in
            versionSearch.isEmpty || app.versions[index].version.localizedCaseInsensitiveContains(versionSearch)
                || app.versions[index].localizedDescription.localizedCaseInsensitiveContains(versionSearch)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SourceImageField(title: "아이콘", url: $app.iconURL, isHeader: false,
                                 importedPreview: app.iconPreviewData,
                                 clearImportedPreview: { app.iconPreviewData = nil })
                AppInputField(title: "앱 이름", text: $app.name)
                AppInputField(title: "번들 ID", text: $app.bundleIdentifier, identifier: true)
                AppInputField(title: "마켓플레이스 ID (선택 사항)", text: $app.marketplaceID)
                Text("마켓플레이스 ID는 현재 JSON 내보내기 형식에서 제외됩니다.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, -18)
                SourceTextField(title: "틴트 컬러", text: $app.tintColor) {
                    ColorPicker("틴트 컬러", selection: Binding(
                        get: { sourceTintColor(app.tintColor) },
                        set: { app.tintColor = sourceHexColor($0) }
                    ), supportsOpacity: false).labelsHidden()
                }
                AppInputField(title: "개발자 이름", text: $app.developerName)
                AppInputField(title: "앱 부제목 (선택 사항)", text: $app.subtitle)
                AppInputField(title: "앱 설명 (선택 사항)", text: $app.localizedDescription, multiline: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("카테고리 (선택 사항)").font(.subheadline)
                    Picker("카테고리", selection: $app.category) {
                        ForEach(categories, id: \.self) { Text(categoryLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                screenshotsSection
                versionsSection
                privacySection
                entitlementsSection
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("앱 편집")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { editorToolbar }
        .overlay {
            if scanningPackage {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("앱 파일 분석 중…").font(.headline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .sheet(item: $sheet) { selected in
            switch selected {
            case .addVersion:
                AddVersionSheet(version: $versionDraft, fileName: selectedFileName) {
                    app.versions.insert(versionDraft, at: 0)
                    sheet = nil
                }
            case .addPrivacy:
                addPrivacySheet
            case .addEntitlement:
                addEntitlementSheet
            case .packagePicker:
                AppPackagePicker(
                    onPick: { url in scanSelectedFile(url) },
                    onCancel: { sheet = nil }
                )
            }
        }
        .onChange(of: app.bundleIdentifier) { oldID, newID in
            if !oldID.isEmpty, let index = store.source.featuredApps.firstIndex(of: oldID) {
                if newID.isEmpty { store.source.featuredApps.remove(at: index) }
                else { store.source.featuredApps[index] = newID }
            }
        }
        .keyboardDismissButton()
    }

    private var editorToolbar: some View {
        HStack {
            Button { toggleFeatured() } label: {
                Image(systemName: store.source.featuredApps.contains(app.bundleIdentifier) ? "star.fill" : "star")
                    .foregroundStyle(.orange).font(.title2)
            }
            .accessibilityLabel("대표 앱 선택")
            Spacer()
            Button { openPackagePicker() } label: { Label("IPA/ADP 파일 선택", systemImage: "doc") }
                .font(.subheadline)
            Menu {
                Button("앱 복제", systemImage: "plus.square.on.square") {
                    var copy = app
                    copy.editorID = UUID()
                    copy.name += " 복사본"
                    copy.bundleIdentifier = ""
                    store.source.apps.append(copy)
                }
            } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("더 보기")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
    }

    private var screenshotsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("스크린샷").font(.subheadline)
            VStack(spacing: 0) {
                screenshotRow("iPhone", count: app.screenshots.iphone.count)
                screenshotRow("iPad", count: app.screenshots.ipad.count)
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func screenshotRow(_ title: String, count: Int) -> some View {
        NavigationLink {
            ScreenshotsEditor(screenshots: $app.screenshots)
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(minWidth: 23, minHeight: 23)
                    .background(sourceTintColor(app.tintColor), in: Circle())
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("버전").font(.subheadline)
                Spacer()
                Menu {
                    Button("직접 추가", systemImage: "pencil") {
                        versionDraft = AltVersion()
                        selectedFileName = nil
                        sheet = .addVersion
                    }
                    Button("IPA/ADP 파일 선택", systemImage: "doc") { openPackagePicker() }
                } label: { Label("추가", systemImage: "plus") }
                Button { editingVersions.toggle() } label: {
                    Label(editingVersions ? "완료" : "편집", systemImage: "square.and.pencil")
                }
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("검색", text: $versionSearch,
                              prompt: Text("검색").foregroundColor(Color.primary.opacity(0.7)))
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(.primary)
                }
                .padding(11)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 11))
                .padding(12)

                if app.versions.isEmpty {
                    Text("추가된 버전이 없습니다.").foregroundStyle(.secondary).padding(16)
                } else if matchingVersions.isEmpty {
                    Text("검색 결과가 없습니다.").foregroundStyle(.secondary).padding(16)
                } else {
                    ForEach(Array(matchingVersions.prefix(showAllVersions ? Int.max : 4)), id: \.self) { index in
                        versionRow(index)
                    }
                    if matchingVersions.count > 4 {
                        Button {
                            showAllVersions.toggle()
                        } label: {
                            Text(showAllVersions ? "접기" : "모두 보기")
                            Text("\(matchingVersions.count)")
                                .font(.caption.weight(.bold)).foregroundStyle(.white)
                                .padding(5)
                                .background(sourceTintColor(app.tintColor), in: Circle())
                        }
                        .foregroundStyle(sourceTintColor(app.tintColor))
                        .padding(14)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func versionRow(_ index: Int) -> some View {
        let version = app.versions[index]
        return HStack(spacing: 10) {
            Circle().fill(.gray.opacity(0.45)).frame(width: 9, height: 9)
            NavigationLink {
                VersionEditor(version: $app.versions[index])
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(version.version.isEmpty ? "새 버전" : version.version)
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(sourceTintColor(app.tintColor), in: Capsule())
                        Spacer()
                        Text(appVersionDate(version.date)).font(.caption2).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(version.localizedDescription.isEmpty ? version.downloadURL : version.localizedDescription)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .buttonStyle(.plain)
            if editingVersions {
                Button(role: .destructive) { app.versions.remove(at: index) } label: {
                    Image(systemName: "minus.circle.fill")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var privacySection: some View {
        let entries = app.appPermissions.privacy.keys.sorted()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("개인정보 사용 설명").font(.subheadline)
                Spacer()
                Button {
                    newPrivacyKey = ""
                    newPrivacyValue = ""
                    sheet = .addPrivacy
                } label: { Label("추가", systemImage: "plus") }
                NavigationLink { PermissionsEditor(permissions: $app.appPermissions) } label: {
                    Label("편집", systemImage: "square.and.pencil")
                }
            }
            VStack(spacing: 0) {
                if entries.isEmpty {
                    Text("등록된 개인정보 사용 설명이 없습니다.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                } else {
                    ForEach(Array(entries.prefix(showAllPrivacy ? Int.max : 4)), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(key).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                            Text(app.appPermissions.privacy[key] ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        if key != entries.last { Divider().padding(.leading, 14) }
                    }
                    if entries.count > 4 {
                        Button(showAllPrivacy ? "접기" : "모두 보기 \(entries.count)개") {
                            showAllPrivacy.toggle()
                        }
                        .foregroundStyle(sourceTintColor(app.tintColor)).padding(14)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var entitlementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("앱 권한 설정").font(.subheadline)
                Spacer()
                Button { newEntitlement = ""; sheet = .addEntitlement } label: { Label("추가", systemImage: "plus") }
                NavigationLink { PermissionsEditor(permissions: $app.appPermissions) } label: {
                    Label("편집", systemImage: "square.and.pencil")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if app.appPermissions.entitlements.isEmpty {
                    Text("등록된 앱 권한이 없습니다.").foregroundStyle(.secondary)
                } else {
                    ForEach(app.appPermissions.entitlements, id: \.self) { item in
                        Text(item).font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var addPrivacySheet: some View {
        NavigationStack {
            Form {
                TextField("권한 키", text: $newPrivacyKey).textInputAutocapitalization(.never)
                TextField("설명", text: $newPrivacyValue, axis: .vertical)
            }
            .navigationTitle("개인정보 사용 설명 추가")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { sheet = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") {
                        app.appPermissions.privacy[newPrivacyKey] = newPrivacyValue
                        sheet = nil
                    }
                    .disabled(newPrivacyKey.isEmpty)
                }
            }
            .keyboardDismissButton()
        }
    }

    private var addEntitlementSheet: some View {
        NavigationStack {
            Form { TextField("앱 권한 항목", text: $newEntitlement).textInputAutocapitalization(.never) }
                .navigationTitle("앱 권한 추가")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { sheet = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("추가") {
                            app.appPermissions.entitlements.append(newEntitlement)
                            sheet = nil
                        }
                        .disabled(newEntitlement.isEmpty)
                    }
                }
                .keyboardDismissButton()
        }
    }

    private func toggleFeatured() {
        let id = app.bundleIdentifier
        guard !id.isEmpty else { store.message = "Bundle ID를 먼저 입력하세요."; return }
        if let index = store.source.featuredApps.firstIndex(of: id) {
            store.source.featuredApps.remove(at: index)
        } else if store.source.featuredApps.count < 5 {
            store.source.featuredApps.append(id)
        } else {
            store.message = "대표 앱은 최대 5개까지 선택할 수 있습니다."
        }
    }

    private func openPackagePicker() {
        selectedFileName = nil
        sheet = .packagePicker
    }

    private func scanSelectedFile(_ url: URL) {
        sheet = nil
        scanningPackage = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AppPackageScanner.scan(url) }
            DispatchQueue.main.async {
                scanningPackage = false
                switch result {
                case .success(let package):
                    if !package.name.isEmpty { app.name = package.name }
                    if !package.bundleIdentifier.isEmpty { app.bundleIdentifier = package.bundleIdentifier }
                    if let icon = package.iconData {
                        app.iconPreviewData = icon
                        app.iconURL = ""
                    }
                    versionDraft = AltVersion()
                    versionDraft.version = package.version
                    versionDraft.buildVersion = package.buildVersion
                    versionDraft.minOSVersion = package.minOSVersion
                    versionDraft.size = package.size
                    selectedFileName = package.fileName
                    sheet = .addVersion
                case .failure(let error):
                    store.message = "앱 파일을 분석하지 못했습니다: \(error.localizedDescription)"
                }
            }
        }
    }
}

private func appVersionDate(_ value: String) -> String {
    let components = String(value.prefix(10)).split(separator: "-")
    guard components.count == 3 else { return value }
    return "\(components[0])년 \(Int(components[1]) ?? 0)월 \(Int(components[2]) ?? 0)일"
}

func appVersionPickerDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) { return date }
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: String(value.prefix(10))) ?? .now
}

func appVersionISODate(_ value: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: value)
}

struct AppInputField: View {
    let title: String
    @Binding var text: String
    var placeholder = ""
    var multiline = false
    var identifier = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if title.hasSuffix(" *") {
                HStack(spacing: 2) {
                    Text(String(title.dropLast(2)))
                    Text("*").foregroundStyle(.red)
                }
                .font(.subheadline)
            } else {
                Text(title).font(.subheadline)
            }
            HStack(alignment: multiline ? .top : .center, spacing: 8) {
                Group {
                    if multiline {
                        TextField(placeholder, text: $text, axis: .vertical).lineLimit(5...8)
                    } else {
                        TextField(placeholder, text: $text)
                            .textInputAutocapitalization(identifier ? .never : .sentences)
                            .autocorrectionDisabled(identifier)
                    }
                }
                .frame(maxWidth: .infinity)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("\(title) 지우기")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, multiline ? 12 : 0)
            .frame(minHeight: multiline ? 115 : 42)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct AddVersionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var version: AltVersion
    let fileName: String?
    let addAction: () -> Void
    @State private var sizeText = ""
    @State private var sizeUnit = "MB"
    private let units = ["bytes", "KB", "MB", "GB"]

    private var canAdd: Bool {
        !version.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !version.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && version.size > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let fileName {
                        Text("\(fileName)의 앱 정보와 크기를 읽었습니다. 배포용 다운로드 URL은 직접 입력해 주세요.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    AppInputField(title: "IPA/ADP 다운로드 URL *", text: $version.downloadURL,
                                  placeholder: "https://site.com/someapp.ipa", identifier: true)
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("파일 크기 *").font(.subheadline)
                            TextField("0.0", text: $sizeText)
                                .keyboardType(.decimalPad)
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
                    AppInputField(title: "버전 번호 *", text: $version.version, placeholder: "1.0.0")
                    AppInputField(title: "빌드 번호 (선택 사항)", text: $version.buildVersion, placeholder: "123")
                    Text("빌드 번호는 현재 JSON 내보내기 형식에서 제외됩니다.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, -18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("출시일 *").font(.subheadline)
                        DatePicker("출시일", selection: dateBinding, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    AppInputField(title: "변경 사항 (선택 사항)", text: $version.localizedDescription,
                                  placeholder: "변경 사항을 입력하세요", multiline: true)
                    AppInputField(title: "최소 iOS 버전 (선택 사항)", text: $version.minOSVersion, placeholder: "16.1")
                }
                .frame(maxWidth: 760)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("앱 버전 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: addAction) {
                    Text("추가").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
                .padding(16)
                .background(Color(uiColor: .systemBackground))
            }
            .onAppear {
                if version.size > 0 {
                    if fileName != nil { sizeUnit = "bytes"; sizeText = String(version.size) }
                    else { sizeText = String(Double(version.size) / 1_000_000) }
                }
            }
            .onChange(of: sizeText) { _, _ in updateSize() }
            .onChange(of: sizeUnit) { _, _ in
                if version.size > 0 {
                    sizeText = sizeUnit == "bytes"
                        ? String(version.size)
                        : String(Double(version.size) / sizeMultiplier)
                }
            }
            .keyboardDismissButton()
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { appVersionPickerDate(version.date) },
                set: { version.date = appVersionISODate($0) })
    }

    private func updateSize() {
        version.size = Int((Double(sizeText) ?? 0) * sizeMultiplier)
    }

    private var sizeMultiplier: Double {
        switch sizeUnit {
        case "KB": return 1_000
        case "MB": return 1_000_000
        case "GB": return 1_000_000_000
        default: return 1
        }
    }
}
