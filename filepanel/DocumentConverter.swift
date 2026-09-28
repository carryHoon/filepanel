#if os(macOS)
import AppKit
import PDFKit

/// macOS 내장 문서 엔진(NSAttributedString, TextEdit과 같은 엔진)으로 워드 계열 문서를 변환한다.
/// 글자 스타일·문단·목록·기본 표·이미지는 대체로 유지되지만, Word 전용 레이아웃
/// (머리글/바닥글, 각주, 도형, 복잡한 표)은 달라질 수 있다.
nonisolated enum DocumentConverter {
    enum DocumentError: LocalizedError {
        case unreadable
        case noText
        case unwritable

        var errorDescription: String? {
            switch self {
            case .unreadable: "문서를 열 수 없어요."
            case .noText: "PDF에 글자 정보가 없어요. (스캔한 문서일 수 있어요)"
            case .unwritable: "문서를 저장할 수 없어요."
            }
        }
    }

    /// 문서를 PDF로 조판할 때의 용지(A4)와 여백
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let pageMargin: CGFloat = 72
    /// 잘못된 입력으로 끝없이 페이지가 늘어나는 것을 막는 상한
    private static let maxPages = 2000

    static func convert(_ source: URL, from sourceFormat: ImageFormat, to format: ImageFormat, into folder: URL) throws -> [URL] {
        let sourceAccess = source.startAccessingSecurityScopedResource()
        let folderAccess = folder.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { source.stopAccessingSecurityScopedResource() }
            if folderAccess { folder.stopAccessingSecurityScopedResource() }
        }

        let content = sourceFormat == .pdf ? try extractText(fromPDF: source) : try read(source, as: sourceFormat)
        let baseName = source.deletingPathExtension().lastPathComponent

        switch format {
        case .pdf:
            let url = ImageConverter.uniqueURL(baseName: baseName, fileExtension: "pdf", in: folder)
            try write(makePDF(from: content), to: url)
            return [url]

        case .png, .jpeg:
            // 문서 → PDF로 조판한 뒤, 기존 PDF → 이미지 경로로 페이지마다 한 장씩 만든다
            let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDirectory) }
            let pdfURL = workDirectory.appendingPathComponent(baseName).appendingPathExtension("pdf")
            try write(makePDF(from: content), to: pdfURL)
            return try ImageConverter.convert(pdfURL, from: .pdf, to: format, into: folder)

        default:
            guard let type = documentType(for: format) else { throw DocumentError.unwritable }
            var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if type == .plain {
                attributes[.characterEncoding] = String.Encoding.utf8.rawValue
            }
            let data: Data
            do {
                data = try content.data(from: NSRange(location: 0, length: content.length), documentAttributes: attributes)
            } catch {
                throw DocumentError.unwritable
            }
            let url = ImageConverter.uniqueURL(baseName: baseName, fileExtension: format.fileExtension, in: folder)
            try write(data, to: url)
            return [url]
        }
    }

    // MARK: - 읽기

    private static func documentType(for format: ImageFormat) -> NSAttributedString.DocumentType? {
        switch format {
        case .docx: .officeOpenXML
        case .doc: .docFormat
        case .rtf: .rtf
        case .odt: .openDocument
        case .txt: .plain
        case .html: .html
        default: nil
        }
    }

    private static func read(_ url: URL, as format: ImageFormat) throws -> NSAttributedString {
        if format == .txt {
            return try readPlainText(url)
        }
        // HTML 읽기는 메인 스레드 전용이라 입력에서 제외했다 (여기는 백그라운드에서 실행됨)
        guard format != .html, let type = documentType(for: format) else { throw DocumentError.unreadable }
        do {
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        } catch {
            throw DocumentError.unreadable
        }
    }

    /// 텍스트 파일을 여러 인코딩으로 차례로 시도해 읽는다.
    /// 윈도우 메모장에서 저장한 옛 한글(CP949/EUC-KR) 파일은 macOS의 자동 추측으로는 못 읽는 경우가 있다.
    private static func readPlainText(_ url: URL) throws -> NSAttributedString {
        guard let data = try? Data(contentsOf: url) else { throw DocumentError.unreadable }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]

        // BOM이 있거나 UTF-8이면 그대로
        if let string = String(data: data, encoding: .utf8) ?? decodeWithBOM(data) {
            return NSAttributedString(string: string, attributes: attributes)
        }
        // 한국어 → 일본어 → 중국어 순. 서유럽(Latin-1)은 어떤 바이트든 읽혀서 맨 마지막에 둔다.
        let fallbacks: [CFStringEncodings] = [.dosKorean, .EUC_KR, .shiftJIS, .GB_18030_2000, .big5]
        for encoding in fallbacks {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
            if let string = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                return NSAttributedString(string: string, attributes: attributes)
            }
        }
        if let string = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) {
            return NSAttributedString(string: string, attributes: attributes)
        }
        throw DocumentError.unreadable
    }

    private static func decodeWithBOM(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(2))
        guard bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF] else { return nil }
        return String(data: data, encoding: .utf16)
    }

    /// PDF의 글자를 뽑아낸다. 서식(글꼴 크기 등)도 가능한 만큼 가져온다.
    private static func extractText(fromPDF url: URL) throws -> NSAttributedString {
        guard let document = PDFDocument(url: url) else { throw DocumentError.unreadable }
        let result = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let text = page.attributedString, text.length > 0 {
                if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
                result.append(text)
            }
        }
        // 글자가 하나도 없으면 스캔 이미지 PDF일 가능성이 높다 → 빈 문서를 만들지 않고 알려준다
        guard !result.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentError.noText
        }
        return result
    }

    // MARK: - PDF 조판

    /// 문서를 A4 페이지로 나눠 PDF로 그린다 (TextKit으로 페이지마다 텍스트 영역을 채워 나간다)
    private static func makePDF(from content: NSAttributedString) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocumentError.unwritable
        }

        let storage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let textSize = CGSize(width: pageSize.width - pageMargin * 2, height: pageSize.height - pageMargin * 2)

        // 글자가 다 들어갈 때까지 페이지(텍스트 영역)를 하나씩 추가한다
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
        } while NSMaxRange(layoutManager.glyphRange(for: containers[containers.count - 1])) < layoutManager.numberOfGlyphs
            && containers.count < maxPages

        let origin = CGPoint(x: pageMargin, y: pageMargin)
        NSGraphicsContext.saveGraphicsState()
        // 텍스트는 위에서 아래로 그려지므로 뒤집힌 좌표계로 그린다
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            let glyphRange = layoutManager.glyphRange(for: container)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
            context.restoreGState()
            context.endPDFPage()
        }
        NSGraphicsContext.restoreGraphicsState()
        context.closePDF()
        return data as Data
    }

    private static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DocumentError.unwritable
        }
    }
}
#endif
