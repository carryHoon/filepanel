#if os(macOS)
import AppKit
import ServiceManagement

/// '로그인 시 자동으로 열기' 설정.
/// 상태는 항상 시스템(SMAppService)에서 읽는다. 사용자가 시스템 설정 → 로그인 항목에서
/// 직접 끄거나 켤 수 있어서, 앱에 따로 저장해 두면 실제 상태와 어긋나기 때문이다.
@Observable
final class LaunchAtLogin {
    private static let hasAskedKey = "HasAskedLaunchAtLogin"

    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }

    /// 등록은 됐지만 사용자가 시스템 설정에서 허용해야 실제로 실행되는 상태
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                if status != .enabled { try SMAppService.mainApp.register() }
            } else if status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - 첫 실행 안내

    /// 처음 실행했을 때 한 번만 물어본다. 사용자 동의 없이 자동 실행을 켜지 않는다.
    /// - Returns: 이번에 물어봤는지 (= 첫 실행인지)
    @discardableResult
    func askIfNeeded() -> Bool {
        refresh()
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.hasAskedKey), !isEnabled else { return false }
        // 답을 고르기 전에 앱이 종료돼도 다시 묻지 않도록 먼저 기록한다
        defaults.set(true, forKey: Self.hasAskedKey)

        let alert = NSAlert()
        alert.messageText = "로그인할 때 파일패널을 자동으로 열까요?"
        alert.informativeText = "켜 두면 Mac을 켤 때마다 화면 가장자리에 탭이 바로 나타나요.\n나중에 탭을 우클릭 → 설정에서 언제든 바꿀 수 있어요."
        alert.addButton(withTitle: "자동으로 열기")
        alert.addButton(withTitle: "나중에")

        // Dock 아이콘 없는 앱이라 먼저 활성화해야 안내 창이 다른 앱 뒤에 숨지 않는다
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return true }
        setEnabled(true)

        // 켜기로 했는데 실패했거나 추가 승인이 필요하면, 조용히 넘어가지 않고 알려준다
        if let lastError {
            let failure = NSAlert()
            failure.messageText = "자동 실행을 켜지 못했어요"
            failure.informativeText = "\(lastError)\n탭을 우클릭 → 설정에서 다시 시도할 수 있어요."
            failure.runModal()
        } else if needsApproval {
            let approval = NSAlert()
            approval.messageText = "시스템 설정에서 허용이 필요해요"
            approval.informativeText = "시스템 설정 → 일반 → 로그인 항목에서 파일패널을 허용하면 자동으로 열려요."
            approval.addButton(withTitle: "로그인 항목 열기")
            approval.addButton(withTitle: "닫기")
            if approval.runModal() == .alertFirstButtonReturn {
                openLoginItemsSettings()
            }
        }
        return true
    }
}
#endif
