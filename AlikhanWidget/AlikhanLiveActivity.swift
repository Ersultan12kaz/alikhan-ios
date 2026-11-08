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
            LockScreenView(content: context.state)
                .activityBackgroundTint(Color.black.opacity(0.88))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(openURL)
        } dynamicIsland: { context in
            let s = OrbState(rawValue: context.state.state) ?? .sleep
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(s.dragon).resizable().scaledToFit().frame(width: 70, height: 48)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusMark(state: s).font(.title3).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.banner.isEmpty ? s.label : context.state.banner)
                        .font(.headline).foregroundStyle(s.accent).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Lines(content: context.state)
                }
            } compactLeading: {
                Image(s.dragon).resizable().scaledToFit().frame(width: 34, height: 24)
            } compactTrailing: {
                StatusMark(state: s)
            } minimal: {
                Image(s.dragon).resizable().scaledToFit().frame(width: 24, height: 20)
            }
            .widgetURL(openURL)
            .keylineTint(s.accent)
        }
    }
}

struct StatusMark: View {
    let state: OrbState
    var body: some View {
        Image(systemName: state.symbol).foregroundStyle(state.accent)
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
    var body: some View {
        let s = OrbState(rawValue: content.state) ?? .sleep
        HStack(spacing: 12) {
            Image(s.dragon).resizable().scaledToFit().frame(width: 76, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusMark(state: s)
                    Text(content.banner.isEmpty ? s.label : content.banner).font(.headline).foregroundStyle(s.accent)
                }
                Lines(content: content)
            }
        }
        .padding(14)
    }
}
