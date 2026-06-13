import SwiftUI
import AppKit

/// Card overlay shown for ~15s after a screenshot / replay / recording is
/// saved. Surfaces filename + size and provides Open / Show-in-Finder. Wraps
/// the ToastVM so callers just need `SaveToastView(toast: vm.toast)`.
struct SaveToastView: View {
    @ObservedObject var toast: ToastVM

    var body: some View {
        ZStack {
            if let current = toast.current {
                SaveToastCard(toast: current, onDismiss: { toast.dismiss() })
                    .id(current.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast.current?.id)
    }
}

private struct SaveToastCard: View {
    let toast: SaveToast
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: toast.iconSystemName)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(toast.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.kindLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(toast.filename)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(formatBytes(toast.sizeBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 240, alignment: .leading)

            HStack(spacing: 6) {
                Button("Open") { open() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button {
                    showInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show in Finder")
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private func open() {
        NSWorkspace.shared.open(toast.url)
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([toast.url])
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
