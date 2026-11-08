import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AlikhanWidgetBundle: WidgetBundle {
    var body: some Widget {
        AlikhanLiveActivity()
    }
}

private let openURL = URL(string: "alikhan://open")

struct AlikhanLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlikhanAttributes.self) { context in
            LockScreenView(content: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(openURL)
        } dynamicIsland: { context in
            let s = OrbState(rawValue: context.state.state) ?? .sleep
            let stale = context.isStale   // Қосымша жабық: айдаһар сұр
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(s.dragon).resizable().scaledToFit().frame(width: 120, height: 80).grayscale(stale ? 1 : 0).opacity(stale ? 0.5 : 1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusMark(state: s, stale: stale).font(.title3).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(stale ? "Алихан жабық, ашыңыз" : (context.state.banner.isEmpty ? s.label : context.state.banner))
                        .font(.headline).foregroundStyle(stale ? Color.gray : s.accent).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Lines(content: context.state)
                }
            } compactLeading: {
                Image(s.islandDragon).resizable().scaledToFit().frame(width: 60, height: 36).grayscale(stale ? 1 : 0).opacity(stale ? 0.5 : 1)
            } compactTrailing: {
                StatusMark(state: s, stale: stale)
            } minimal: {
                Image(s.islandDragon).resizable().scaledToFit().frame(width: 40, height: 30).grayscale(stale ? 1 : 0).opacity(stale ? 0.5 : 1)
            }
            .widgetURL(openURL)
            .keylineTint(s.accent)
        }
    }
}

struct StatusMark: View {
    let state: OrbState
    var stale = false
    var body: some View {
        Image(systemName: stale ? "moon.zzz" : state.symbol).foregroundStyle(stale ? Color.gray : state.accent)
    }
}

struct Lines: View {
    let content: AlikhanAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !content.heard.isEmpty {
                Text("Сіз: \(content.heard)").font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            if !content.said.isEmpty {
                Text(content.said).font(.callout).foregroundStyle(.white).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LockScreenView: View {
    let content: AlikhanAttributes.ContentState
    var stale = false
    var body: some View {
        let s = OrbState(rawValue: content.state) ?? .sleep
        HStack(spacing: 12) {
            Image(s.dragon).resizable().scaledToFit().frame(width: 110, height: 74).grayscale(stale ? 1 : 0).opacity(stale ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusMark(state: s, stale: stale)
                    Text(stale ? "Алихан жабық, ашыңыз" : (content.banner.isEmpty ? s.label : content.banner))
                        .font(.headline).foregroundStyle(stale ? Color.gray : s.accent)
                }
                Lines(content: content)
            }
        }
        .padding(14)
    }
}
