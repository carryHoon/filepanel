import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO 기반 이미지 변환기 (PDF 입력은 CGPDFDocument로 페이지를 렌더링)
nonisolated enum ImageConverter {
    enum ConversionError: LocalizedError {
        case unreadable
        case unwritable

        var errorDescription: String? {
            switch self {
            case .unreadable: "파일을 읽을 수 없어요."
            case .unwritable: "파일을 저장할 수 없어요."
            }
        }
    }

    /// PDF 페이지를 이미지로 만들 때의 배율 (1 = 72dpi). 2면 144dpi로 화면에서 선명하다.
    private static let pdfRenderScale: CGFloat = 2
    /// 너무 큰 PDF 페이지가 메모리를 과하게 쓰지 않도록 한 변의 최대 픽셀
    private static let pdfMaxPixelSide: CGFloat = 8000
    /// 한 번에 이미지로 바꿀 PDF 최대 페이지 수 (실수로 수백 쪽 문서를 넣는 경우 대비)
    private static let pdfMaxPages = 200

    /// `source`를 `format`으로 변환해 `folder`에 저장하고, 저장된 파일 URL들을 반환한다.
    /// 여러 쪽짜리 PDF를 이미지로 바꾸면 페이지마다 파일이 생긴다 (이름-1, 이름-2 …).
    static func convert(_ source: URL, from sourceFormat: ImageFormat, to format: ImageFormat, into folder: URL) throws -> [URL] {
        // 파일 선택기/드래그로 받은 URL은 샌드박스 접근 권한을 명시적으로 열어야 한다
        let sourceAccess = source.startAccessingSecurityScopedResource()
        let folderAccess = folder.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { source.stopAccessingSecurityScopedResource() }
            if folderAccess { folder.stopAccessingSecurityScopedResource() }
        }

        let pages = sourceFormat == .pdf ? try renderPDFPages(source) : [try loadImage(source)]
        let baseName = source.deletingPathExtension().lastPathComponent

        return try pages.enumerated().map { index, page in
            let name = pages.count > 1 ? "\(baseName)-\(index + 1)" : baseName
            let destinationURL = uniqueURL(baseName: name, fileExtension: format.fileExtension, in: folder)
            try write(page.image, properties: page.properties, as: format, to: destinationURL)
            return destinationURL
        }
    }

    // MARK: - 읽기

    private struct LoadedImage {
        let image: CGImage
        /// 원본 메타데이터 (촬영 정보, 색 프로필 등). 회전 정보는 이미 픽셀에 반영했으므로 뺀다.
        let properties: [CFString: Any]
    }

    private static func loadImage(_ url: URL) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionError.unreadable
        }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1

        let image: CGImage?
        if orientation == 1 {
            // 회전이 없으면 원본 그대로 디코딩 (16비트·HDR 같은 원본 깊이 유지)
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            // 회전 정보가 있으면 픽셀 자체를 돌려서 저장한다.
            // BMP·ICO·PDF처럼 회전 태그를 모르는 형식에서도 사진이 눕지 않게 하기 위해서다.
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else { throw ConversionError.unreadable }

        properties[kCGImagePropertyOrientation] = nil
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        return LoadedImage(image: image, properties: properties)
    }

    /// PDF의 각 페이지를 흰 배경 이미지로 렌더링한다
    private static func renderPDFPages(_ url: URL) throws -> [LoadedImage] {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ConversionError.unreadable
        }

        let pageCount = min(document.numberOfPages, pdfMaxPages)
        return try (1...pageCount).map { pageNumber in
            guard let page = document.page(at: pageNumber) else { throw ConversionError.unreadable }

            // 페이지 회전(90/270도)을 반영한 실제 보이는 크기
            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
            let scale = min(pdfRenderScale, pdfMaxPixelSide / max(pageSize.width, pageSize.height, 1))
            let width = max(Int(pageSize.width * scale), 1)
            let height = max(Int(pageSize.height * scale), 1)

            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw ConversionError.unreadable }

            // 문서는 흰 종이 위에 그려진다고 가정한다 (투명 배경이면 글자가 안 보이는 경우가 많음)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.scaleBy(x: scale, y: scale)
            // getDrawingTransform은 확대를 하지 않으므로, 배율은 위에서 따로 적용하고 회전·위치만 맡긴다
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)

            guard let image = context.makeImage() else { throw ConversionError.unreadable }
            return LoadedImage(image: image, properties: [:])
        }
    }

    // MARK: - 쓰기

    private static func write(_ image: CGImage, properties: [CFString: Any], as format: ImageFormat, to url: URL) throws {
        var image = image
        if !format.supportsAlpha, let flattened = flattenedOnWhite(image) {
            image = flattened
        }

        // 아이콘은 정사각형 규격 크기 여러 장, 나머지는 원본 한 장
        let frames: [CGImage] = if let sizes = format.iconSizes {
            try sizes.map { try squareIcon(from: image, size: $0) }
        } else {
            [image]
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw ConversionError.unwritable
        }

        var options = format.iconSizes == nil ? properties : [:]
        if format.isLossy {
            options[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, options as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            // 실패하면 반쯤 쓰인 파일이 남지 않게 지운다
            try? FileManager.default.removeItem(at: url)
            throw ConversionError.unwritable
        }
    }

    /// 비율을 유지한 채 투명한 정사각형 가운데에 맞춰 넣은 아이콘 한 장
    private static func squareIcon(from image: CGImage, size: Int) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ConversionError.unwritable
        }
        let scale = CGFloat(size) / CGFloat(max(image.width, image.height, 1))
        let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let origin = CGPoint(x: (CGFloat(size) - drawSize.width) / 2, y: (CGFloat(size) - drawSize.height) / 2)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: origin, size: drawSize))
        guard let icon = context.makeImage() else { throw ConversionError.unwritable }
        return icon
    }

    /// 투명 영역을 흰색으로 채운 이미지를 만든다 (JPEG에서 투명 영역이 검게 나오는 것 방지)
    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        let opaqueAlphaInfos: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        guard !opaqueAlphaInfos.contains(image.alphaInfo) else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// 같은 이름의 파일이 있으면 "이름 2", "이름 3"처럼 번호를 붙인다
    static func uniqueURL(baseName: String, fileExtension: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder
                .appendingPathComponent("\(baseName) \(index)")
                .appendingPathExtension(fileExtension)
            index += 1
        }
        return candidate
    }
}
