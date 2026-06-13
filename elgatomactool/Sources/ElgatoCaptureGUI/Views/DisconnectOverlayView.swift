import SwiftUI

/// Full-frame "Device disconnected" overlay shown atop the frozen buffer when the
/// capture device drops off USB. Pure presentation; takes no observed state.
struct DisconnectOverlayView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.6))
            VStack(spacing: 12) {
                Image(systemName: "cable.connector.slash")
                    .font(.system(size: 36))
                    .foregroundStyle(.yellow)
                Text("Device disconnected")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("Buffer preserved — you can still save replays")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
