import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
private struct ProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.35), value: progress)
        }
    }
}

// 0→0.95 over 15 s while processing; 1.0 when ready; 0 otherwise.
@available(iOS 16.1, *)
private func processingProgress(for state: DictationActivityAttributes.ContentState, at date: Date) -> Double {
    switch state.phase {
    case "processing":
        guard let start = state.processingStartDate else { return 0.0 }
        return min(date.timeIntervalSince(start) / 15.0, 0.95)
    case "ready":
        return 1.0
    default:
        return 0.0
    }
}

@available(iOS 16.1, *)
struct DictationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            DictationBannerView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: context.state.phase == "standby" ? "waveform" : "button.programmable")
                            .font(.title2)
                            .foregroundColor(.white)
                        Text(context.state.phase == "standby" ? "Ready" : "Hold\nto stop")
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
                            TimelineView(.periodic(from: context.state.startDate, by: 1)) { tl in
                                Text("\(Int(tl.date.timeIntervalSince(context.state.startDate)))s")
                                    .font(.system(.title3, design: .monospaced).weight(.medium))
                                    .foregroundColor(.white)
                                    .monospacedDigit()
                            }
                        } else if context.state.phase == "processing" {
                            TimelineView(.periodic(from: context.state.processingStartDate ?? Date(), by: 0.5)) { tl in
                                ProgressRing(
                                    progress: processingProgress(for: context.state, at: tl.date),
                                    lineWidth: 3
                                )
                                .frame(width: 28, height: 28)
                            }
                        } else if context.state.phase == "ready" {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        } else if context.state.phase == "standby" {
                            Image(systemName: "waveform")
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
                        TimelineView(.periodic(from: context.state.startDate, by: 1)) { tl in
                            Text("\(Int(tl.date.timeIntervalSince(context.state.startDate)))s")
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundColor(.white)
                                .monospacedDigit()
                                .frame(minWidth: 32)
                        }
                    }
                } else if context.state.phase == "processing" {
                    TimelineView(.periodic(from: context.state.processingStartDate ?? Date(), by: 0.5)) { tl in
                        ProgressRing(
                            progress: processingProgress(for: context.state, at: tl.date),
                            lineWidth: 2.5
                        )
                        .frame(width: 20, height: 20)
                    }
                } else if context.state.phase == "ready" {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                } else if context.state.phase == "standby" {
                    EmptyView()
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                }
            }             minimal: {
                Image(systemName: "waveform")
                    .foregroundColor(.white)
            }
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
                    TimelineView(.periodic(from: state.startDate, by: 1)) { tl in
                        Text("\(Int(tl.date.timeIntervalSince(state.startDate)))s")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                } else if state.phase == "processing" {
                    Text("Preparing speech model...")
                        .font(.headline)
                        .foregroundColor(.white)
                    if let message = state.statusMessage, !message.isEmpty {
                        Text(message)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    } else {
                        Text("Transcribing...")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                } else if state.phase == "ready" {
                    Text("Done")
                        .font(.headline)
                        .foregroundColor(.white)
                } else if state.phase == "standby" {
                    Text("Ready")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Listening for the keyboard")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            Spacer()
            if state.phase == "processing" {
                TimelineView(.periodic(from: state.processingStartDate ?? Date(), by: 0.5)) { tl in
                    ProgressRing(
                        progress: processingProgress(for: state, at: tl.date),
                        lineWidth: 3
                    )
                    .frame(width: 28, height: 28)
                }
            } else if state.phase == "ready" {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.white)
            } else if state.phase == "standby" {
                Image(systemName: "waveform")
                    .foregroundColor(.white)
            }
        }
        .padding(14)
    }
}
