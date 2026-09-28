import Foundation

/// 입력·출력 형식에 따라 이미지 변환기 또는 문서 변환기로 보낸다
nonisolated enum FileConverter {
    static func convert(_ source: URL, from sourceFormat: ImageFormat, to format: ImageFormat, into folder: URL) throws -> [URL] {
        // 워드 계열 문서가 들어오거나, PDF에서 글자를 뽑아 문서로 만드는 경우는 문서 변환기
        let needsDocumentEngine = sourceFormat.isDocument || (sourceFormat == .pdf && format.isDocument)
        guard needsDocumentEngine else {
            return try ImageConverter.convert(source, from: sourceFormat, to: format, into: folder)
        }
        #if os(macOS)
        return try DocumentConverter.convert(source, from: sourceFormat, to: format, into: folder)
        #else
        throw ImageConverter.ConversionError.unwritable
        #endif
    }
}
