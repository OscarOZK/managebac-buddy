// ManageBac 菜单栏快捷入口
// 菜单栏显示 📂，点击展开一个小面板，面板里有一个液态玻璃按钮，
// 点击按钮 → 打开桌面上的完整看板 App。

import SwiftUI
import AppKit

// 完整看板 App 的位置（走 $HOME 推导 + 环境变量可覆盖，不写死用户名）
private let kAppPath: String = ProcessInfo.processInfo.environment["MBB_DASHBOARD_APP"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/APP/ManageBac看板.app")
// 兜底：如果 App 找不到，就直接开本机看板页面
private let kWebURL = "http://127.0.0.1:8765/app"

@main
struct MBMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra {
            PanelView()
        } label: {
            Text("📂")
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var online = false
    @State private var confirmingQuit = false     // 点 ✕ 后进入二次确认

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            GlassEffectContainer(spacing: 18) {
                if confirmingQuit {
                    confirmBar
                } else {
                    openButton
                }
            }

            footer
        }
        .padding(20)
        .frame(width: 460)
        .task { await ping() }
    }

    // MARK: - 顶部标题

    private var header: some View {
        HStack(spacing: 11) {
            Text("📂")
                .font(.system(size: 24))
            VStack(alignment: .leading, spacing: 3) {
                Text("ManageBac")
                    .font(.system(size: 16, weight: .semibold))
                Text("快捷入口")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Circle()
                    .fill(online ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(online ? "服务在线" : "服务待机")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            // 退出按钮：同样是液态玻璃
            Button(action: { confirmingQuit = true }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help("退出菜单栏应用")
        }
    }

    // MARK: - 主按钮

    private var openButton: some View {
        Button(action: openDashboard) {
            HStack(spacing: 13) {
                Text("📊")
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 3) {
                    Text("打开完整看板")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("待办 · 课程 · 成绩")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 74)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }

    // MARK: - 退出二次确认（同一块玻璃，高度一致，面板不会跳）

    private var confirmBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("确定退出菜单栏应用？")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("退出后菜单栏图标会消失")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("取消") { confirmingQuit = false }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(.capsule)
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(.capsule)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 74)
        .contentShape(.rect(cornerRadius: 20))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    // MARK: - 底部说明

    private var footer: some View {
        Text(confirmingQuit
             ? "点「退出」关闭本应用，点「取消」返回。"
             : "点击上方按钮打开完整应用，数据会自动刷新。")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 动作

    private func openDashboard() {
        if FileManager.default.fileExists(atPath: kAppPath) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: kAppPath),
                                               configuration: cfg) { _, _ in }
        } else if let web = URL(string: kWebURL) {
            NSWorkspace.shared.open(web)
        }
        // 用 SwiftUI 官方的方式收起面板（切 App 本身也会让它自动消失）
        dismiss()
    }

    // MARK: - 探测本机服务是否在线（失败就静默当作待机）

    private func ping() async {
        guard let url = URL(string: "http://127.0.0.1:8765/api/health") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.2
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let ok = (try? await URLSession.shared.data(for: req))
            .map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
        await MainActor.run { online = ok }
    }
}
