#if os(macOS)
import AppKit
import SwiftUI

/// 설정 창. macOS 표준인 툴바 탭(일반 · 가장자리 탭 · 정보) 방식이다.
/// 창이 열려 있는 동안만 일반 앱처럼 Dock·메뉴 막대에 나타나서 ⌘W로 닫고 ⌘Q로 종료할 수 있고,
/// 닫으면 다시 백그라운드(Dock 아이콘 없음)로 돌아간다. (Rectangle·BetterDisplay와 같은 방식)
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(controller: EdgePanelController) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.tab("일반", symbol: "gearshape", GeneralSettingsView(controller: controller)))
        tabs.addTabViewItem(Self.tab("가장자리 탭", symbol: "sidebar.left", EdgeTabSettingsView(controller: controller)))
        tabs.addTabViewItem(Self.tab("정보", symbol: "info.circle", AboutSettingsView()))

        let window = SettingsWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        // 설정 창이 떠 있는 동안에는 Dock·메뉴 막대에 앱을 보여준다
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 창을 닫으면 다시 Dock 아이콘 없는 백그라운드 앱으로
        NSApp.setActivationPolicy(.accessory)
    }

    /// 탭마다 내용 크기에 맞춰 창 높이가 바뀌도록 SwiftUI 뷰를 담는다
    private static func tab(_ label: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        // 탭 컨트롤러가 선택된 탭의 제목을 창 제목으로 쓴다 (없으면 'Untitled'로 보임)
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}

/// ⌘W로 닫히는 설정 창.
/// 이 앱은 일반 창이 없어 SwiftUI 기본 메뉴에 '닫기(⌘W)' 항목이 없을 수 있으므로 창이 직접 처리한다.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
#endif
