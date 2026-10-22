import Foundation
import Darwin

extension FileOperationTests {
    static func quickViewTests() async {
        await test("preview preserves the original encoded and binary file") { dir in
            let fixtures: [(String, Data)] = [
                ("unicode.txt", Data([0xff, 0xfe]) + "中文 café 😀".data(using: .utf16LittleEndian)!),
                ("document.pdf", Data("%PDF-1.4\n1 0 obj\n".utf8)),
                ("image.png", Data([0x89, 0x50, 0x4e, 0x47, 0, 255]))
            ]
            for (name, bytes) in fixtures {
                let url = dir.appendingPathComponent(name)
                try bytes.write(to: url)
                let content = try await LocalFileSystemService().quickViewContent(for: url)
                try expect(content.url == url, "preview must reference the original file")
                try expect(content.title == name, "preview title mismatch")
                try expect(content.allowsTextEncoding == (name == "unicode.txt"), "encoding controls must be limited to plain text")
                let originalBytes = try Data(contentsOf: content.url)
                try expect(originalBytes == bytes, "preview changed original bytes")
            }
        }
        await test("preview allows a document larger than the old text buffer limit") { dir in
            let url = try file(dir, "large.pdf", "%PDF-1.4")
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 11 * 1024 * 1024)
            try handle.close()
            let content = try await LocalFileSystemService().quickViewContent(for: url)
            try expect(content.url == url, "large document was replaced by a text placeholder")
        }
        await test("preview explicit encodings preserve Unicode and traditional Chinese") { dir in
            let fixtures: [(PreviewTextEncoding, String)] = [
                (.utf8, "中文 café 😀"), (.utf16, "中文 café 😀"),
                (.gb18030, "中文预览正常"), (.big5, "中文預覽正常")
            ]
            for (encoding, expected) in fixtures {
                let url = dir.appendingPathComponent("sample.txt")
                let data = expected.data(using: encoding.stringEncoding!)!
                try data.write(to: url)
                let result = try PreviewTextDecoder.read(url, encoding: encoding.stringEncoding!)
                try expect(result == expected, "explicit encoding lost characters")
            }
        }
        await test("preview decoding errors do not strip bytes or load oversized files") { dir in
            let url = dir.appendingPathComponent("sample.txt")
            try Data([0xff, 0xfe, 0xff]).write(to: url)
            try await mustFail { _ = try PreviewTextDecoder.read(url, encoding: .utf8) }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(PreviewTextDecoder.maximumBytes + 1))
            try handle.close()
            try await mustFail { _ = try PreviewTextDecoder.read(url, encoding: .utf8) }
        }
        await test("preview rejects missing unreadable and nonregular files") { dir in
            let service = LocalFileSystemService()
            try await mustFail { _ = try await service.quickViewContent(for: dir.appendingPathComponent("missing")) }
            try await mustFail { _ = try await service.quickViewContent(for: dir) }
            let fifo = dir.appendingPathComponent("pipe")
            try expect(mkfifo(fifo.path, 0o600) == 0, "fixture FIFO failed")
            try await mustFail { _ = try await service.quickViewContent(for: fifo) }
            let source = try file(dir, "unreadable.txt")
            chmod(source.path, 0)
            defer { chmod(source.path, 0o600) }
            try await mustFail { _ = try await service.quickViewContent(for: source) }
        }
    }
}
