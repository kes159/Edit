import Foundation
import ImageIO
import UIKit

enum ImgurImageUploader {
    private static let maximumInputBytes = 100_000_000
    private static let maximumUploadBytes = 10_000_000

    static func upload(_ imageData: Data, clientID: String) async throws -> URL {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty,
              clientID.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw UploadError.invalidClientID
        }
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
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"poster.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://api.imgur.com/3/image")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Client-ID \(clientID)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UploadError.server((response as? HTTPURLResponse)?.statusCode)
        }
        guard let result = try? JSONDecoder().decode(UploadResponse.self, from: data),
              result.success, let link = result.data?.link,
              var components = URLComponents(string: link) else {
            throw UploadError.invalidResponse
        }
        components.scheme = "https"
        guard components.host?.lowercased() == "i.imgur.com", let url = components.url else {
            throw UploadError.invalidResponse
        }
        return url
    }
}

private struct UploadResponse: Decodable {
    let success: Bool
    let data: UploadedImage?
}

private struct UploadedImage: Decodable {
    let link: String?
}

private enum UploadError: LocalizedError {
    case invalidClientID, invalidImage, imageTooLarge, invalidResponse, server(Int?)

    var errorDescription: String? {
        switch self {
        case .invalidClientID: "Imgur Client ID를 확인해 주세요."
        case .invalidImage: "선택한 파일에서 이미지를 읽지 못했습니다."
        case .imageTooLarge: "이미지가 너무 큽니다. 다른 이미지를 선택해 주세요."
        case .invalidResponse: "Imgur에서 이미지 주소를 받지 못했습니다."
        case .server(let status): "Imgur 업로드에 실패했습니다\(status.map { " (HTTP \($0))" } ?? ""). Client ID를 확인해 주세요."
        }
    }
}
