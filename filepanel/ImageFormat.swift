import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 변환에 사용할 수 있는 형식 (이미지 + 문서).
/// 이미지는 ImageIO(+ PDF는 CGPDFDocument), 워드 계열 문서는 macOS 내장 문서 엔진(NSAttributedString)으로 처리한다.
nonisolated enum ImageFormat: String, CaseIterable, Identifiable {
    // 일반
    case png, jpeg, heic, heif, avif, webp, jpegXL, tiff, gif, bmp
    // 문서
    case pdf, docx, doc, rtf, odt, txt, html
    // 전문가용
    case raw, psd, jpeg2000, openEXR, tga, radiance, sgi, pbm, pict
    // 아이콘
    case ico, icns

    var id: Self { self }

    var displayName: String {
        switch self {
        case .jpegXL: "JPEG XL"
        case .jpeg2000: "JPEG 2000"
        case .openEXR: "OpenEXR"
        case .radiance: "HDR"
        case .raw: "RAW"
        default: rawValue.uppercased()
        }
    }

    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .heif: .heif
        case .avif: Self.type("public.avif")
        case .webp: .webP
        case .jpegXL: Self.type("public.jpeg-xl")
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .pdf: .pdf
        case .docx: Self.type("org.openxmlformats.wordprocessingml.document")
        case .doc: Self.type("com.microsoft.word.doc")
        case .rtf: .rtf
        case .odt: Self.type("org.oasis-open.opendocument.text")
        case .txt: .plainText
        case .html: .html
        // 카메라 RAW는 제조사별 형식(ARW, CR3, NEF, DNG…)이 모두 이 타입을 따른다
        case .raw: .rawImage
        case .psd: Self.type("com.adobe.photoshop-image")
        case .jpeg2000: Self.type("public.jpeg-2000")
        case .openEXR: Self.type("com.ilm.openexr-image")
        case .tga: Self.type("com.truevision.tga-image")
        case .radiance: Self.type("public.radiance")
        case .sgi: Self.type("com.sgi.sgi-image")
        case .pbm: Self.type("public.pbm")
        case .pict: Self.type("com.apple.pict")
        case .ico: .ico
        case .icns: .icns
        }
    }

    var fileExtension: String {
        switch self {
        // 일반 텍스트 타입의 기본 확장자는 'txt'가 아닐 수 있어 고정한다
        case .txt: "txt"
        case .html: "html"
        default: utType.preferredFilenameExtension ?? rawValue
        }
    }

    /// 워드 계열 문서 (macOS 내장 문서 엔진으로 읽고 쓴다)
    var isDocument: Bool {
        Self.documentFormats.contains(self)
    }

    static let documentFormats: [ImageFormat] = [.docx, .doc, .rtf, .odt, .txt, .html]

    /// 입력으로 받는 문서. HTML 읽기는 메인 스레드에서만 가능해 변환 중(백그라운드) 멈춤 위험이 있어 입력에서 뺐다.
    private static let documentInputs: [ImageFormat] = [.docx, .doc, .rtf, .odt, .txt]

    /// 투명도를 저장할 수 없는 형식은 흰 배경으로 합성해서 저장한다
    var supportsAlpha: Bool {
        switch self {
        case .jpeg, .pbm: false
        default: true
        }
    }

    /// 손실 압축 품질을 적용할 형식
    var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .heif, .avif, .jpeg2000: true
        default: false
        }
    }

    /// 아이콘 형식은 정사각형 규격 크기 여러 장을 한 파일에 담아야 한다 (원본 크기 그대로는 저장 실패)
    var iconSizes: [Int]? {
        switch self {
        // ICO는 한 장당 최대 256px. 24px는 단독으론 되지만 다른 크기와 섞으면 ImageIO가 저장에 실패해서 뺐다.
        case .ico: [16, 32, 48, 64, 128, 256]
        case .icns: [16, 32, 64, 128, 256, 512, 1024]
        default: nil
        }
    }

    private static func type(_ identifier: String) -> UTType {
        UTType(identifier) ?? .image
    }

    // MARK: - 형식 판별

    /// 확장자가 아니라 파일 내용을 읽어서 실제 형식을 판별한다.
    /// (웹에서 받은 파일은 이름이 .png인데 내용은 WebP인 경우가 흔하다)
    static func detect(at url: URL) -> ImageFormat? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let identifier = CGImageSourceGetType(source) as String?,
           let type = UTType(identifier) {
            return match(type)
        }
        // ImageIO가 모르는 PDF 변형도 PDF 렌더러로 열리면 PDF로 본다
        if let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 {
            return .pdf
        }
        // 워드 계열 문서는 이미지처럼 내용으로 판별할 방법이 없어 파일 종류(확장자)로 판단한다.
        // 실제로 열리는지는 변환할 때 확인하고, 안 열리면 실패로 알려준다.
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        if let type, let document = documentInputs.first(where: { type.conforms(to: $0.utType) }) {
            return document
        }
        return nil
    }

    /// 판별 우선순위: RAW(일부 RAW는 TIFF 기반이라 TIFF로 오인되지 않게 먼저), HEIC(HEIF의 하위 형식) 순
    private static let detectionOrder: [ImageFormat] = [.raw, .heic] + allCases.filter { $0 != .raw && $0 != .heic }

    private static func match(_ type: UTType) -> ImageFormat? {
        detectionOrder.first { type.conforms(to: $0.utType) }
    }

    // MARK: - 변환 결과 형식

    /// 결과 형식 메뉴의 분류와 순서
    private static let allOutputSections: [(title: String, formats: [ImageFormat])] = [
        ("일반", [.png, .jpeg, .heic, .avif, .tiff, .gif, .bmp]),
        ("문서", [.pdf, .docx, .doc, .rtf, .odt, .txt, .html]),
        ("전문가용", [.psd, .jpeg2000, .openEXR, .tga]),
        ("아이콘", [.ico, .icns]),
    ]

    /// 이미지 결과 형식 중 이 Mac의 ImageIO가 실제로 쓸 수 있는 것 (예: WebP, JPEG XL은 읽기만 지원)
    private static let writableImageOutputs: Set<ImageFormat> = {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return Set(allOutputSections.flatMap(\.formats).filter { !$0.isDocument && writable.contains($0.utType.identifier) })
    }()

    /// 이 형식의 파일로 만들 수 있는 결과 형식
    var allowedOutputs: Set<ImageFormat> {
        if isDocument {
            // 문서 → 문서 형식, PDF로 조판, 페이지별 PNG/JPEG
            return Set(Self.documentFormats).union([.pdf, .png, .jpeg])
        }
        if self == .pdf {
            // PDF → 페이지별 이미지 + 텍스트 추출(문서 형식)
            return Self.writableImageOutputs.union(Self.documentFormats)
        }
        return Self.writableImageOutputs
    }

    /// 올린 파일들 모두로 만들 수 있는 결과 형식만 분류별로 보여준다.
    /// 예: 이미지와 DOCX를 섞으면 둘 다 가능한 PDF·PNG·JPEG만 남는다. 아무것도 안 올렸으면 전부 보여준다.
    static func outputSections(for inputs: some Collection<ImageFormat>) -> [(title: String, formats: [ImageFormat])] {
        let everything = writableImageOutputs.union(documentFormats)
        let allowed = inputs.reduce(everything) { $0.intersection($1.allowedOutputs) }
        return allOutputSections
            .map { section in (section.title, section.formats.filter { allowed.contains($0) }) }
            .filter { !$0.formats.isEmpty }
    }

    /// 파일을 올렸을 때 먼저 골라줄 결과 형식: 문서만 있으면 PDF, 그 외엔 PNG
    static func preferredOutput(for inputs: some Collection<ImageFormat>) -> ImageFormat {
        !inputs.isEmpty && inputs.allSatisfy(\.isDocument) ? .pdf : .png
    }
}
