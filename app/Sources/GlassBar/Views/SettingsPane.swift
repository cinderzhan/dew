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

            // Claude 官方额度：默认关。说明写在开关旁边，不藏在文档里。
            VStack(alignment: .leading, spacing: 5) {
                Toggle(isOn: $settings.claudeUsageAPIEnabled) {
                    Text(L(.claudeUsageToggle))
                        .font(Metrics.bodyFont)
                        .foregroundStyle(skin.dim)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(skin.signal)

                Text(L(.claudeUsageExplain))
                    .font(.system(size: 10))
                    .foregroundStyle(skin.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(skin.line).frame(height: 0.5) }
    }
}
