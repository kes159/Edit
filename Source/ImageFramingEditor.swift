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
        case .poster: return CGSize(width: 1500, height: 1000)
        case .header, .screenshot:
            let limit: CGFloat = self == .screenshot ? 4096 : 2048
            let scale = min(1, limit / max(image.size.width, image.size.height))
            return CGSize(width: max(1, (image.size.width * scale).rounded()),
                          height: max(1, (image.size.height * scale).rounded()))
        }
    }

    func fitScale(image: CGSize, canvas: CGSize) -> CGFloat {
        if self == .sourceIcon {
            // Fit all four corners inside SideStore's circular source icon mask.
            return min(canvas.width, canvas.height) / hypot(image.width, image.height) * 0.96
        }
        let inset: CGFloat = self == .appIcon ? 0.84 : 1
        return min(canvas.width / image.width, canvas.height / image.height) * inset
    }
}

private enum FramingError: LocalizedError {
    case unreadable
    var errorDescription: String? { "이미지를 읽지 못했거나 파일이 너무 큽니다." }
}

/// Preview and export share the same normalized position and drawing rectangle.
struct ImageFramingEditor: View {
    let image: UIImage
    let profile: ImageFrameProfile
    let onCancel: () -> Void
    let onApply: (Data) -> Void
    @State private var zoom: CGFloat = 1
    @State private var position: CGSize = .zero
    @State private var renderFailed = false
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    private var output: CGSize { profile.outputSize(for: image) }
    private var paddingColor: UIColor { UIColor.white.withAlphaComponent(0.5) }
    private var maximumZoom: CGFloat {
        let fillScale = max(output.width / image.size.width, output.height / image.size.height)
            / profile.fitScale(image: image.size, canvas: output)
        return max(6, fillScale * 2)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    let ratio = output.width / output.height
                    let width = max(1, min(520, min(geometry.size.width, geometry.size.height * ratio)))
                    let size = CGSize(width: width, height: width / ratio)
                    canvas(size)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                Text("사진을 끌어 위치를 바꾸고 두 손가락으로 확대·축소하세요.")
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

    private func drawingRect(canvas: CGSize, scale: CGFloat, offset: CGSize) -> CGRect {
        let factor = profile.fitScale(image: image.size, canvas: canvas) * scale
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        return CGRect(x: (canvas.width - size.width) / 2 + offset.width * canvas.width,
                      y: (canvas.height - size.height) / 2 + offset.height * canvas.height,
                      width: size.width, height: size.height)
    }

    private func canvas(_ size: CGSize) -> some View {
        let scale = min(maximumZoom, max(0.2, zoom * pinch))
        let offset = CGSize(width: position.width + drag.width / size.width,
                            height: position.height + drag.height / size.height)
        let rect = drawingRect(canvas: size, scale: scale, offset: offset)
        return ZStack {
            Color(uiColor: paddingColor)
            Image(uiImage: image).resizable()
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .mask {
            if profile == .sourceIcon { Circle() }
            else if profile == .appIcon { RoundedRectangle(cornerRadius: size.width * 0.22) }
            else { Rectangle() }
        }
        .background(Color.gray.opacity(0.2))
        .overlay { Rectangle().stroke(Color.secondary, lineWidth: 1) }
        .overlay {
            if profile == .sourceIcon { Circle().stroke(Color.accentColor, lineWidth: 2) }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                position.width = min(3, max(-3, position.width + value.translation.width / size.width))
                position.height = min(3, max(-3, position.height + value.translation.height / size.height))
            })
        .simultaneousGesture(MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in zoom = min(maximumZoom, max(0.2, zoom * value)) })
    }

    private func render() -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: output, format: format).image { context in
            paddingColor.setFill()
            context.fill(CGRect(origin: .zero, size: output))
            context.cgContext.interpolationQuality = .high
            image.draw(in: drawingRect(canvas: output, scale: zoom, offset: position))
        }
        return rendered.pngData()
    }
}
