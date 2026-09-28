import SwiftUI

@main struct MyApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        // macOS에선 일반 창 없이 가장자리 패널·메뉴 막대만 띄운다. 설정 창은 AppKit으로 직접 관리한다.
        Settings { EmptyView() }
            .commands {
                // 설정 창이 열려 앱 메뉴가 보일 때 '설정…(⌘,)'이 빈 SwiftUI 설정 대신 우리 설정 창을 열게 한다
                CommandGroup(replacing: .appSettings) {
                    Button("설정…") { appDelegate.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
        #else
        WindowGroup {
            ContentView()
        }
        #endif
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panelController = EdgePanelController()
    /// 메뉴 막대 아이콘은 앱이 뜬 뒤에 만들어야 해서 실행 완료 시점에 생성한다
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Xcode 프리뷰·코드 실행용으로 뜬 복사본은 메뉴 막대 아이콘·탭을 만들지 않는다.
        // (만들면 프리뷰가 끝난 뒤에도 남아 아이콘이 두 개가 되거나, 실제 앱이 중복 실행으로 오인돼 꺼졌음)
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return
        }

        // 같은 앱이 이미 떠 있으면(예: 다운로드 폴더와 응용 프로그램 폴더에 하나씩 있는 경우)
        // 메뉴 막대 아이콘·가장자리 탭이 두 개씩 생기므로, 새로 뜬 쪽은 아무것도 만들지 않고 종료한다
        if isAnotherInstanceRunning {
            NSApp.terminate(nil)
            return
        }

        let menuBar = MenuBarController()
        menuBar.onOpenSettings = { [panelController] in panelController.showSettings() }
        panelController.menuBar = menuBar
        menuBarController = menuBar

        panelController.show()

        // 탭과 메뉴 막대 아이콘을 모두 꺼둔 상태로 실행하면 화면에 아무것도 안 보여 헷갈리므로 설정 창을 연다
        if !panelController.isTabVisible && !menuBar.isVisible {
            showSettings()
        }
        // 패널이 먼저 보이고 나서 물어봐야 무엇을 자동으로 열지 사용자가 알 수 있다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [panelController] in
            panelController.launchAtLogin.askIfNeeded()
        }
    }

    private var isAnotherInstanceRunning: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != currentPID && !$0.isTerminated }
    }

    func showSettings() {
        panelController.showSettings()
    }

    /// 이미 실행 중일 때 Finder·Launchpad·Spotlight에서 앱을 다시 열면 설정 창을 연다.
    /// 메뉴 막대 아이콘이나 탭을 숨겨도 언제든 설정에 들어올 수 있는 통로다. (Rectangle·BetterDisplay와 같은 방식)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
}
#endif
