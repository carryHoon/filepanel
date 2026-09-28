import SwiftUI
import UniformTypeIdentifiers

/// 패널(AppKit)이 받은 파일 드롭을 SwiftUI 화면으로 전달하는 통로.
/// macOS 가장자리 패널에서는 드롭을 AppKit이 직접 처리하고, 결과만 여기로 넘긴다.
@Observable
final class FileDropModel {
    struct Drop: Equatable {
        let id = UUID()
        let urls: [URL]
    }

    /// 파일을 패널 위로 끌고 온 상태인지 (드롭 영역 강조용)
    var isTargeted = false
    private(set) var latestDrop: Drop?

    func deliver(_ urls: [URL]) {
        latestDrop = Drop(urls: urls)
    }
}

/// 선택된 파일과, 헤더로 판별한 실제 형식
private struct SelectedFile: Identifiable {
    let url: URL
    let format: ImageFormat

    var id: URL { url }
}

/// 하단에 보여줄 상태 메시지
private enum StatusMessage {
    case info(String)
    case success(String)
    case warning(String)

    var text: String {
        switch self {
        case .info(let text), .success(let text), .warning(let text): text
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        }
    }
}

struct ContentView: View {
    @State private var targetFormat: ImageFormat = .png
    @State private var selectedFiles: [SelectedFile] = []
    @State private var outputFolder: URL?
    @State private var savedFiles: [URL] = []
    @State private var status: StatusMessage?
    @State private var isPickingFiles = false
    @State private var isPickingFolder = false
    @State private var isDropTargeted = false
    @State private var isConverting = false
    /// 현재 선택을 이 형식으로 변환 완료했음. 파일이나 변환 형식이 바뀌면 초기화된다.
    @State private var completedFormat: ImageFormat?
    /// 가장자리 패널 안에 있을 때만 주입된다
    @Environment(FileDropModel.self) private var panelDrop: FileDropModel?

    /// 드롭 영역 강조 여부. 패널 안이면 패널이 알려준 상태를, 아니면 SwiftUI 드롭 상태를 쓴다.
    private var isDropHighlighted: Bool {
        panelDrop?.isTargeted ?? isDropTargeted
    }

    /// 파일 선택 창에서 고를 수 있는 형식 (읽을 수 있는 모든 이미지 형식)
    private static let readableTypes = ImageFormat.allCases.map(\.utType)
    /// 드롭 영역에 이름을 보여줄 최대 파일 수
    private static let visibleFileLimit = 3

    /// 이미 변환 형식과 같은 파일은 변환할 필요가 없으므로 뺀다
    private var filesToConvert: [SelectedFile] {
        selectedFiles.filter { $0.format != targetFormat }
    }

    private var isCompleted: Bool {
        completedFormat == targetFormat && !isConverting
    }

    private var canConvert: Bool {
        !filesToConvert.isEmpty && outputFolder != nil && !isConverting && !isCompleted
    }

    /// 감지된 형식 요약. 한 가지면 "WEBP", 여러 가지면 "WEBP 2 · HEIC 1"
    private var detectedSummary: String? {
        guard !selectedFiles.isEmpty else { return nil }
        let counts = Dictionary(grouping: selectedFiles, by: \.format).mapValues(\.count)
        let formats = ImageFormat.allCases.filter { counts[$0] != nil }
        if formats.count == 1, let format = formats.first {
            return format.displayName
        }
        return formats.map { "\($0.displayName) \(counts[$0] ?? 0)" }.joined(separator: " · ")
    }

    /// 저장된 상태 메시지가 없을 때 보여줄 안내
    private var currentStatus: StatusMessage? {
        if let status { return status }
        if !selectedFiles.isEmpty && filesToConvert.isEmpty {
            return .info("모든 파일이 이미 \(targetFormat.displayName) 형식이에요.")
        }
        if !selectedFiles.isEmpty && outputFolder == nil {
            return .info("저장 위치를 선택해 주세요.")
        }
        return nil
    }

    var body: some View {
        // 모든 요소를 위에서부터 고정 높이로 쌓아서, 상태가 바뀌어도 버튼 위치는 그대로이고 내용만 바뀌게 한다
        VStack(alignment: .leading, spacing: 14) {
            header
            dropZone
            optionsGroup
            VStack(spacing: 8) {
                convertButton
                // 결과 문구는 버튼 아래 고정 높이 영역에만 표시해서, 나타나거나 사라져도 다른 요소가 움직이지 않게 한다
                statusView
                    .frame(maxWidth: .infinity, minHeight: Self.statusAreaHeight, maxHeight: Self.statusAreaHeight, alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        #if os(macOS)
        .frame(width: 320)
        #endif
        .animation(.snappy(duration: 0.2), value: isDropHighlighted)
        .animation(.snappy(duration: 0.2), value: selectedFiles.map(\.id))
        // 패널이 받은 드롭을 반영
        .onChange(of: panelDrop?.latestDrop) { _, drop in
            if let drop { addFiles(drop.urls) }
        }
        // 완료 후 변환 형식을 바꾸면 새 변환을 할 수 있게 완료 상태와 결과 문구를 지운다
        .onChange(of: targetFormat) {
            guard completedFormat != nil else { return }
            completedFormat = nil
            status = nil
            savedFiles = []
        }
    }

    /// 버튼 아래 결과 문구 영역 높이 (최대 두 줄)
    private static let statusAreaHeight: CGFloat = 32

    // MARK: - 헤더

    private var header: some View {
        HStack(spacing: 10) {
            // 앱 아이콘과 같은 변환 화살표. 템플릿 이미지라 강조 색·라이트/다크 모드를 따라간다.
            Image("ConvertArrows")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("파일 변환")
                    .font(.headline)
                Text("형식은 자동으로 인식해요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !selectedFiles.isEmpty {
                // 평소엔 선택 해제(X), 변환이 끝나면 '새로 시작'(↺)으로 바뀐다. 둘 다 누르면 처음 상태로 돌아간다.
                Button {
                    clearSelection()
                } label: {
                    Image(systemName: isCompleted ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isCompleted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(isCompleted ? "새로 시작" : "선택 해제")
                .transition(.opacity)
            }
        }
    }

    // MARK: - 파일 선택 / 드롭 영역

    private var dropZone: some View {
        Button {
            #if os(macOS)
            let urls = FilePicker.pickFiles(of: Self.readableTypes)
            if !urls.isEmpty { addFiles(urls) }
            #else
            isPickingFiles = true
            #endif
        } label: {
            Group {
                if selectedFiles.isEmpty {
                    emptyDropContent
                } else {
                    selectedFileList
                }
            }
            // 높이 고정: 파일 목록 길이에 따라 늘어나면 아래 버튼이 밀려 내려간다
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .background(
                isDropHighlighted ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.fill.quaternary),
                in: .rect(cornerRadius: 12)
            )
            .overlay {
                if selectedFiles.isEmpty || isDropHighlighted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isDropHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                }
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        #if !os(macOS)
        // macOS 가장자리 패널에서는 드롭을 AppKit(패널)이 받는다.
        // 여기서도 등록하면 호스팅 뷰가 드래그를 가로채 패널의 드롭 처리와 충돌한다.
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        #endif
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: Self.readableTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): addFiles(urls)
            case .failure(let error): status = .warning(error.localizedDescription)
            }
        }
    }

    private var emptyDropContent: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 28, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isDropHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: isDropHighlighted)
            Text("이미지·문서를 여기에 놓으세요")
                .font(.callout.weight(.medium))
            Text("또는 클릭해서 선택")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedFileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(selectedFiles.prefix(Self.visibleFileLimit)) { file in
                HStack(spacing: 8) {
                    Image(systemName: file.format.isDocument || file.format == .pdf ? "doc.text" : "photo")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(file.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    FormatBadge(format: file.format)
                }
                .font(.callout)
            }
            if selectedFiles.count > Self.visibleFileLimit {
                Text("외 \(selectedFiles.count - Self.visibleFileLimit)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
            Spacer(minLength: 0)
            Text("클릭하거나 놓아서 다시 선택")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .padding(12)
    }

    // MARK: - 옵션 (시스템 설정의 그룹 행 스타일)

    private var optionsGroup: some View {
        VStack(spacing: 0) {
            OptionRow(title: "원본") {
                Text(detectedSummary ?? "자동 인식")
                    .foregroundStyle(detectedSummary == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Divider().padding(.leading, 12)

            OptionRow(title: "변환 형식") {
                // 형식이 많아져서 메뉴 안에서 분류별(일반·문서·전문가용·아이콘)로 나눠 보여준다
                Picker("변환 형식", selection: $targetFormat) {
                    // 올린 파일로 만들 수 있는 형식만 보여준다 (예: DOCX를 올리면 문서·PDF·PNG·JPEG)
                    ForEach(ImageFormat.outputSections(for: selectedFiles.map(\.format)), id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.formats) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            Divider().padding(.leading, 12)

            OptionRow(title: "저장 위치") {
                folderButton
            }
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
    }

    private var folderButton: some View {
        Button {
            #if os(macOS)
            if let url = FilePicker.pickFolder() { outputFolder = url }
            #else
            isPickingFolder = true
            #endif
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(outputFolder?.lastPathComponent ?? "선택…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(outputFolder == nil ? .secondary : .primary)
            }
        }
        .buttonStyle(.borderless)
        .help(outputFolder?.path ?? "변환된 파일을 저장할 폴더를 선택하세요")
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): outputFolder = url
            case .failure(let error): status = .warning(error.localizedDescription)
            }
        }
    }

    // MARK: - 상태 / 변환 버튼

    /// 버튼 아래 한 줄: 왼쪽에 결과 문구, 오른쪽에 'Finder에서 보기'
    @ViewBuilder
    private var statusView: some View {
        if let currentStatus {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: currentStatus.symbol)
                    .foregroundStyle(currentStatus.tint)
                Text(currentStatus.text)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                #if os(macOS)
                if !savedFiles.isEmpty {
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting(savedFiles)
                    }
                    .buttonStyle(.link)
                    .fixedSize()
                }
                #endif
            }
            .font(.caption)
            .padding(.horizontal, 4)
            .transition(.opacity)
        }
    }

    private var convertButton: some View {
        Button {
            Task { await convert() }
        } label: {
            HStack(spacing: 6) {
                if isConverting {
                    ProgressView()
                        .controlSize(.small)
                    Text("변환 중…")
                } else if isCompleted {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                    Text("변환 완료")
                } else if filesToConvert.isEmpty {
                    Text("변환")
                } else {
                    Text("\(filesToConvert.count)개를 \(targetFormat.displayName)로 변환")
                }
            }
            .frame(maxWidth: .infinity)
            .contentTransition(.opacity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        // 완료 상태는 비활성(회색) 대신 초록색으로 보여주고, 누르면 아무 일도 하지 않는다
        .tint(isCompleted ? .green : nil)
        .allowsHitTesting(!isCompleted)
        .keyboardShortcut(.defaultAction)
        .disabled(!canConvert && !isCompleted)
        .animation(.snappy(duration: 0.2), value: isCompleted)
    }

    // MARK: - 동작

    /// 파일 헤더로 형식을 판별하고, 지원하지 않는 파일은 뺀다
    private func addFiles(_ urls: [URL]) {
        let detected = urls.compactMap { url in
            ImageFormat.detect(at: url).map { SelectedFile(url: url, format: $0) }
        }
        let skippedCount = urls.count - detected.count

        selectedFiles = detected
        savedFiles = []
        completedFormat = nil
        status = skippedCount > 0 ? .warning("지원하지 않는 파일 \(skippedCount)개는 제외했어요.") : nil
        adjustTargetFormat()
    }

    /// 올린 파일에 맞게 결과 형식을 맞춘다.
    /// - 지금 형식으로 만들 수 없으면(예: DOCX인데 ICO) 추천 형식으로 바꾼다.
    /// - 문서만 올렸는데 이미지 형식이 골라져 있으면 PDF로, 이미지를 올렸는데 워드 형식이면 PNG로 바꾼다.
    private func adjustTargetFormat() {
        let inputs = selectedFiles.map(\.format)
        guard !inputs.isEmpty else { return }
        let allowed = ImageFormat.outputSections(for: inputs).flatMap(\.formats)
        let preferred = ImageFormat.preferredOutput(for: inputs)
        let onlyDocuments = inputs.allSatisfy(\.isDocument)
        let mismatched = onlyDocuments ? !targetFormat.isDocument && targetFormat != .pdf : targetFormat.isDocument

        if !allowed.contains(targetFormat) || mismatched {
            targetFormat = allowed.contains(preferred) ? preferred : (allowed.first ?? preferred)
        }
    }

    private func clearSelection() {
        selectedFiles = []
        savedFiles = []
        completedFormat = nil
        status = nil
    }

    private func convert() async {
        // 완료 상태에서 Return 키로 다시 눌리는 경우도 막는다
        guard let folder = outputFolder, canConvert else { return }
        isConverting = true
        defer { isConverting = false }

        let files = filesToConvert.map { (url: $0.url, format: $0.format) }
        let alreadyTargetCount = selectedFiles.count - files.count
        let format = targetFormat

        // 디코딩/인코딩은 무거우므로 메인 스레드 밖에서 처리
        let (saved, failed) = await Task.detached {
            var saved: [URL] = []
            var failed: [String] = []
            for file in files {
                do {
                    // 여러 쪽 PDF는 한 파일에서 여러 결과가 나온다
                    saved += try FileConverter.convert(file.url, from: file.format, to: format, into: folder)
                } catch {
                    failed.append(file.url.lastPathComponent)
                }
            }
            return (saved, failed)
        }.value

        savedFiles = saved
        // 결과 파일 수가 입력 수와 다르면(PDF 여러 쪽) 만들어진 파일 수 기준으로 알려준다
        let convertedCount = files.count - failed.count
        let summary = saved.count == convertedCount
            ? "\(saved.count)개를 ‘\(folder.lastPathComponent)’에 저장했어요."
            : "\(convertedCount)개 파일에서 \(saved.count)개를 ‘\(folder.lastPathComponent)’에 저장했어요."
        var lines = [summary]
        if alreadyTargetCount > 0 {
            lines.append("이미 \(format.displayName)인 \(alreadyTargetCount)개는 건너뛰었어요.")
        }
        if !failed.isEmpty {
            lines.append("실패: \(failed.joined(separator: ", "))")
        }
        let message = lines.joined(separator: "\n")
        status = failed.isEmpty ? .success(message) : .warning(message)
        // 전부 성공했을 때만 완료로 표시한다. 실패가 있으면 다시 시도할 수 있게 둔다.
        if failed.isEmpty && !saved.isEmpty {
            completedFormat = format
        }
    }
}

/// 옵션 그룹의 한 줄: 왼쪽 제목, 오른쪽 값/컨트롤
private struct OptionRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            content
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
    }
}

/// 파일 형식을 작은 캡슐로 표시
private struct FormatBadge: View {
    let format: ImageFormat

    var body: some View {
        Text(format.displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.fill.tertiary, in: .capsule)
    }
}

#if os(macOS)
/// 가장자리 패널은 SwiftUI 씬이 아니라서 fileImporter 대신 NSOpenPanel을 직접 띄운다
private enum FilePicker {
    static func pickFiles(of types: [UTType]) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "변환할 이미지나 문서를 선택하세요"
        return run(panel) ? panel.urls : []
    }

    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.message = "변환된 파일을 저장할 폴더를 선택하세요"
        return run(panel) ? panel.url : nil
    }

    private static func run(_ panel: NSOpenPanel) -> Bool {
        // Dock 아이콘 없는 앱이라 먼저 활성화해야 열기 창이 다른 앱 뒤에 숨지 않는다
        NSApp.activate()
        return panel.runModal() == .OK
    }
}
#endif

#Preview {
    ContentView()
        .frame(height: 416)
}
