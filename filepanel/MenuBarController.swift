#if os(macOS)
import AppKit
import SwiftUI

/// 상단 메뉴 막대 아이콘. 누르면 변환 화면이 팝오버로 열린다.
/// 가장자리 패널과 같은 ContentView를 쓰고, 파일 드롭도 같은 방식(AppKit 컨테이너)으로 받는다.
@Observable
final class MenuBarController: NSObject, NSPopoverDelegate {
    private static let visibleKey = "MenuBarIconVisible"

    /// 메뉴 막대 아이콘 표시 여부. 바꾸면 저장하고 바로 반영한다.
    var isVisible: Bool {
        didSet {
            UserDefaults.standard.set(isVisible, forKey: Self.visibleKey)
            statusItem.isVisible = isVisible
            if !isVisible { closePopover() }
        }
    }

    /// 우클릭 메뉴의 '설정…'에서 호출 (설정 창은 가장자리 패널 컨트롤러가 관리한다)
    @ObservationIgnored var onOpenSettings: (() -> Void)?

    @ObservationIgnored private let statusItem: NSStatusItem
    @ObservationIgnored private let popover = NSPopover()
    @ObservationIgnored private let dropModel = FileDropModel()

    override init() {
        isVisible = UserDefaults.standard.object(forKey: Self.visibleKey) as? Bool ?? true
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureButton()
        configurePopover()
        statusItem.isVisible = isVisible
    }

    // MARK: - 팝오버

    func showPopover() {
        guard isVisible, !popover.isShown, let button = statusItem.button else { return }
        // Dock 아이콘 없는 앱이라 활성화해야 팝오버가 키 입력(Return으로 변환 등)을 받는다
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }

    private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    // MARK: - 구성

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // 앱 아이콘과 같은 변환 화살표(벡터). 템플릿 이미지여야 메뉴 막대의 밝기/다크 모드에 맞춰 색이 바뀐다.
        let image = (NSImage(named: "ConvertArrows")?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16)
        image?.isTemplate = true
        image?.accessibilityDescription = "파일 변환"
        button.image = image
        button.toolTip = "파일 변환 · 우클릭으로 설정"

        // 클릭·우클릭·파일 끌어오기를 한 곳에서 받는 투명 뷰를 버튼 위에 얹는다
        let inputView = StatusItemInputView(frame: button.bounds)
        inputView.autoresizingMask = [.width, .height]
        inputView.onClick = { [weak self] in self?.togglePopover() }
        inputView.onRightClick = { [weak self] in self?.showMenu() }
        inputView.onDragEntered = { [weak self] in
            // 드래그 콜백 안에서 창을 띄우면 드래그 처리가 꼬일 수 있어 한 박자 늦춘다
            DispatchQueue.main.async { self?.showPopover() }
        }
        inputView.onDrop = { [weak self] urls in
            guard let self else { return }
            self.dropModel.deliver(urls)
            DispatchQueue.main.async { self.showPopover() }
        }
        button.addSubview(inputView)
    }

    private func configurePopover() {
        let size = NSSize(width: EdgePanelController.contentWidth, height: EdgePanelController.panelHeight)

        let hostingView = NSHostingView(
            rootView: ContentView()
                .environment(dropModel)
                .frame(width: size.width, height: size.height)
        )
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]

        // 팝오버 안에서도 파일 드롭은 AppKit 컨테이너 한 곳이 받는다 (가장자리 패널과 같은 방식)
        let container = DropContainerView(frame: NSRect(origin: .zero, size: size))
        container.dropModel = dropModel
        container.addSubview(hostingView)

        let viewController = NSViewController()
        viewController.view = container

        popover.contentViewController = viewController
        popover.contentSize = size
        // 메뉴 막대 아이콘을 다시 누를 때만 닫힌다.
        // (바깥 클릭으로 닫히는 기본 동작이면, Finder에서 파일을 끌어오려고 클릭하는 순간 닫혀서 다시 열어야 했음)
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
    }

    private func showMenu() {
        closePopover()
        let menu = NSMenu()
        let settings = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "파일패널 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        // 메뉴를 잠깐 붙였다가 떼는 방식이 메뉴 막대 아래 정확한 위치에 메뉴를 띄운다
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}

/// 메뉴 막대 버튼 위의 투명한 입력 뷰: 클릭, 우클릭(또는 Control+클릭), 파일 끌어오기/놓기
private final class StatusItemInputView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onDragEntered: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        onDragEntered?()
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}
#endif
