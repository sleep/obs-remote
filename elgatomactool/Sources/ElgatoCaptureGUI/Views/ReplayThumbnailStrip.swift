import SwiftUI

/// Horizontal strip of replay-buffer thumbnails captured at 1Hz. Auto-scrolls to the
/// newest entry. Observes only ReplayBufferVM.
struct ReplayThumbnailStrip: View {
    @ObservedObject var replay: ReplayBufferVM

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(replay.replayThumbnails) { thumb in
                        VStack(spacing: 2) {
                            Image(nsImage: thumb.image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 80, height: 45)
                                .clipped()
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                                )
                            Text(ViewFormatters.thumbnailAgeLabel(thumb.capturedAt))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .id(thumb.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .frame(height: 68)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: replay.replayThumbnails.count) { _ in
                if let last = replay.replayThumbnails.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(last.id, anchor: .trailing)
                    }
                }
            }
        }
    }
}
