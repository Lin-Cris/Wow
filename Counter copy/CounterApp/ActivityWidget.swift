import ActivityKit
import SwiftUI
import WidgetKit

struct CounterActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CounterLiveAttributes.self) { context in
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(context.state.categoryAsset)
                        .resizable().scaledToFit().frame(width: 30, height: 30)
                    Text("待记账")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(context.state.status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(context.state.amount)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                    Spacer()
                    Text("建议分类  \(context.state.category)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .activityBackgroundTint(Color.white)
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(CounterActivityController.draftURL(context.state.draftID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(context.state.categoryAsset)
                        .resizable().scaledToFit().frame(width: 34, height: 34)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.amount)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("待记账")
                        .font(.system(size: 16, weight: .semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.status)
                        Spacer()
                        Text("建议分类  \(context.state.category)")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(context.state.categoryAsset)
                    .resizable().scaledToFit().frame(width: 20, height: 20)
            } compactTrailing: {
                Text(context.state.amount.replacingOccurrences(of: "¥", with: ""))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            } minimal: {
                Image(context.state.categoryAsset)
                    .resizable().scaledToFit().frame(width: 20, height: 20)
            }
            .widgetURL(CounterActivityController.draftURL(context.state.draftID))
            .keylineTint(Color(red: 0.98, green: 0.75, blue: 0.0))
        }
    }
}

@main
struct CounterWidgetBundle: WidgetBundle {
    var body: some Widget { CounterActivityWidget() }
}
