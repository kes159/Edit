import Foundation
import ImageIO
import UIKit

struct CloudinaryUploadedImage {
    let url: URL
    let width: Int
    let height: Int
}

enum CloudinaryImageUploader {
    enum Purpose: Equatable { case poster, artwork, screenshot }
    // Public identifiers for the unsigned upload preset; no API secret is used.
    private static let cloudName = "twcc97rp"
    private static let uploadPreset = "source_editor_public"
    private static let maximumInputBytes = 100_000_000
    private static let maximumUploadBytes = 10_000_000

    static func upload(_ imageData: Data) async throws -> URL {
        (try await uploadImage(imageData, purpose: .poster)).url
    }

    static func uploadImage(_ imageData: Data, purpose: Purpose) async throws -> CloudinaryUploadedImage {
        guard !imageData.isEmpty, imageData.count <= maximumInputBytes else {
            throw UploadError.imageTooLarge
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: purpose == .screenshot ? 4096 : 2048,
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw UploadError.invalidImage
        }
        let image = UIImage(cgImage: thumbnail)
        let isJPEG = purpose == .poster
        guard let encoded = isJPEG ? image.jpegData(compressionQuality: 0.85) : image.pngData() else {
            throw UploadError.invalidImage
        }
        guard encoded.count <= maximumUploadBytes else { throw UploadError.imageTooLarge }

        let boundary = UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"upload_preset\"\r\n\r\n\(uploadPreset)\r\n".utf8))
        let filename = isJPEG ? "image.jpg" : "image.png"
        let contentType = isJPEG ? "image/jpeg" : "image/png"
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(encoded)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://api.cloudinary.com/v1_1/\(cloudName)/image/upload")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(UploadErrorResponse.self, from: data))?.error.message
            throw UploadError.server(http.statusCode, detail)
        }
        guard let result = try? JSONDecoder().decode(UploadResponse.self, from: data),
              let url = URL(string: result.secureURL),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "res.cloudinary.com",
              url.path.hasPrefix("/\(cloudName)/"),
              result.width > 0, result.height > 0 else {
            throw UploadError.invalidResponse
        }
        return CloudinaryUploadedImage(url: url, width: result.width, height: result.height)
    }
}

private struct UploadResponse: Decodable {
    let secureURL: String
    let width: Int
    let height: Int
    enum CodingKeys: String, CodingKey { case secureURL = "secure_url", width, height }
}

private struct UploadErrorResponse: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}

private enum UploadError: LocalizedError {
    case invalidImage, imageTooLarge, invalidResponse, server(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidImage: "선택한 파일에서 이미지를 읽지 못했습니다."
        case .imageTooLarge: "이미지가 너무 큽니다. 다른 이미지를 선택해 주세요."
        case .invalidResponse: "Cloudinary에서 올바른 이미지 주소를 받지 못했습니다."
        case .server(let status, let detail):
            "이미지 업로드에 실패했습니다 (HTTP \(status)).\(detail.map { "\n\($0)" } ?? "")"
        }
    }
}
