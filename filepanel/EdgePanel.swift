#if os(macOS)
import AppKit
import SwiftUI

/// 패널을 붙일 화면 가장자리
enum PanelEdge: String, CaseIterable, Identifiable {
    case left, right

    var id: Self { self }

    var displayName: String {
        switch self {
        case .left: "왼쪽"
        case .right: "오른쪽"
        }
    }
}

/// 화면 가장자리에 책갈피처럼 붙어 있는 패널을 관리한다.
/// 탭은 항상 화면 끝에 고정되고, 펼치면 패널 폭이 화면 안쪽으로 늘어나며 카드가 드러난다.
/// (패널을 화면 밖으로 밀어내는 방식은 옆에 모니터가 있으면 내용이 비쳐 보여서 쓰지 않음)
@Observable
final class EdgePanelController {
    static let tabWidth: CGFloat = 26
    static let tabHeight: CGFloat = 76
    static let contentWidth: CGFloat = 320
    static let panelHeight: CGFloat = 416
    /// 탭과 카드 사이 간격. 카드가 네 모서리 모두 둥근 떠 있는 판처럼 보이게 한다.
    static let tabSpacing: CGFloat = 6
    static let fullWidth = tabWidth + tabSpacing + contentWidth

    /// 탭이 화면 위아래 끝에 딱 붙지 않도록 두는 여백
    private static let screenMargin: CGFloat = 8
    /// 공간이 충분할 때 카드 윗변에서 탭까지의 거리
    private static let preferredTabInset: CGFloat = 24

    private enum DefaultsKey {
        static let displayID = "EdgePanelDisplayID"
        static let edge = "EdgePanelEdge"
        static let verticalPosition = "EdgePanelVerticalPosition"
        static let tabVisible = "EdgePanelTabVisible"
    }

    private(set) var isExpanded = false

    /// 붙일 가장자리. 바꾸면 저장하고 바로 옮긴다.
    var edge: PanelEdge {
        didSet {
            UserDefaults.standard.set(edge.rawValue, forKey: DefaultsKey.edge)
            // 사용자가 모니터를 직접 고른 적이 없으면, 새 가장자리에 맞는 기본 모니터로 바꾼다
            if UserDefaults.standard.object(forKey: DefaultsKey.displayID) == nil {
                selectedDisplayID = defaultDisplayID()
            }
            applyLayout()
        }
    }

    /// 탭의 세로 위치. 0이면 화면 맨 위, 1이면 맨 아래. 탭을 끌어서 바꾼다.
    var verticalPosition: Double {
        didSet { applyLayout() }
    }

    /// 화면 가장자리 탭 표시 여부 (메뉴 막대만 쓰고 싶은 사용자를 위해 끌 수 있다)
    var isTabVisible: Bool {
        didSet {
            UserDefaults.standard.set(isTabVisible, forKey: DefaultsKey.tabVisible)
            updatePanelVisibility()
        }
    }

    /// 설정 창에서 메뉴 막대 아이콘 표시를 함께 다루기 위한 참조
    @ObservationIgnored weak var menuBar: MenuBarController?

    /// 패널 안에서 탭이 카드 윗변으로부터 떨어진 거리.
    /// 탭이 화면 위/아래 끝으로 가면 카드는 화면 안에 머물고 탭만 카드 옆을 따라 움직인다.
    private(set) var tabOffset: CGFloat = preferredTabInset

    private(set) var isDraggingTab = false

    /// 패널을 붙일 모니터. 사용자가 고르면 저장해서 다음 실행에도 유지한다.
    private(set) var selectedDisplayID: CGDirectDisplayID?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var hostingView: NSView?
    @ObservationIgnored private var settingsWindowController: SettingsWindowController?
    @ObservationIgnored private var screenObserver: Task<Void, Never>?
    @ObservationIgnored private var dragStart: (mouseY: CGFloat, tabTop: CGFloat)?
    /// 0이면 완전히 접힘(창 = 탭 크기), 1이면 완전히 펼침(창 = 카드 전체)
    @ObservationIgnored private var revealProgress: CGFloat = 0
    @ObservationIgnored private var revealTimer: Timer?
    /// 패널에 드롭된 파일을 카드(ContentView)로 전달한다
    @ObservationIgnored let dropModel = FileDropModel()
    @ObservationIgnored let launchAtLogin = LaunchAtLogin()
    @ObservationIgnored private var moveObserver: (any NSObjectProtocol)?
    /// 마지막으로 직접 지정한 창 프레임. 이와 다르게 움직였다면 외부에서 옮긴 것이다.
    @ObservationIgnored private var lastAppliedFrame: NSRect = .zero

    init() {
        let defaults = UserDefaults.standard
        edge = defaults.string(forKey: DefaultsKey.edge).flatMap(PanelEdge.init(rawValue:)) ?? .left
        verticalPosition = defaults.object(forKey: DefaultsKey.verticalPosition) as? Double ?? 0.5
        isTabVisible = defaults.object(forKey: DefaultsKey.tabVisible) as? Bool ?? true
    }

    /// 탭을 숨기면 접은 뒤 창을 내리고, 다시 보이면 가장자리에 띄운다
    private func updatePanelVisibility() {
        guard let panel else { return }
        if isTabVisible {
            applyLayout()
            panel.orderFrontRegardless()
        } else {
            revealTimer?.invalidate()
            isExpanded = false
            revealProgress = 0
            applyLayout()
            panel.orderOut(nil)
        }
    }

    func show() {
        selectedDisplayID = resolveDisplayID()

        let panel = EdgePanel()
        // 호스팅 뷰는 항상 펼친 크기로 고정하고, 창 크기만 바꿔서 보이는 부분을 잘라낸다.
        // (SwiftUI 정렬에 맡기면 창이 좁을 때 콘텐츠가 가운데 정렬돼 카드 중앙이 보이는 문제가 있었음)
        let hostingView = FirstMouseHostingView(rootView: EdgePanelView(controller: self))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.fullWidth, height: Self.panelHeight)

        // 파일 드롭은 패널 전체에서 이 컨테이너 한 곳이 받는다 (탭 위든 카드 위든)
        let container = DropContainerView()
        container.clipsToBounds = true
        container.dropModel = dropModel
        container.onDragEntered = { [weak self] in
            // 드래그 콜백 안에서 창 크기를 바꾸면 드래그 처리가 꼬이므로(kDragIPCWithinWindow 재진입),
            // 콜백이 끝난 뒤 애니메이션 없이 한 번에 펼친다
            DispatchQueue.main.async { self?.expandImmediately() }
        }
        container.addSubview(hostingView)
        panel.contentView = container
        self.panel = panel
        self.hostingView = hostingView

        applyLayout()
        if isTabVisible {
            panel.orderFrontRegardless()
        }

        // 해상도 변경, 모니터 연결/해제 시 가장자리에 다시 붙인다
        screenObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                guard let self else { return }
                self.selectedDisplayID = self.resolveDisplayID()
                self.applyLayout()
            }
        }

        // 시스템(창 이동·타일링 등)이 패널을 옮기면 즉시 설정된 가장자리로 되돌린다
        // (queue: nil → 알림을 보낸 그 자리에서 바로 실행돼, 옮겨진 위치가 화면에 그려지기 전에 되돌린다)
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: nil
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel, panel.frame != self.lastAppliedFrame else { return }
                self.applyLayout()
            }
        }
    }

    func toggle() {
        setExpanded(!isExpanded)
    }

    /// 파일을 끌고 들어왔을 때: 드래그 중 창 크기가 계속 바뀌지 않도록 애니메이션 없이 펼친다
    func expandImmediately() {
        guard !isExpanded, panel != nil else { return }
        isExpanded = true
        revealTimer?.invalidate()
        revealProgress = 1
        applyLayout()
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded, panel != nil else { return }
        isExpanded = expanded
        animateReveal(to: expanded ? 1 : 0)
    }

    // MARK: - 탭 누르기: 클릭이면 펼치기/접기, 끌면 세로 위치 이동

    /// 이만큼 움직이기 전까지는 클릭으로 본다
    private static let dragThreshold: CGFloat = 4

    /// 탭을 누른 순간. 누를 때마다 상태를 새로 시작해서, 이전 누르기가 어떻게 끝났든 영향이 없게 한다.
    /// (SwiftUI 제스처는 도중에 취소되면 onEnded가 안 불려 이전 시작점이 남고, 다음 클릭이 드래그로 오인됐음)
    func tabPressBegan() {
        dragStart = (NSEvent.mouseLocation.y, layout().tabTop)
        isDraggingTab = false
    }

    /// 탭을 누른 채 움직일 때마다 호출된다.
    /// 창이 드래그 중에 같이 움직이므로, 창 기준 좌표 대신 화면 기준 마우스 위치로 계산한다.
    func tabPressChanged() {
        let mouseY = NSEvent.mouseLocation.y
        guard let dragStart else { return }

        if !isDraggingTab {
            guard abs(mouseY - dragStart.mouseY) >= Self.dragThreshold else { return }
            isDraggingTab = true
        }

        guard let visibleFrame = currentScreen?.visibleFrame else { return }
        let travel = Self.tabTravel(in: visibleFrame)
        guard travel > 0 else { return }
        let tabTop = dragStart.tabTop + (mouseY - dragStart.mouseY)
        let highestTabTop = visibleFrame.maxY - Self.screenMargin
        verticalPosition = min(max((highestTabTop - tabTop) / travel, 0), 1)
    }

    /// 손을 뗐을 때: 끌었으면 위치 저장, 아니면 클릭으로 보고 바로 펼치기/접기
    func tabPressEnded() {
        guard dragStart != nil else { return }
        if isDraggingTab {
            UserDefaults.standard.set(verticalPosition, forKey: DefaultsKey.verticalPosition)
        } else {
            toggle()
        }
        dragStart = nil
        isDraggingTab = false
    }

    func resetVerticalPosition() {
        verticalPosition = 0.5
        UserDefaults.standard.set(verticalPosition, forKey: DefaultsKey.verticalPosition)
    }

    // MARK: - 설정 창

    func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(controller: self)
        }
        // 사용자가 시스템 설정에서 로그인 항목을 바꿨을 수 있으니 열 때마다 실제 상태를 다시 읽는다
        launchAtLogin.refresh()
        settingsWindowController?.present()
    }

    // MARK: - 모니터 선택

    var availableScreens: [(id: CGDirectDisplayID, name: String)] {
        NSScreen.screens.compactMap { screen in
            screen.displayID.map { ($0, screen.localizedName) }
        }
    }

    func moveToScreen(_ displayID: CGDirectDisplayID) {
        UserDefaults.standard.set(Int(displayID), forKey: DefaultsKey.displayID)
        selectedDisplayID = displayID
        applyLayout()
    }

    /// 고른 가장자리 바로 옆에 다른 모니터가 붙어 있는지.
    /// 이 경우 마우스가 옆 모니터로 넘어가버려서 탭을 찾기 어렵다.
    var edgeBordersAnotherScreen: Bool {
        guard let screen = currentScreen else { return false }
        return NSScreen.screens.contains { other in
            guard other.displayID != screen.displayID else { return false }
            let touches = switch edge {
            case .left: abs(other.frame.maxX - screen.frame.minX) < 1
            case .right: abs(other.frame.minX - screen.frame.maxX) < 1
            }
            let overlapsVertically = other.frame.maxY > screen.frame.minY && other.frame.minY < screen.frame.maxY
            return touches && overlapsVertically
        }
    }

    private var currentScreen: NSScreen? {
        NSScreen.screens.first { $0.displayID == selectedDisplayID } ?? NSScreen.screens.first
    }

    /// 저장된 모니터 → 현재 모니터 → 가장자리 기본 모니터 순으로 고른다
    private func resolveDisplayID() -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        if let saved = UserDefaults.standard.object(forKey: DefaultsKey.displayID) as? Int,
           screens.contains(where: { $0.displayID == CGDirectDisplayID(saved) }) {
            return CGDirectDisplayID(saved)
        }
        if let current = selectedDisplayID, screens.contains(where: { $0.displayID == current }) {
            return current
        }
        return defaultDisplayID()
    }

    /// 왼쪽이면 가장 왼쪽 모니터, 오른쪽이면 가장 오른쪽 모니터 (옆 모니터와 경계가 겹치지 않게)
    private func defaultDisplayID() -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        let screen = switch edge {
        case .left: screens.min { $0.frame.minX < $1.frame.minX }
        case .right: screens.max { $0.frame.maxX < $1.frame.maxX }
        }
        return screen?.displayID
    }

    // MARK: - 배치

    /// 현재 설정(가장자리, 세로 위치, 모니터)과 펼침 정도대로 패널을 즉시 옮긴다.
    /// 창은 접혔을 때 탭 크기, 펼쳤을 때 카드 전체 크기이고, 그 사이는 펼침 정도에 따라 보간한다.
    /// (창을 긴 막대 모양으로 두면 투명한 부분까지 그림자·유리 테두리가 그려져 이상한 선이 보였음)
    private func applyLayout() {
        guard let panel, let hostingView else { return }
        let layout = layout()
        if tabOffset != layout.tabOffset {
            tabOffset = layout.tabOffset
        }

        let windowFrame = Self.interpolate(from: layout.tabFrame, to: layout.panelFrame, progress: revealProgress)
        lastAppliedFrame = windowFrame
        panel.setFrame(windowFrame, display: true)

        // 호스팅 뷰는 화면 기준으로 항상 '펼친 패널' 자리에 고정해서, 창 크기가 바뀌어도 내용이 움직이지 않게 한다
        hostingView.setFrameOrigin(NSPoint(
            x: layout.panelFrame.minX - windowFrame.minX,
            y: layout.panelFrame.minY - windowFrame.minY
        ))
    }

    /// 펼침 정도를 목표값까지 부드럽게 바꾼다.
    /// 창 프레임과 호스팅 뷰 위치를 같은 프레임에서 함께 갱신해야 해서 AppKit 창 애니메이션 대신 직접 돌린다.
    private func animateReveal(to target: CGFloat) {
        revealTimer?.invalidate()
        let start = revealProgress
        let startTime = CACurrentMediaTime()
        let duration = 0.24

        // .common 모드에 등록해야 메뉴 추적 중 같은 상황에서도 멈추지 않는다
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let t = min((CACurrentMediaTime() - startTime) / duration, 1)
                let eased = 1 - pow(1 - t, 3) // ease-out cubic
                self.revealProgress = start + (target - start) * eased
                self.applyLayout()
                if t >= 1 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private static func interpolate(from: NSRect, to: NSRect, progress: CGFloat) -> NSRect {
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return NSRect(
            x: lerp(from.minX, to.minX),
            y: lerp(from.minY, to.minY),
            width: lerp(from.width, to.width),
            height: lerp(from.height, to.height)
        ).integral
    }

    /// 탭이 위아래로 움직일 수 있는 거리
    private static func tabTravel(in visibleFrame: NSRect) -> CGFloat {
        max(visibleFrame.height - tabHeight - screenMargin * 2, 0)
    }

    /// 탭 위치를 먼저 정하고, 카드는 탭 근처에 두되 화면 밖으로 나가지 않게 맞춘다
    private func layout() -> (panelFrame: NSRect, tabFrame: NSRect, tabOffset: CGFloat, tabTop: CGFloat) {
        let visibleFrame = currentScreen?.visibleFrame ?? .zero
        let panelX = switch edge {
        case .left: visibleFrame.minX
        case .right: visibleFrame.maxX - Self.fullWidth
        }
        let tabX = switch edge {
        case .left: visibleFrame.minX
        case .right: visibleFrame.maxX - Self.tabWidth
        }

        let tabTop = visibleFrame.maxY - Self.screenMargin - Self.tabTravel(in: visibleFrame) * verticalPosition
        let preferredPanelTop = tabTop + Self.preferredTabInset
        let panelTop = min(max(preferredPanelTop, visibleFrame.minY + Self.panelHeight), visibleFrame.maxY)

        let panelFrame = NSRect(x: panelX, y: panelTop - Self.panelHeight, width: Self.fullWidth, height: Self.panelHeight)
        let tabFrame = NSRect(x: tabX, y: tabTop - Self.tabHeight, width: Self.tabWidth, height: Self.tabHeight)
        return (panelFrame, tabFrame, panelTop - tabTop, tabTop)
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// 패널이 키 윈도우가 아닐 때도 첫 클릭을 창 활성화에 쓰지 않고 바로 버튼·탭에 전달한다.
/// (기본값이면 첫 클릭은 삼켜져서 탭을 두 번 눌러야 열렸음)
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // 투명한 뷰는 기본값이 true라 끌면 창 자체가 이동될 수 있다
    override var mouseDownCanMoveWindow: Bool { false }
}

/// 테두리 없이 항상 위에 떠 있고, 클릭해도 다른 앱의 포커스를 뺏지 않는 패널
private final class EdgePanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // 모든 데스크톱(Spaces)과 전체 화면 앱 위에서도 보이게
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        // 테두리 없는 투명 창에선 시스템 그림자가 창 사각형을 따라 검은 테두리처럼 그려져서 끈다.
        // 둥근 모서리와 가장자리 표현은 Liquid Glass가 담당한다.
        hasShadow = false
        hidesOnDeactivate = false
        // 사용자·시스템이 창을 끌어 옮기지 못하게 한다. 위치는 항상 컨트롤러가 정한다.
        isMovable = false
        isMovableByWindowBackground = false
        // 투명한 창은 기본적으로 '투명한 픽셀'을 클릭하면 뒤 창으로 클릭이 통과된다.
        // Liquid Glass는 창 서버에서 합성돼 창 픽셀상으론 거의 투명하므로,
        // 아이콘 옆 유리 부분을 누르면 클릭이 사라졌다. 명시적으로 꺼서 창 영역 전체가 클릭을 받게 한다.
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { true }
}

/// 탭 + 카드. 탭은 화면 끝 쪽에 오고, 패널 폭이 줄면 카드가 잘려서 탭만 보인다.
private struct EdgePanelView: View {
    let controller: EdgePanelController

    private static let cardCornerRadius: CGFloat = 20

    /// 화면 안쪽을 향한 모서리만 둥글게
    private func innerRoundedShape(radius: CGFloat) -> UnevenRoundedRectangle {
        switch controller.edge {
        case .left: UnevenRoundedRectangle(bottomTrailingRadius: radius, topTrailingRadius: radius)
        case .right: UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: EdgePanelController.tabSpacing) {
            switch controller.edge {
            case .left:
                tab
                card
            case .right:
                card
                tab
            }
        }
    }

    private var card: some View {
        // 탭과 떨어진 떠 있는 판이라 네 모서리 모두 둥글게.
        // Liquid Glass는 이 투명 창에서 활성화될 때 모양 밖 사각형까지 그려져 모서리가 각져 보였다(탭과 같은 문제).
        // 가장 얇은 머티리얼 + 반사광 + 빛 받는 테두리로 유리 느낌을 직접 만들고, 둥근 모양대로 잘라서
        // 모양 밖으로는 아무것도 그려지지 않게 한다.
        ContentView()
            .environment(controller.dropModel)
            .frame(width: EdgePanelController.contentWidth, height: EdgePanelController.panelHeight, alignment: .top)
            .background {
                ZStack {
                    // 뒤가 잘 비치는 얇은 블러
                    Rectangle().fill(.ultraThinMaterial)
                    // 유리 윗부분에 맺히는 은은한 반사광
                    LinearGradient(
                        colors: [.white.opacity(0.14), .white.opacity(0.03), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                }
            }
            .clipShape(.rect(cornerRadius: Self.cardCornerRadius))
            // 왼쪽 위에서 빛을 받는 듯한 유리 테두리 (위·왼쪽은 밝고 아래·오른쪽은 옅게)
            .overlay {
                RoundedRectangle(cornerRadius: Self.cardCornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.45), .white.opacity(0.10), .white.opacity(0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }

    private var closeSymbol: String {
        controller.edge == .left ? "chevron.left" : "chevron.right"
    }

    private var tab: some View {
        // 아이콘 하나로 상태를 표현: 접힘 = 앱 아이콘과 같은 변환 화살표, 펼침 = 닫는 방향 화살표.
        // 끌 수 있다는 건 손바닥 커서로 알려준다.
        Group {
            if controller.isExpanded {
                Image(systemName: closeSymbol)
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Image("ConvertArrows")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            }
        }
            .foregroundStyle(.white)
            .transition(.opacity)
            .frame(width: EdgePanelController.tabWidth, height: EdgePanelController.tabHeight)
            // 유리 틴트는 활성화될 때 모양 밖 사각형까지 그려져 각진 모서리가 겹쳐 보였다.
            // 강조 색 단색으로 채우고 모양대로 잘라서 둥근 모서리만 보이게 한다.
            .background(Color.accentColor.gradient)
            .clipShape(innerRoundedShape(radius: 9))
            .focusEffectDisabled()
            // 클릭·드래그·우클릭 메뉴·파일 끌어오기는 AppKit 뷰가 직접 받는다
            .overlay { TabMouseArea(controller: controller) }
            .padding(.top, controller.tabOffset)
    }
}

/// 패널 전체의 파일 드롭을 받는 컨테이너.
/// SwiftUI dropDestination과 탭의 드롭 처리가 따로 등록돼 서로 드래그를 가로채던 문제를 없애려고
/// 드롭은 이곳 한 군데서만 처리한다. (호스팅 뷰는 드래그 타입을 등록하지 않으므로 드래그가 여기까지 올라온다)
final class DropContainerView: NSView {
    var dropModel: FileDropModel?
    var onDragEntered: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        dropModel?.isTargeted = true
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropModel?.isTargeted == true ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropModel?.isTargeted = false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropModel?.isTargeted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropModel?.isTargeted = false
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        dropModel?.deliver(urls)
        return true
    }

    private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}

/// 탭의 마우스 입력을 AppKit 이벤트로 직접 받는다.
/// mouseDown/mouseUp은 누를 때마다 반드시 짝으로 오기 때문에, SwiftUI 제스처처럼 중간 취소로 상태가 꼬이지 않는다.
private struct TabMouseArea: NSViewRepresentable {
    let controller: EdgePanelController

    func makeNSView(context: Context) -> TabMouseView {
        let view = TabMouseView()
        view.controller = controller
        return view
    }

    func updateNSView(_ nsView: TabMouseView, context: Context) {
        nsView.controller = controller
    }
}

private final class TabMouseView: NSView {
    weak var controller: EdgePanelController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "클릭해서 열기 · 위아래로 끌어서 위치 이동"
        // 파일 드롭은 등록하지 않는다. 탭 위로 끌어온 파일은 DropContainerView가 받아서 패널을 펼친다.
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 패널이 키 윈도우가 아니어도 첫 클릭을 바로 받는다
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // 탭을 끄는 건 세로 위치 조절이지 창 이동이 아니다
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: 손쉬운 사용 (VoiceOver에서 탭을 버튼으로 읽고 누를 수 있게)

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        controller?.isExpanded == true ? "파일 변환 패널 닫기" : "파일 변환 패널 열기"
    }
    override func accessibilityPerformPress() -> Bool {
        controller?.toggle()
        return true
    }

    // MARK: 클릭 / 드래그

    override func mouseDown(with event: NSEvent) {
        // Control+클릭은 우클릭 메뉴로
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        controller?.tabPressBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.tabPressChanged()
        if controller?.isDraggingTab == true {
            NSCursor.closedHand.set()
        }
    }

    override func mouseUp(with event: NSEvent) {
        controller?.tabPressEnded()
        NSCursor.openHand.set()
    }

    // MARK: 커서 (패널이 키 윈도우가 아니어도 손바닥 커서가 보이게)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    // MARK: 우클릭 메뉴

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "파일패널 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @objc private func openSettings() {
        controller?.showSettings()
    }
}

#endif
