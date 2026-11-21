import SwiftUI

enum UsageColors {
    static func bar(_ used: Double) -> Color {
        if used >= 90 { return .red }
        if used >= 75 { return .orange }
        return .accentColor
    }

    static func text(_ used: Double) -> Color {
        if used >= 90 { return .red }
        if used >= 75 { return .orange }
        return .primary
    }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    // View state is declared without the @State attribute on purpose: newer Apple
    // command line tools treat @State as a macro whose plugin only ships with Xcode.
    private let _range = State<HistoryRange>(initialValue: .day)
    private var range: HistoryRange {
        get { _range.wrappedValue }
        nonmutating set { _range.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let message = store.errorMessage {
                errorBanner(message)
            }
            if store.windows.isEmpty {
                emptyState
            } else {
                ForEach(store.visibleWindows) { window in
                    WindowRow(window: window, now: store.now)
                }
                Divider()
                historySection
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    private var subtitle: String {
        if settings.authMethod == .claudeCode { return store.sourceLabel }
        return settings.orgName
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude usage")
                    .font(.system(size: 14, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(BorderlessButtonStyle())
                .help("Refresh now")
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                if store.needsSignIn {
                    Button("Open Settings", action: onOpenSettings)
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    @ViewBuilder private var emptyState: some View {
        if store.isLoading {
            Text("Checking your usage…")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        } else if store.errorMessage == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your Claude account to see your limits here.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect account", action: onOpenSettings)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("History range", selection: _range.projectedValue) {
                    ForEach(HistoryRange.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .labelsHidden()
                .frame(width: 150)
            }
            HistoryChart(points: store.history.samples(in: range, now: store.now), range: range, now: store.now)
                .frame(height: 90)
            HStack(spacing: 14) {
                legend(color: .accentColor, label: "Session")
                legend(color: Color.primary.opacity(0.5), label: "Weekly")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(color)
                .frame(width: 12, height: 3)
            Text(label)
        }
    }

    private var footer: some View {
        HStack {
            Text("Leeway \(AppInfo.version) · \(TextFormat.updatedAgo(store.lastUpdated, now: store.now))")
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundColor(.secondary)
            Spacer()
            Button("Settings", action: onOpenSettings)
                .controlSize(.small)
            Button("Quit", action: onQuit)
                .controlSize(.small)
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let pace = window.pace(now: now)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(TextFormat.percent(window.used)) used")
                    .font(Font.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(UsageColors.text(window.used))
            }
            UsageBar(value: window.used, marker: window.elapsedFraction(now: now))
            HStack(alignment: .firstTextBaseline) {
                Text(resetText)
                    .foregroundColor(.secondary)
                Spacer()
                if let pace = pace {
                    Text(PaceText.text(for: pace, now: now))
                        .foregroundColor(PaceText.color(for: pace.level))
                }
            }
            .font(.system(size: 11))
        }
    }

    private var resetText: String {
        guard let reset = window.resetsAt, reset > now else { return TextFormat.resetLine(nil, now: now) }
        return "\(TextFormat.resetLine(reset, now: now)), in \(TextFormat.countdown(to: reset, now: now))"
    }
}

/// A usage bar with a tick that marks how much of the window has passed.
/// Fill to the left of the tick means you're under pace.
struct UsageBar: View {
    let value: Double
    let marker: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(UsageColors.bar(value))
                    .frame(width: CGFloat(min(max(value, 0), 100) / 100) * geometry.size.width)
                if let marker = marker {
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 2, height: geometry.size.height + 6)
                        .offset(x: CGFloat(marker) * geometry.size.width - 1)
                }
            }
        }
        .frame(height: 6)
        .help("The tick shows how much of this window has passed. Staying left of it means you're under pace.")
    }
}

enum PaceText {
    static func text(for pace: Pace, now: Date) -> String {
        switch pace.level {
        case .atLimit:
            return "Limit reached"
        case .runningOut:
            if let hit = pace.limitDate {
                return "Runs out around \(TextFormat.when(hit, now: now))"
            }
            return "Ahead of pace"
        case .tight:
            return "Cutting it close"
        case .steady:
            return "On pace"
        case .relaxed:
            return "Plenty left"
        }
    }

    static func color(for level: Pace.Level) -> Color {
        switch level {
        case .atLimit, .runningOut: return .red
        case .tight: return .orange
        case .steady, .relaxed: return .secondary
        }
    }
}

struct HistoryChart: View {
    let points: [HistoryPoint]
    let range: HistoryRange
    let now: Date

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach([0.0, 50.0, 100.0], id: \.self) { level in
                    gridLine(level, size: geometry.size)
                        .stroke(Color.primary.opacity(level == 0 ? 0.25 : 0.08), lineWidth: 1)
                }
                Text("100%")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .position(x: geometry.size.width - 14, y: yPosition(100, geometry.size) + 7)
                Text("50%")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .position(x: geometry.size.width - 12, y: yPosition(50, geometry.size) + 7)
                line(\.w, size: geometry.size)
                    .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                line(\.s, size: geometry.size)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if points.count < 2 {
                    Text("The chart fills in as Leeway runs.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
    }

    private func gridLine(_ level: Double, size: CGSize) -> Path {
        Path { path in
            let y = yPosition(level, size)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
    }

    private func line(_ key: KeyPath<HistoryPoint, Double?>, size: CGSize) -> Path {
        Path { path in
            let start = now.addingTimeInterval(-range.seconds)
            let gapLimit = max(3600, range.seconds / 48)
            var drawing = false
            var lastTime: Date? = nil
            for point in points {
                guard let value = point[keyPath: key] else {
                    drawing = false
                    continue
                }
                let x = CGFloat(point.t.timeIntervalSince(start) / range.seconds) * size.width
                let location = CGPoint(x: x, y: yPosition(value, size))
                let isGap = lastTime.map { point.t.timeIntervalSince($0) > gapLimit } ?? false
                if !drawing || isGap {
                    path.move(to: location)
                    drawing = true
                } else {
                    path.addLine(to: location)
                }
                lastTime = point.t
            }
        }
    }

    private func yPosition(_ value: Double, _ size: CGSize) -> CGFloat {
        let inset: CGFloat = 3
        let clamped = CGFloat(min(max(value, 0), 100))
        return inset + (size.height - inset * 2) * (1 - clamped / 100)
    }
}
