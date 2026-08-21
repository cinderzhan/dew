import Foundation

// MARK: - RRULE（Codex automations 用的 iCalendar 重复规则）

/// 只覆盖 automation.toml 里实际出现过的子集：
/// FREQ=DAILY/WEEKLY/HOURLY，配合 BYHOUR / BYMINUTE / BYDAY。
/// 遇到不认识的规则一律降级为「定时」+ nil，不猜、不崩。
enum RRule {
    private static func parts(_ rrule: String) -> [String: String] {
        let body = rrule.hasPrefix("RRULE:") ? String(rrule.dropFirst(6)) : rrule
        var out: [String: String] = [:]
        for piece in body.split(separator: ";") {
            let kv = piece.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[String(kv[0]).uppercased()] = String(kv[1])
        }
        return out
    }

    private static func ints(_ s: String?) -> [Int] {
        (s ?? "").split(separator: ",").compactMap { Int($0) }.sorted()
    }

    static func humanize(_ rrule: String) -> String {
        let p = parts(rrule)
        guard let freq = p["FREQ"]?.uppercased() else { return L(.scheduled) }

        let hours = ints(p["BYHOUR"])
        let minutes = ints(p["BYMINUTE"])
        let minute = minutes.first ?? 0

        let times = hours.map { String(format: "%02d:%02d", $0, minute) }.joined(separator: "、")

        switch freq {
        case "DAILY":
            return times.isEmpty ? L(.everyDay) : L(.everyDayAt, times)
        case "HOURLY":
            return L(.everyHour)
        case "WEEKLY":
            let days = (p["BYDAY"] ?? "").split(separator: ",").map(weekdayName).joined(separator: "、")
            let d = days.isEmpty ? L(.everyWeek) : L(.everyWeekOn, days)
            return times.isEmpty ? d : "\(d) \(times)"
        default:
            return L(.scheduled)
        }
    }

    private static func weekdayName(_ code: Substring) -> String {
        switch code.uppercased() {
        case "MO": return L(.wdMon); case "TU": return L(.wdTue); case "WE": return L(.wdWed)
        case "TH": return L(.wdThu); case "FR": return L(.wdFri); case "SA": return L(.wdSat)
        case "SU": return L(.wdSun); default: return String(code)
        }
    }

    static func nextRun(after now: Date, rrule: String) -> Date? {
        let p = parts(rrule)
        guard let freq = p["FREQ"]?.uppercased() else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        let hours = ints(p["BYHOUR"])
        let minutes = ints(p["BYMINUTE"])
        let minute = minutes.first ?? 0

        switch freq {
        case "HOURLY":
            return cal.nextDate(after: now,
                                matching: DateComponents(minute: minute),
                                matchingPolicy: .nextTime)

        case "DAILY", "WEEKLY":
            // 没给 BYHOUR 时，automations 的实际行为是「每天某个固定时刻」，
            // 我们无从得知具体几点，退化为次日同一时刻。
            let candidateHours = hours.isEmpty ? [cal.component(.hour, from: now)] : hours

            let weekdays: [Int] = (p["BYDAY"] ?? "").split(separator: ",").compactMap { code in
                switch code.uppercased() {
                case "SU": return 1; case "MO": return 2; case "TU": return 3
                case "WE": return 4; case "TH": return 5; case "FR": return 6
                case "SA": return 7; default: return nil
                }
            }

            var best: Date?
            for h in candidateHours {
                var comps = DateComponents(hour: h, minute: minute)
                if freq == "WEEKLY", weekdays.count == 1 { comps.weekday = weekdays[0] }
                if let d = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) {
                    if best == nil || d < best! { best = d }
                }
            }
            // 多个星期几时逐个求最近的
            if freq == "WEEKLY", weekdays.count > 1 {
                for wd in weekdays {
                    for h in candidateHours {
                        let comps = DateComponents(hour: h, minute: minute, weekday: wd)
                        if let d = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime),
                           best == nil || d < best! { best = d }
                    }
                }
            }
            return best

        default:
            return nil
        }
    }
}

// MARK: - Cron（Claude Code scheduled-tasks 用的 5 段式）

enum Cron {
    /// 逐分钟向前扫，最多 90 天。够覆盖日/周/月级任务，且开销可以忽略。
    static func nextRun(after now: Date, expression: String) -> Date? {
        let fields = expression.split(separator: " ").map(String.init)
        guard fields.count == 5 else { return nil }

        let minute = expand(fields[0], 0, 59)
        let hour   = expand(fields[1], 0, 23)
        let dom    = expand(fields[2], 1, 31)
        let month  = expand(fields[3], 1, 12)
        let dow    = expand(fields[4], 0, 6)
        guard !minute.isEmpty, !hour.isEmpty, !dom.isEmpty, !month.isEmpty, !dow.isEmpty else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        var t = cal.date(bySetting: .second, value: 0, of: now) ?? now
        t = t.addingTimeInterval(60)
        let limit = now.addingTimeInterval(90 * 24 * 3600)

        while t < limit {
            let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: t)
            let wd = ((c.weekday ?? 1) - 1) % 7   // Calendar 里周日=1，cron 里周日=0
            if minute.contains(c.minute ?? -1),
               hour.contains(c.hour ?? -1),
               month.contains(c.month ?? -1),
               dom.contains(c.day ?? -1),
               dow.contains(wd) {
                return t
            }
            t = t.addingTimeInterval(60)
        }
        return nil
    }

    /// 展开 `*` / `a,b` / `a-b` / `*/n` / `a-b/n`
    private static func expand(_ field: String, _ lo: Int, _ hi: Int) -> Set<Int> {
        var out = Set<Int>()
        for piece in field.split(separator: ",") {
            let (rangePart, step): (Substring, Int) = {
                if let slash = piece.firstIndex(of: "/") {
                    return (piece[piece.startIndex..<slash], Int(piece[piece.index(after: slash)...]) ?? 1)
                }
                return (piece, 1)
            }()
            guard step > 0 else { continue }

            var from = lo, to = hi
            if rangePart != "*" {
                if let dash = rangePart.firstIndex(of: "-") {
                    from = Int(rangePart[rangePart.startIndex..<dash]) ?? lo
                    to   = Int(rangePart[rangePart.index(after: dash)...]) ?? hi
                } else if let v = Int(rangePart) {
                    from = v; to = v
                } else { continue }
            }
            guard from <= to else { continue }
            out.formUnion(stride(from: max(from, lo), through: min(to, hi), by: step))
        }
        return out
    }

    static func humanize(_ expression: String) -> String {
        let f = expression.split(separator: " ").map(String.init)
        guard f.count == 5 else { return expression }
        let m = f[0], h = f[1], dom = f[2], mon = f[3], dow = f[4]
        guard let mi = Int(m), let hh = Int(h) else { return expression }
        let time = String(format: "%02d:%02d", hh, mi)
        if dom == "*", mon == "*", dow == "*" { return L(.everyDayAt, time) }
        if dom == "*", mon == "*", dow == "1-5" { return L(.weekdaysAt, time) }
        if dom == "*", mon == "*", let d = Int(dow) {
            let names: [L10n.Key] = [.wdSun, .wdMon, .wdTue, .wdWed, .wdThu, .wdFri, .wdSat]
            return L(.everyWeekOn, L(names[min(max(d, 0), 6)])) + " " + time
        }
        if mon == "*", let d = Int(dom) { return L(.everyMonthOn, d) + " " + time }
        return expression
    }
}

// MARK: - 展示用的相对时间

enum RelTime {
    static func untilText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = date.timeIntervalSince(now)
        if s < 0 { return L(.past) }
        if s < 60 { return L(.rightNow) }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        if days == 1 { return L(.tomorrow) }
        if days > 1 { return L(.daysLater, days) }

        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        if h > 0 { return L(.hoursLater, h) }
        return L(.minutesLater, m)
    }

    static func sinceText(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return L(.secondsAgo, Int(s)) }
        let m = Int(s) / 60
        if m < 60 { return L(.minutesAgo, m) }
        let h = m / 60
        if h < 24 { return L(.hoursAgo, h) }
        return L(.daysAgo, h / 24)
    }

    static func clockText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
