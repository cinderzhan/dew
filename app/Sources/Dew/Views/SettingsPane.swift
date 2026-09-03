import SwiftUI

/// 设置。刻意只放真正需要用户调的东西——
/// 每加一项都是在给「极简」这个卖点上税。
struct SettingsPane: View {
    @EnvironmentObject var settings: AppSettings
    let skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L(.opacity))
                    .font(Metrics.bodyFont)
                    .foregroundStyle(skin.dim)
                Spacer()
                Text("\(Int((settings.tintOpacity * 100).rounded()))%")
                    .font(Metrics.metaFont)
                    .foregroundStyle(skin.faint)
                    .monospacedDigit()
            }

            Slider(value: $settings.tintOpacity,
                   in: AppSettings.tintRange.lowerBound...AppSettings.tintRange.upperBound)
                .controlSize(.mini)
                .tint(skin.signal)

            Text(L(.opacityHint))
                .font(.system(size: 10))
                .foregroundStyle(skin.faint)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(L(.language))
                    .font(Metrics.bodyFont)
                    .foregroundStyle(skin.dim)
                Spacer()
                // 两个字的切换，做成一对小字而不是下拉：省一次点击，也少一个系统控件
                HStack(spacing: 3) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        let on = settings.language == lang
                        Button { settings.language = lang } label: {
                            Text(lang.displayName)
                                .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? skin.text : skin.faint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(on ? skin.selection : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 4)

            // 两个开关的说明都收进 tooltip：面板要留白，但读钥匙串凭据这种事
            // 不能只写在文档里，鼠标停一下就能看到。
            toggle(L(.launchAtLogin), help: L(.launchAtLoginHelp),
                   isOn: Binding(get: { settings.launchAtLogin },
                                 set: { settings.setLaunchAtLogin($0) }))
            toggle(L(.claudeUsageToggle), help: L(.claudeUsageExplain), isOn: $settings.claudeUsageAPIEnabled)
            toggle(L(.deepLinkToggle), help: L(.deepLinkExplain), isOn: $settings.importingDeepLinksEnabled)
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(skin.line).frame(height: 0.5) }
    }

    private func toggle(_ title: String, help: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(Metrics.bodyFont)
                .foregroundStyle(skin.dim)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(skin.signal)
        .padding(.top, 6)
        .help(help)
    }
}
