import SwiftUI
import UIKit
import ImageIO

struct ImageFramingRequest: Identifiable {
    let id = UUID()
    let image: UIImage

    static func prepare(_ data: Data) async throws -> ImageFramingRequest {
        guard !data.isEmpty, data.count <= 100_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else { throw FramingError.unreadable }
        return ImageFramingRequest(image: UIImage(cgImage: image))
    }
}

enum ImageFrameProfile: Equatable {
    case sourceIcon, appIcon, header, poster, screenshot

    func outputSize(for image: UIImage) -> CGSize {
        switch self {
        case .sourceIcon, .appIcon: return CGSize(width: 1024, height: 1024)
        case .header, .poster: return CGSize(width: 1500, height: 900)
        case .screenshot:
            let limit: CGFloat = 4096
            let scale = min(1, limit / max(image.size.width, image.size.height))
            return CGSize(width: max(1, (image.size.width * scale).rounded()),
                          height: max(1, (image.size.height * scale).rounded()))
        }
    }
}

private enum FramingError: LocalizedError {
    case unreadable
    var errorDescription: String? { "이미지를 읽지 못했거나 파일이 너무 큽니다." }
}

/// All positions are relative to a 4:3 workspace so preview and PNG export agree.
struct ImageFramingEditor: View {
    let image: UIImage
    let profile: ImageFrameProfile
    let onCancel: () -> Void
    let onApply: (Data) -> Void
    @State private var zoom: CGFloat = 1
    @State private var position: CGSize = .zero
    @State private var cropCenter = CGPoint(x: 0.5, y: 0.5)
    @State private var cropWidth: CGFloat?
    @State private var resizeStart: CGRect?
    @State private var renderFailed = false
    @GestureState private var imageDrag: CGSize = .zero
    @GestureState private var cropDrag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    private var output: CGSize { profile.outputSize(for: image) }
    private var ratio: CGFloat { output.width / output.height }
    private var paddingColor: UIColor { .white.withAlphaComponent(0.5) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    let width = max(1, min(720, min(geometry.size.width, geometry.size.height * 4 / 3)))
                    canvas(CGSize(width: width, height: width * 3 / 4))
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                Text("사진을 끌어 위치를 바꾸고 두 손가락으로 확대·축소하세요. 파란 테두리를 끌어 자를 위치를, 모서리를 끌어 프레임 크기를 조정하세요.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("적용한 이미지만 Cloudinary에 공개 업로드됩니다. 원본 사진은 변경되지 않습니다.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(16)
            .navigationTitle("이미지 위치·크기 조정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("적용 후 업로드") {
                        if let data = render() { onApply(data) }
                        else { renderFailed = true }
                    }
                }
            }
            .alert("이미지를 만들지 못했습니다", isPresented: $renderFailed) {
                Button("확인", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled()
    }

    private func imageRect(in size: CGSize, scale: CGFloat, offset: CGSize) -> CGRect {
        let fit = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * fit * scale
        let height = image.size.height * fit * scale
        return CGRect(x: (size.width - width) / 2 + offset.width * size.width,
                      y: (size.height - height) / 2 + offset.height * size.height,
                      width: width, height: height)
    }

    private func selection(in size: CGSize, translation: CGSize = .zero) -> CGRect {
        let initial = imageRect(in: size, scale: 1, offset: .zero)
        let maximum = min(size.width * 0.96, size.height * 0.96 * ratio)
        let width = min(maximum, max(maximum * 0.15,
            cropWidth.map { $0 * size.width } ?? min(initial.width, initial.height * ratio, maximum)))
        let height = width / ratio
        let x = min(size.width - width, max(0, cropCenter.x * size.width + translation.width - width / 2))
        let y = min(size.height - height, max(0, cropCenter.y * size.height + translation.height - height / 2))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func canvas(_ size: CGSize) -> some View {
        let offset = CGSize(width: position.width + imageDrag.width / size.width,
                            height: position.height + imageDrag.height / size.height)
        let photo = imageRect(in: size, scale: min(12, max(0.2, zoom * pinch)), offset: offset)
        let crop = selection(in: size, translation: cropDrag)
        return ZStack {
            ZStack {
                CropCheckerboard()
                Color(uiColor: paddingColor)
                Image(uiImage: image).resizable()
                    .frame(width: photo.width, height: photo.height)
                    .position(x: photo.midX, y: photo.midY)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .named("imageCropCanvas"))
                .updating($imageDrag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    position.width = min(3, max(-3, position.width + value.translation.width / size.width))
                    position.height = min(3, max(-3, position.height + value.translation.height / size.height))
                })
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(crop)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            cropGrid(crop)
            cropEdges(crop, in: size)
            ForEach(0..<4, id: \.self) { corner in
                Rectangle().fill(Color.blue)
                    .frame(width: 10, height: 10)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                    .position(x: corner % 2 == 0 ? crop.minX : crop.maxX,
                              y: corner < 2 ? crop.minY : crop.maxY)
                    .gesture(resizeGesture(corner: corner, size: size))
                    .accessibilityLabel("자르기 프레임 모서리")
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "imageCropCanvas")
        .clipped()
        .simultaneousGesture(MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in zoom = min(12, max(0.2, zoom * value)) })
    }

    private func cropGrid(_ crop: CGRect) -> some View {
        ZStack {
            Path { path in
                for division in 1...2 {
                    let fraction = CGFloat(division) / 3
                    path.move(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.minY))
                    path.addLine(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.maxY))
                    path.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * fraction))
                    path.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * fraction))
                }
            }.stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            Path { $0.addRect(crop) }.stroke(Color.blue, lineWidth: 2)
        }.allowsHitTesting(false)
    }

    private func cropEdges(_ crop: CGRect, in size: CGSize) -> some View {
        let move = DragGesture(coordinateSpace: .named("imageCropCanvas"))
            .updating($cropDrag) { value, state, _ in state = value.translation }
            .onEnded { value in storeSelection(selection(in: size, translation: value.translation), in: size) }
        return ZStack {
            Color.clear.frame(width: crop.width, height: 24).contentShape(Rectangle())
                .position(x: crop.midX, y: crop.minY).gesture(move)
            Color.clear.frame(width: crop.width, height: 24).contentShape(Rectangle())
                .position(x: crop.midX, y: crop.maxY).gesture(move)
            Color.clear.frame(width: 24, height: crop.height).contentShape(Rectangle())
                .position(x: crop.minX, y: crop.midY).gesture(move)
            Color.clear.frame(width: 24, height: crop.height).contentShape(Rectangle())
                .position(x: crop.maxX, y: crop.midY).gesture(move)
        }
    }

    private func resizeGesture(corner: Int, size: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .named("imageCropCanvas"))
            .onChanged { value in
                if resizeStart == nil {
                    let start = selection(in: size)
                    resizeStart = CGRect(x: start.minX / size.width, y: start.minY / size.height,
                                         width: start.width / size.width, height: start.height / size.height)
                }
                guard let normalized = resizeStart else { return }
                let start = CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
                                   width: normalized.width * size.width, height: normalized.height * size.height)
                let right = corner % 2 == 1
                let bottom = corner >= 2
                let anchor = CGPoint(x: right ? start.minX : start.maxX, y: bottom ? start.minY : start.maxY)
                let dx = value.translation.width * (right ? 1 : -1)
                let dy = value.translation.height * ratio * (bottom ? 1 : -1)
                let delta = abs(dx) >= abs(dy) ? dx : dy
                let maximum = min(right ? size.width - anchor.x : anchor.x,
                                  (bottom ? size.height - anchor.y : anchor.y) * ratio,
                                  size.width * 0.96, size.height * 0.96 * ratio)
                let minimum = min(size.width * 0.96, size.height * 0.96 * ratio) * 0.15
                let width = min(maximum, max(minimum, start.width + delta))
                let height = width / ratio
                storeSelection(CGRect(x: right ? anchor.x : anchor.x - width,
                                      y: bottom ? anchor.y : anchor.y - height,
                                      width: width, height: height), in: size)
            }
            .onEnded { _ in resizeStart = nil }
    }

    private func storeSelection(_ rect: CGRect, in size: CGSize) {
        cropWidth = rect.width / size.width
        cropCenter = CGPoint(x: rect.midX / size.width, y: rect.midY / size.height)
    }

    private func render() -> Data? {
        let workspace = CGSize(width: 1200, height: 900)
        let crop = selection(in: workspace)
        let photo = imageRect(in: workspace, scale: zoom, offset: position)
        let factor = output.width / crop.width
        let export = CGRect(x: (photo.minX - crop.minX) * factor,
                            y: (photo.minY - crop.minY) * factor,
                            width: photo.width * factor, height: photo.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: output, format: format).image { context in
            paddingColor.setFill()
            context.fill(CGRect(origin: .zero, size: output))
            context.cgContext.interpolationQuality = .high
            image.draw(in: export)
        }
        return rendered.pngData()
    }
}

private struct CropCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 12
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.35)))
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in 0..<Int(ceil(size.width / tile)) where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile,
                                             width: tile, height: tile)), with: .color(.gray.opacity(0.65)))
                }
            }
        }.allowsHitTesting(false)
    }
}
