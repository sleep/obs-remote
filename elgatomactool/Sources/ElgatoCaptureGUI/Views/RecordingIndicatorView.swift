import SwiftUI

/// "REC <duration>" pill shown when recording. Observes only RecordingVM.
struct RecordingIndicatorView: View {
    @ObservedObject var recording: RecordingVM

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 10, height: 10)
            Text("REC")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
            Text(ViewFormatters.formatRecordingDuration(recording.recordingDuration))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
    }
}
