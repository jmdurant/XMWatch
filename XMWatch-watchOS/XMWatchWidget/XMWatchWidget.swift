import WidgetKit
import SwiftUI

struct XMWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> XMWatchEntry {
        XMWatchEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (XMWatchEntry) -> Void) {
        completion(XMWatchEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<XMWatchEntry>) -> Void) {
        let entry = XMWatchEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

struct XMWatchEntry: TimelineEntry {
    let date: Date
}

struct XMWatchWidgetEntryView: View {
    var entry: XMWatchProvider.Entry

    @Environment(\.widgetFamily) var widgetFamily

    var body: some View {
        switch widgetFamily {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "radio")
                    .font(.title2)
                    .widgetAccentable()
            }

        case .accessoryRectangular:
            HStack {
                Image(systemName: "radio")
                    .font(.title2)
                    .widgetAccentable()
                VStack(alignment: .leading) {
                    Text("XMWatch")
                        .font(.headline)
                        .widgetAccentable()
                    Text("Satellite Radio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .accessoryCorner:
            Image(systemName: "radio")
                .font(.title2)
                .widgetAccentable()
                .widgetLabel {
                    Text("XMWatch")
                }

        case .accessoryInline:
            Label("XMWatch", systemImage: "radio")

        @unknown default:
            Image(systemName: "radio")
                .font(.title2)
        }
    }
}

@main
struct XMWatchWidget: Widget {
    let kind: String = "XMWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: XMWatchProvider()) { entry in
            XMWatchWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("XMWatch")
        .description("Launch XMWatch satellite radio.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryCorner,
            .accessoryInline
        ])
    }
}
