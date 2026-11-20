import SwiftUI
import UniformTypeIdentifiers
import QuartzCore

final class ReorderDiagnostics: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var report = ""

    private final class Gesture {
        let area: String
        let input: String
        let started: CFTimeInterval
        var frameGaps: [Double] = []
        var updateCount = 0
        var updateTotal = 0.0
        var updateMax = 0.0
        var reorderCount = 0
        var reorderTotal = 0.0
        var reorderMax = 0.0
        var autoScrollCount = 0
        var finishTime = 0.0
        var duration = 0.0
        var slowEvents: [String] = []

        init(area: String, input: String, started: CFTimeInterval) {
            self.area = area
            self.input = input
            self.started = started
        }
    }

    private var startedAt: Date?
    private var gestures: [Gesture] = []
    private var active: Gesture?
    private var displayLink: CADisplayLink?
    private var previousFrameTime: CFTimeInterval?

    func start() {
        displayLink?.invalidate()
        gestures.removeAll()
        active = nil
        previousFrameTime = nil
        startedAt = Date()
        report = ""
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        finishGesture()
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false
        report = makeReport()
    }

    func beginGesture(area: String, input: String) {
        guard isRunning, active == nil else { return }
        previousFrameTime = nil
        active = Gesture(area: area, input: input, started: CACurrentMediaTime())
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func recordUpdate(duration: Double, autoScrolling: Bool) {
        guard isRunning, let gesture = active else { return }
        gesture.updateCount += 1
        gesture.updateTotal += duration
        gesture.updateMax = max(gesture.updateMax, duration)
        if autoScrolling { gesture.autoScrollCount += 1 }
        recordSlowEvent("드래그 처리", duration: duration, threshold: 0.010, in: gesture)
    }

    func recordReorder(duration: Double) {
        guard isRunning, let gesture = active else { return }
        gesture.reorderCount += 1
        gesture.reorderTotal += duration
        gesture.reorderMax = max(gesture.reorderMax, duration)
        recordSlowEvent("순서 변경", duration: duration, threshold: 0.010, in: gesture)
    }

    func recordFinish(duration: Double) {
        guard isRunning, let gesture = active else { return }
        gesture.finishTime = duration
        recordSlowEvent("종료/저장", duration: duration, threshold: 0.010, in: gesture)
    }

    func finishGesture() {
        guard isRunning, let gesture = active else { return }
        gesture.duration = CACurrentMediaTime() - gesture.started
        gestures.append(gesture)
        active = nil
        previousFrameTime = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        guard let gesture = active else { return }
        if let previousFrameTime {
            let gap = link.timestamp - previousFrameTime
            if gap > 0, gap < 10 {
                gesture.frameGaps.append(gap)
                if gap > 0.025, gesture.slowEvents.count < 24 {
                    let elapsed = max(0, link.timestamp - gesture.started)
                    gesture.slowEvents.append("\(String(format: "%.2f", elapsed))초 화면 갱신 간격 \(ms(gap))")
                }
            }
        }
        previousFrameTime = link.timestamp
    }

    private func makeReport() -> String {
        let refresh = max(60, UIScreen.main.maximumFramesPerSecond)
        let budget = 1.0 / Double(refresh)
        var lines = [
            "Source Editor 드래그 진단",
            "측정 시작: \(startedAt?.formatted(date: .numeric, time: .standard) ?? "-")",
            "기기: \(UIDevice.current.model) · 화면 최대 \(refresh)Hz",
            "제스처 \(gestures.count)회",
            ""
        ]
        if gestures.isEmpty {
            lines.append("측정된 순서 변경 제스처가 없습니다. 소스 또는 앱 탭에서 앱을 끌어 옮겨 주세요.")
        }
        for (index, gesture) in gestures.enumerated() {
            let gaps = gesture.frameGaps.sorted()
            let averageFPS = gaps.isEmpty ? 0 : Double(gaps.count) / gaps.reduce(0, +)
            let p95 = gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))]
            let slow = gaps.filter { $0 > budget * 1.5 }.count
            let severe = gaps.filter { $0 > budget * 2.5 }.count
            lines += [
                "[\(index + 1)] \(gesture.area) · \(gesture.input) · \(String(format: "%.2f", gesture.duration))초",
                "화면: 평균 \(String(format: "%.1f", averageFPS))fps, 프레임 간격 p95 \(ms(p95)), 최대 \(ms(gaps.last ?? 0))",
                "지연 프레임: \(slow)/\(gaps.count) (목표 간격의 1.5배 초과), 심한 지연 \(severe)회 (2.5배 초과)",
                "드래그 처리: \(gesture.updateCount)회, 평균 \(ms(gesture.updateCount == 0 ? 0 : gesture.updateTotal / Double(gesture.updateCount))), 최대 \(ms(gesture.updateMax))",
                "순서 변경: \(gesture.reorderCount)회, 평균 \(ms(gesture.reorderCount == 0 ? 0 : gesture.reorderTotal / Double(gesture.reorderCount))), 최대 \(ms(gesture.reorderMax))",
                "자동 스크롤 중 처리: \(gesture.autoScrollCount)회 · 종료/저장: \(ms(gesture.finishTime))"
            ]
            if !gesture.slowEvents.isEmpty {
                lines.append("지연 기록 (처음 \(gesture.slowEvents.count)개):")
                lines += gesture.slowEvents.map { "  · \($0)" }
            }
            if gesture.reorderMax > budget {
                lines.append("가능성: 순서 변경 처리 시간이 화면 갱신 간격을 넘었습니다.")
            } else if gesture.updateMax > budget {
                lines.append("가능성: 드래그 위치 계산이 화면 갱신 간격을 넘었습니다.")
            } else if severe > 0 {
                lines.append("가능성: 측정된 드래그 처리 밖에서 메인 스레드 또는 화면 렌더링이 지연됐습니다.")
            } else {
                lines.append("측정 구간에서 뚜렷한 지연 원인은 확인되지 않았습니다.")
            }
            lines.append("")
        }
        lines.append("참고: FPS는 화면 갱신 콜백 간격으로 추정한 값입니다. GPU 작업이나 시스템 부하의 정확한 원인은 Instruments로 확인해야 합니다.")
        return lines.joined(separator: "\n")
    }

    private func ms(_ seconds: Double) -> String {
        String(format: "%.1fms", seconds * 1_000)
    }

    private func recordSlowEvent(_ name: String, duration: Double, threshold: Double, in gesture: Gesture) {
        guard duration > threshold, gesture.slowEvents.count < 24 else { return }
        let elapsed = max(0, CACurrentMediaTime() - gesture.started)
        gesture.slowEvents.append("\(String(format: "%.2f", elapsed))초 \(name) \(ms(duration))")
    }
}

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

enum ReorderMotion {
    static let lift = Animation.interactiveSpring(response: 0.22, dampingFraction: 0.92)
    static let shift = Animation.interactiveSpring(response: 0.22, dampingFraction: 0.96, blendDuration: 0.06)
    static let drop = Animation.interactiveSpring(response: 0.24, dampingFraction: 0.96)
}

final class ReorderAutoScroller: NSObject {
    weak var scrollView: UIScrollView?
    private var displayLink: CADisplayLink?
    private var fingerY: CGFloat = 0
    private var bottomBoundary: CGFloat?
    private var scrollVelocity: CGFloat = 0
    private(set) var isAutoScrolling = false

    func attach(_ scrollView: UIScrollView) { self.scrollView = scrollView }

    func start(at y: CGFloat) {
        fingerY = y
        bottomBoundary = scrollView.map { visibleBottom(of: $0) }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(scrollIfNeeded(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func update(to y: CGFloat) { fingerY = y }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        bottomBoundary = nil
        scrollVelocity = 0
        isAutoScrolling = false
    }

    @objc private func scrollIfNeeded(_ link: CADisplayLink) {
        guard let scrollView, fingerY.isFinite else { return }
        let height = scrollView.bounds.height
        guard height > 0, height.isFinite else { return }
        let edge = min(90, height * 0.18)
        let strength: CGFloat
        if fingerY < edge { strength = -min(1, (edge - fingerY) / edge) }
        else {
            let bottom = bottomBoundary ?? visibleBottom(of: scrollView)
            let start = max(edge + 40, bottom - 150)
            guard fingerY > start else {
                scrollVelocity = 0
                isAutoScrolling = false
                return
            }
            strength = max(0.3, min(1, (fingerY - start) / max(1, bottom - start)))
        }
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height - height + scrollView.adjustedContentInset.bottom)
        let frameDuration = min(max(link.targetTimestamp - link.timestamp, 1.0 / 120), 1.0 / 30)
        let speed: CGFloat = strength > 0 ? 1_500 : 900
        let targetVelocity = strength * speed
        scrollVelocity += (targetVelocity - scrollVelocity) * min(1, frameDuration * 18)
        let next = min(max(scrollView.contentOffset.y + scrollVelocity * frameDuration, minY), maxY)
        guard next.isFinite, abs(next - scrollView.contentOffset.y) > 0.1 else {
            isAutoScrolling = false
            return
        }
        isAutoScrolling = true
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: next), animated: false)
    }

    private func visibleBottom(of scrollView: UIScrollView) -> CGFloat {
        let height = scrollView.bounds.height
        let fallbackInset: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 100 : 24
        var bottom = height - max(scrollView.safeAreaInsets.bottom, fallbackInset)
        if let window = scrollView.window, let tabTop = tabBarTop(in: window, window: window) {
            let viewportTop = scrollView.convert(scrollView.bounds, to: window).minY
            let tabY = tabTop - viewportTop
            if tabY.isFinite && tabY > 0 && tabY < height { bottom = min(bottom, tabY) }
        }
        return max(height * 0.4, bottom)
    }

    private func tabBarTop(in view: UIView, window: UIWindow) -> CGFloat? {
        var top: CGFloat?
        if let tabBar = view as? UITabBar, !tabBar.isHidden, tabBar.alpha > 0.1 {
            let frame = tabBar.convert(tabBar.bounds, to: window)
            if frame.width > 0, frame.height > 0, frame.intersects(window.bounds) { top = frame.minY }
        }
        for child in view.subviews {
            if let candidate = tabBarTop(in: child, window: window) {
                top = min(top ?? candidate, candidate)
            }
        }
        return top
    }
}

struct ReorderScrollLocator: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolve()
    }

    final class ProbeView: UIView {
        var onResolve: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.resolve() }
        }

        func resolve() {
            var ancestor = superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView {
                    onResolve?(scroll)
                    return
                }
                ancestor = current.superview
            }
        }
    }
}

struct ReorderTouchSurface: UIViewRepresentable {
    let frame: CGRect
    let onTap: (() -> Void)?
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        if onTap != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
            tap.delegate = context.coordinator
            tap.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)
        }
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

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.restoreScrolling()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var frame: CGRect = .zero
        var onTap: (() -> Void)?
        var onChange: ((CGFloat) -> Void)?
        var onEnd: ((CGFloat) -> Void)?
        private weak var scrollView: UIScrollView?
        private var scrollWasEnabled = true
        private var startWindowY: CGFloat?
        private var startFingerY: CGFloat?
        private var lastFingerY: CGFloat?

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { onTap?() }
        }

        @objc func pressed(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            if gesture.state == .began {
                guard validReorderFrame(frame), let window = view.window else { return }
                let fingerY = frame.minY + gesture.location(in: view).y
                let windowY = gesture.location(in: window).y
                guard fingerY.isFinite, windowY.isFinite else { return }
                startFingerY = fingerY
                startWindowY = windowY
                lastFingerY = fingerY
                var ancestor: UIView? = view.superview
                while let current = ancestor {
                    if let scroll = current as? UIScrollView {
                        scrollView = scroll
                        scrollWasEnabled = scroll.isScrollEnabled
                        scroll.isScrollEnabled = false
                        break
                    }
                    ancestor = current.superview
                }
                onChange?(fingerY)
                return
            }
            defer {
                if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                    restoreScrolling()
                }
            }
            guard let startFingerY, let startWindowY else { return }
            let y = view.window.map { startFingerY + gesture.location(in: $0).y - startWindowY }
                ?? lastFingerY ?? startFingerY
            guard y.isFinite else { return }
            lastFingerY = y
            switch gesture.state {
            case .changed: onChange?(y)
            case .ended, .cancelled: onEnd?(y)
            default: break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func restoreScrolling() {
            if let scrollView { scrollView.isScrollEnabled = scrollWasEnabled }
            scrollView = nil
            startWindowY = nil
            startFingerY = nil
            lastFingerY = nil
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
}

final class ReorderFrameCache {
    var frames: [String: CGRect] = [:]
}

final class ReorderDragPosition: ObservableObject {
    @Published var fingerY: CGFloat = 0

    func update(to y: CGFloat) {
        if abs(fingerY - y) > 0.25 { fingerY = y }
    }
}

struct ReorderFloatingPreview<Content: View>: View {
    @ObservedObject var position: ReorderDragPosition
    let frame: CGRect
    let touchOffset: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let y = safeReorderY(position.fingerY, offset: touchOffset) {
            content().position(x: frame.midX, y: y)
        }
    }
}

struct EditorListActionIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: systemName == "square.and.pencil" ? 30 : 26,
                   height: systemName == "square.and.pencil" ? 30 : 26)
            .offset(y: systemName == "square.and.pencil" ? -3 : 0)
            .frame(width: 36, height: 36)
    }
}

struct AppsScreen: View {
    @EnvironmentObject private var store: SourceStore
    @EnvironmentObject private var diagnostics: ReorderDiagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var editing = false
    @State private var editorAppID: UUID?
    @State private var showingEditor = false
    @State private var lastDraggedAppID: UUID?
    @State private var lastDragEndedAt: Date = .distantPast
    @State private var rowFrameCache = ReorderFrameCache()
    @State private var dragFrames: [String: CGRect] = [:]
    @State private var autoScroller = ReorderAutoScroller()
    @State private var draggedAppID: UUID?
    @State private var dragPosition = ReorderDragPosition()
    @State private var dragTouchOffset: CGFloat = 0
    @State private var previewAppIDs: [UUID]?

    private var orderedApps: [SourceApp] {
        guard let previewAppIDs else { return store.source.apps }
        let appsByID = Dictionary(uniqueKeysWithValues: store.source.apps.map { ($0.editorID, $0) })
        return previewAppIDs.compactMap { appsByID[$0] }
    }

    private var visibleApps: [SourceApp] {
        orderedApps.filter { app in
            return search.isEmpty || app.name.localizedCaseInsensitiveContains(search)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
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
                        let app = SourceApp()
                        store.source.apps.append(app)
                        openEditor(for: app.editorID)
                    } label: {
                        EditorListActionIcon(systemName: "plus.circle")
                    }
                    .accessibilityLabel("앱 추가")
                    Button { editing.toggle() } label: {
                        EditorListActionIcon(systemName: editing ? "checkmark.circle" : "square.and.pencil")
                    }
                    .accessibilityLabel(editing ? "편집 완료" : "앱 목록 편집")
                }

                if store.source.apps.isEmpty {
                    ContentUnavailableView("앱이 없습니다", systemImage: "apps.iphone", description: Text("앱을 추가해 주세요."))
                } else if visibleApps.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    VStack(spacing: 10) {
                        ForEach(visibleApps, id: \.editorID) { app in
                            HStack(spacing: 7) {
                                if editing {
                                    Button(role: .destructive) { removeApp(app.editorID) } label: {
                                        Image(systemName: "minus.circle.fill")
                                    }
                                    ImmediateReorderHandle(
                                        coordinateSpace: "appsReorder",
                                        label: "누른 채로 끌어 앱 순서 변경",
                                        onChange: { y in updateDrag(app.editorID, y: y, input: "3줄 손잡이") },
                                        onEnd: { y in endDrag(app.editorID, y: y) }
                                    )
                                }
                                appCard(app)
                                    .overlay {
                                        GeometryReader { geometry in
                                            ReorderTouchSurface(
                                                frame: geometry.frame(in: .named("appsReorder")),
                                                onTap: { openEditor(for: app.editorID) },
                                                onChange: { y in updateDrag(app.editorID, y: y, input: "롱프레스") },
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
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
            .background(ReorderScrollLocator { autoScroller.attach($0) })
        }
        .overlay(alignment: .topLeading) {
        if let draggedAppID,
           let app = store.source.apps.first(where: { $0.editorID == draggedAppID }),
           let frame = dragFrames["app:\(draggedAppID.uuidString)"],
           validReorderFrame(frame) {
            ReorderFloatingPreview(position: dragPosition, frame: frame, touchOffset: dragTouchOffset) {
                dragPreview(app)
                    .frame(width: frame.width)
                    .scaleEffect(1.025)
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 8)
            }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .allowsHitTesting(false)
                .zIndex(1)
        }
        }
        .background(Color(uiColor: .systemBackground))
        .coordinateSpace(name: "appsReorder")
        .onPreferenceChange(ReorderRowFrames.self) { frames in
            rowFrameCache.frames = frames
            if let draggedAppID, autoScroller.isAutoScrolling {
                DispatchQueue.main.async {
                    guard self.draggedAppID == draggedAppID, self.autoScroller.isAutoScrolling else { return }
                    updateDrag(draggedAppID, y: dragPosition.fingerY)
                }
            }
        }
        .onDisappear {
            autoScroller.stop()
            commitPreviewApps()
            draggedAppID = nil
            diagnostics.finishGesture()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                autoScroller.stop()
                commitPreviewApps()
                draggedAppID = nil
                diagnostics.finishGesture()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showingEditor) {
            if let editorAppID,
               let index = store.source.apps.firstIndex(where: { $0.editorID == editorAppID }) {
                AppEditor(app: $store.source.apps[index])
            }
        }
        .keyboardDismissButton()
    }

    private func appCard(_ app: SourceApp) -> some View {
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

    private func dragPreview(_ app: SourceApp) -> some View {
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

    private func removeApp(_ editorID: UUID) {
        guard let index = store.source.apps.firstIndex(where: { $0.editorID == editorID }) else { return }
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
        guard var ids = previewAppIDs else { return }
        guard let sourceIndex = ids.firstIndex(of: id),
              ids.indices.contains(targetIndex),
              sourceIndex != targetIndex else { return }
        ids.remove(at: sourceIndex)
        ids.insert(id, at: targetIndex)
        let started = CACurrentMediaTime()
        withAnimation(ReorderMotion.shift) { previewAppIDs = ids }
        diagnostics.recordReorder(duration: CACurrentMediaTime() - started)
    }

    private func commitPreviewApps() {
        guard let previewAppIDs else { return }
        if previewAppIDs != store.source.apps.map(\.editorID) {
            store.reorderApps(orderedApps)
            store.finishReorder()
        }
        self.previewAppIDs = nil
    }

    private func updateDrag(_ id: UUID, y: CGFloat, input: String = "자동 스크롤") {
        guard y.isFinite else { return }
        let started = CACurrentMediaTime()
        defer { diagnostics.recordUpdate(duration: CACurrentMediaTime() - started, autoScrolling: autoScroller.isAutoScrolling) }
        let key = "app:\(id.uuidString)"
        if draggedAppID == nil {
            dragFrames = rowFrameCache.frames.filter { validReorderFrame($0.value) }
            guard let frame = dragFrames[key] else { return }
            diagnostics.beginGesture(area: "앱 목록", input: input)
            previewAppIDs = store.source.apps.map(\.editorID)
            dragTouchOffset = y - frame.midY
            dragPosition.update(to: y)
            withAnimation(ReorderMotion.lift) { draggedAppID = id }
            autoScroller.start(at: y)
        }
        guard draggedAppID == id else { return }
        dragPosition.update(to: y)
        autoScroller.update(to: y)
        guard let center = safeReorderY(y, offset: dragTouchOffset) else { return }
        let slots = rowFrameCache.frames.filter {
            $0.key.hasPrefix("app:") && validReorderFrame($0.value)
        }.sorted { $0.value.midY < $1.value.midY }
        guard let target = slots.enumerated().min(by: {
            abs($0.element.value.midY - center) < abs($1.element.value.midY - center)
        })?.offset else { return }
        let targetID = UUID(uuidString: String(slots[target].key.dropFirst(4)))
        if let targetID,
           let slotIndex = previewAppIDs?.firstIndex(of: targetID) {
            moveApp(id, to: slotIndex)
        }
    }

    private func endDrag(_ id: UUID, y: CGFloat) {
        updateDrag(id, y: y)
        guard draggedAppID == id else { return }
        lastDraggedAppID = id
        lastDragEndedAt = Date()
        autoScroller.stop()
        withAnimation(ReorderMotion.drop) { draggedAppID = nil }
        dragFrames = [:]
        let started = CACurrentMediaTime()
        commitPreviewApps()
        diagnostics.recordFinish(duration: CACurrentMediaTime() - started)
        diagnostics.finishGesture()
    }
}

private enum AppSheet: String, Identifiable {
    case addVersion, addPrivacy, addEntitlement, packagePicker
    var id: String { rawValue }
}

private enum AppPackageType {
    static let ipa = UTType(filenameExtension: "ipa") ?? UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .data)
    static let adp = UTType(importedAs: "app.sourceeditor.adp", conformingTo: .data)
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
    @Binding var app: SourceApp
    @State private var sheet: AppSheet?
    @State private var versionDraft = SourceVersion()
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
                        versionDraft = SourceVersion()
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
                    versionDraft = SourceVersion()
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
    @Binding var version: SourceVersion
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
                            .environment(\.locale, Locale(identifier: "ko_KR"))
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
