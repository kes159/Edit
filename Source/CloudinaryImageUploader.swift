import Foundation
import ImageIO
import UIKit

enum CloudinaryImageUploader {
    // Public identifiers for the unsigned upload preset; no API secret is used.
    private static let cloudName = "twcc97rp"
    private static let uploadPreset = "source_editor_public"
    private static let maximumInputBytes = 100_000_000
    private static let maximumUploadBytes = 10_000_000

    static func upload(_ imageData: Data) async throws -> URL {
        guard !imageData.isEmpty, imageData.count <= maximumInputBytes else {
            throw UploadError.imageTooLarge
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85) else {
            throw UploadError.invalidImage
        }
        guard jpeg.count <= maximumUploadBytes else { throw UploadError.imageTooLarge }

        let boundary = UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"upload_preset\"\r\n\r\n\(uploadPreset)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"poster.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
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
              url.path.hasPrefix("/\(cloudName)/") else {
            throw UploadError.invalidResponse
        }
        return url
    }
}

private struct UploadResponse: Decodable {
    let secureURL: String
    enum CodingKeys: String, CodingKey { case secureURL = "secure_url" }
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
