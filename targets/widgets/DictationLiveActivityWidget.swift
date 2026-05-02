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
                        Image(systemName: "button.programmable")
                            .font(.title2)
                            .foregroundColor(.white)
                        Text("Hold\nto stop")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 12) {
                        if context.state.phase == "recording" {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text(timerInterval: context.state.startDate...Date.distantFuture, countsDown: false)
                                .font(.system(.title3, design: .monospaced).weight(.medium))
                                .foregroundColor(.white)
                                .monospacedDigit()
                        } else if context.state.phase == "processing" {
                            ProgressView()
                                .tint(.white)
                        } else if context.state.phase == "ready" {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    EmptyView()
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundColor(.white)
            } compactTrailing: {
                if context.state.phase == "recording" {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text(timerInterval: context.state.startDate...Date.distantFuture, countsDown: false)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundColor(.white)
                            .monospacedDigit()
                            .frame(width: 32)
                    }
                } else if context.state.phase == "processing" {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                } else if context.state.phase == "ready" {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                }
            } minimal: {
                Image(systemName: "waveform")
                    .foregroundColor(.white)
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
            Image(systemName: "waveform")
                .foregroundColor(.white)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                if state.phase == "recording" {
                    Text("Recording")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(timerInterval: state.startDate...Date.distantFuture, countsDown: false)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .monospacedDigit()
                } else if state.phase == "processing" {
                    Text("Transcribing...")
                        .font(.headline)
                        .foregroundColor(.white)
                } else if state.phase == "ready" {
                    Text("Done")
                        .font(.headline)
                        .foregroundColor(.white)
                }
            }
            Spacer()
            if state.phase == "processing" {
                ProgressView()
                    .tint(.white)
            } else if state.phase == "ready" {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.white)
            }
        }
        .padding(14)
    }
}
