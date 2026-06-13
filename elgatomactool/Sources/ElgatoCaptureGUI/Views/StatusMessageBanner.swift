import SwiftUI

/// Error banner (red, with warning glyph) or transient status caption shown beneath
/// the controls. Observes only RecordingVM.
struct StatusMessageBanner: View {
    @ObservedObject var recording: RecordingVM

    var body: some View {
        if let error = recording.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(error)
                    .foregroundStyle(.red)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        } else if !recording.statusMessage.isEmpty {
            Text(recording.statusMessage)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
