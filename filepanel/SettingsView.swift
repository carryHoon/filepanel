#if os(macOS)
import AppKit
import SwiftUI

/// 모든 탭이 같은 폭을 쓰도록
private let settingsWidth: CGFloat = 460

// MARK: - 일반

struct GeneralSettingsView: View {
    let controller: EdgePanelController

    private var launchAtLogin: LaunchAtLogin { controller.launchAtLogin }

    var body: some View {
        Form {
            Section {
                Toggle("로그인 시 자동으로 열기", isOn: launchAtLoginBinding)
            } footer: {
                Group {
                    if launchAtLogin.needsApproval {
                        // 등록은 됐지만 시스템 설정에서 허용해야 실제로 실행된다
                        VStack(alignment: .leading, spacing: 4) {
                            Label("시스템 설정에서 허용해야 자동으로 열려요.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("로그인 항목 설정 열기") { launchAtLogin.openLoginItemsSettings() }
                                .buttonStyle(.link)
                        }
                    } else if let error = launchAtLogin.lastError {
                        Label("설정을 바꾸지 못했어요: \(error)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("시스템 설정 → 일반 → 로그인 항목에서도 바꿀 수 있어요.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }

            Section {
                Toggle("화면 가장자리 탭", isOn: Binding(
                    get: { controller.isTabVisible },
                    set: { controller.isTabVisible = $0 }
                ))

                if let menuBar = controller.menuBar {
                    Toggle("메뉴 막대 아이콘", isOn: Binding(
                        get: { menuBar.isVisible },
                        set: { menuBar.isVisible = $0 }
                    ))
                }
            } header: {
                Text("표시 위치")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    // 둘 다 꺼도 된다. 앱을 다시 열면 이 설정 창이 열리므로 언제든 되돌릴 수 있다.
                    if isEverythingHidden {
                        Label("지금은 탭과 메뉴 막대 아이콘이 모두 꺼져 있어서 변환 화면을 열 수 없어요.", systemImage: "eye.slash")
                            .foregroundStyle(.orange)
                        if launchAtLogin.isEnabled || launchAtLogin.needsApproval {
                            Text("로그인 시 자동 실행이 켜져 있어서, 로그인할 때마다 보이지 않게 실행돼요.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Finder나 Spotlight에서 앱을 다시 열면 언제든 이 설정 창이 열려요.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 승인 대기 중이어도 사용자가 켠 상태로 보이게 한다 (끄면 등록 해제)
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled || launchAtLogin.needsApproval },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private var isEverythingHidden: Bool {
        !controller.isTabVisible && !(controller.menuBar?.isVisible ?? false)
    }
}

// MARK: - 가장자리 탭

struct EdgeTabSettingsView: View {
    @Bindable var controller: EdgePanelController

    var body: some View {
        Form {
            Section {
                Picker("가장자리", selection: $controller.edge) {
                    ForEach(PanelEdge.allCases) { edge in
                        Text(edge.displayName).tag(edge)
                    }
                }
                .pickerStyle(.segmented)

                Picker("모니터", selection: displayBinding) {
                    ForEach(controller.availableScreens, id: \.id) { screen in
                        Text(screen.name).tag(Optional(screen.id))
                    }
                }

                LabeledContent("세로 위치") {
                    Button("가운데로 되돌리기") { controller.resetVerticalPosition() }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !controller.isTabVisible {
                        Label("가장자리 탭이 꺼져 있어요. 일반 탭에서 켤 수 있어요.", systemImage: "eye.slash")
                            .foregroundStyle(.secondary)
                    }
                    Text("탭을 위아래로 끌면 원하는 위치로 옮길 수 있어요.")
                        .foregroundStyle(.secondary)
                    if controller.edgeBordersAnotherScreen {
                        Label(
                            "이 가장자리 바로 옆에 다른 모니터가 있어서, 마우스가 넘어가 탭을 누르기 어려울 수 있어요.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }
            .disabled(!controller.isTabVisible)
        }
        .formStyle(.grouped)
        .frame(width: settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var displayBinding: Binding<CGDirectDisplayID?> {
        Binding(
            get: { controller.selectedDisplayID },
            set: { newValue in
                if let newValue { controller.moveToScreen(newValue) }
            }
        )
    }
}

// MARK: - 정보

struct AboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "버전 \(short) (\(build))"
    }

    /// 받을 수 있는 형식 (HTML은 결과로만 만들 수 있다)
    private var inputSummary: (images: String, documents: String) {
        let inputs = ImageFormat.allCases.filter { $0 != .html }
        let documents = inputs.filter { $0.isDocument || $0 == .pdf }
        let images = inputs.filter { !documents.contains($0) }
        return (images.map(\.displayName).joined(separator: ", "), documents.map(\.displayName).joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("파일패널")
                            .font(.title3.weight(.semibold))
                        Text(version)
                            .foregroundStyle(.secondary)
                        Text("화면 가장자리나 메뉴 막대에서 바로 여는 파일 변환기")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("받는 형식") {
                LabeledContent("이미지") {
                    Text(inputSummary.images).multilineTextAlignment(.trailing)
                }
                LabeledContent("문서") {
                    Text(inputSummary.documents).multilineTextAlignment(.trailing)
                }
            }

            Section("변환 결과") {
                ForEach(ImageFormat.outputSections(for: [ImageFormat]()), id: \.title) { section in
                    LabeledContent(section.title) {
                        Text(section.formats.map(\.displayName).joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("파일패널 종료") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("일반") {
    GeneralSettingsView(controller: EdgePanelController())
}

#Preview("일반 · 모두 꺼짐") {
    let controller = EdgePanelController()
    controller.isTabVisible = false
    return GeneralSettingsView(controller: controller)
}

#Preview("가장자리 탭") {
    EdgeTabSettingsView(controller: EdgePanelController())
}

#Preview("정보") {
    AboutSettingsView()
}
#endif
