import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct DictationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            DictationBannerView(state: context.state)
                .widgetURL(URL(string: "codictateapp://dictation"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: context.state.phase == "recording" ? "mic.fill" : "waveform")
                            .foregroundColor(context.state.phase == "recording" ? .red : .white)
                            .font(.title2)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if context.state.phase == "recording" {
                            Text(timerInterval: context.state.startDate...Date.distantFuture, countsDown: false)
                                .font(.system(.title3, design: .monospaced).weight(.medium))
                                .foregroundColor(.white)
                                .monospacedDigit()
                        } else {
                            Text("Transcribing")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        Text("Codictate")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.phase == "recording" ? "Press Action Button to stop" : "Processing audio...")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.bottom, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.phase == "recording" ? "mic.fill" : "waveform")
                    .foregroundColor(context.state.phase == "recording" ? .red : .white)
            } compactTrailing: {
                if context.state.phase == "recording" {
                    Text(timerInterval: context.state.startDate...Date.distantFuture, countsDown: false)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundColor(.white)
                        .monospacedDigit()
                        .frame(width: 48)
                } else {
                    Text("...")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                }
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundColor(.red)
            }
            .widgetURL(URL(string: "codictateapp://dictation"))
        }
    }
}

@available(iOS 16.1, *)
private struct DictationBannerView: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.phase == "recording" ? "mic.fill" : "waveform")
                .foregroundColor(state.phase == "recording" ? .red : .white)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.phase == "recording" ? "Recording" : "Transcribing...")
                    .font(.headline)
                    .foregroundColor(.white)
                if state.phase == "recording" {
                    Text(timerInterval: state.startDate...Date.distantFuture, countsDown: false)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .monospacedDigit()
                }
            }
            Spacer()
            Text("Codictate")
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(14)
    }
}
