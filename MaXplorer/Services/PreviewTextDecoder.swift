import Foundation
import CoreFoundation

nonisolated enum PreviewTextEncoding: String, CaseIterable, Identifiable, Sendable {
    case automatic = "Automatic"
    case utf8 = "UTF-8"
    case utf16 = "UTF-16"
    case gb18030 = "GB18030 / GBK"
    case big5 = "Big5"

    var id: String { rawValue }

    var displayName: String {
        self == .automatic ? "自动" : rawValue
    }

    var stringEncoding: String.Encoding? {
        switch self {
        case .automatic: nil
        case .utf8: .utf8
        case .utf16: .utf16
        case .gb18030: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .big5: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        }
    }
}

nonisolated enum PreviewTextDecoder {
    static let maximumBytes = 10 * 1024 * 1024

    static func read(_ url: URL, encoding: String.Encoding) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw FileSystemError.previewUnavailable("仅支持为不超过 10 MB 的文本文件选择编码。较大文件请使用“自动”。")
        }
        guard let text = String(data: data, encoding: encoding) else {
            throw FileSystemError.previewUnavailable("无法使用所选编码读取此文件。请尝试其他编码或选择“自动”。")
        }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
}
