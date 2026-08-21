import SwiftUI

struct UsageTab: View {
    @EnvironmentObject var agents: AgentStore
    @EnvironmentObject var settings: AppSettings
    let skin: Skin

    var body: some View {
        // 显式容器，理由同 AgentsTab
        VStack(alignment: .leading, spacing: 0) {
            if agents.quotas.isEmpty {
                EmptyHint(text: L(.emptyUsage), skin: skin)
            } else {
                ForEach(agents.quotas) { quota in
                    QuotaBlock(quota: quota, skin: skin)
                }

                if !settings.claudeUsageAPIEnabled {
                    Text(L(.claudeUsageOffHint))
                        .font(.system(size: 10))
                        .foregroundStyle(skin.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Metrics.hPad)
                        .padding(.top, 12)
                }
                if agents.quotas.contains(where: { $0.windows.contains { $0.usedPercent == nil } }) {
                    Text(L(.usageLocalNote))
                        .font(.system(size: 10))
                        .foregroundStyle(skin.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Metrics.hPad)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuotaBlock: View {
    let quota: AgentQuota
    let skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 5) {
            Text(quota.kind.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(skin.text)
            if let plan = quota.planType {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(skin.faint)
                Text(plan)
                    .font(.system(size: 11))
                    .foregroundStyle(skin.dim)
            }
            Spacer()
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.top, 14)
        .padding(.bottom, 6)

        ForEach(quota.windows) { w in
            WindowRow(window: w, skin: skin)
        }
        }
    }
}

/// 一行 = 名称 + 重置时间 + 百分比，下面压一条进度条。
/// 拿不到百分比时退化成 token 数字，并且**不画条**——
/// 画一条没有分母的进度条是在骗人。
struct WindowRow: View {
    let window: QuotaWindow
    let skin: Skin

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(Metrics.bodyFont)
                    .foregroundStyle(skin.text)

                Spacer(minLength: 8)

                if let r = window.resetsAt {
                    Text(resetText(r))
                        .font(Metrics.metaFont)
                        .foregroundStyle(skin.faint)
                        .monospacedDigit()
                }

                if let pct = window.usedPercent {
                    Text("\(Int(pct.rounded()))%")
                        .font(Metrics.bodyFont)
                        .foregroundStyle(skin.dim)
                        .monospacedDigit()
                } else if let total = window.totalTokens {
                    Text(total.compactTokens)
                        .font(Metrics.bodyFont)
                        .foregroundStyle(skin.dim)
                        .monospacedDigit()
                }
            }

            if let pct = window.usedPercent {
                Meter(fraction: pct / 100, critical: window.isCritical, skin: skin)
            } else if let out = window.outputTokens {
                Text(L(.usageOutput, out.compactTokens))
                    .font(.system(size: 10))
                    .foregroundStyle(skin.faint)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 5)
    }

    /// 24 小时内报时刻，更久报天数——跟 Claude 自己的写法保持一致
    private func resetText(_ date: Date) -> String {
        let s = date.timeIntervalSinceNow
        if s <= 0 { return L(.resetDone) }
        if s < 24 * 3600 {
            let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
            return h > 0 ? L(.resetInHM, L(.hoursAgo, h) + " " + L(.minutesAgo, m)) : L(.resetInM, m)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.current == .zh ? "zh_CN" : "en_US")
        f.dateFormat = "EEEE HH:mm"
        return L(.resetAt, f.string(from: date))
    }
}

struct Meter: View {
    let fraction: Double
    var critical: Bool = false
    let skin: Skin

    /// 用量条不该抢「等你介入」的信号色。只有接口报警、或逼近上限时才升级——
    /// 那时候它确实是一件需要你知道的事。
    private var color: Color { critical ? skin.signal : skin.dim }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(skin.line)
                Capsule().fill(color)
                    .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}
