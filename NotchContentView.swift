import SwiftUI

struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .overlay(
                    LinearGradient(
                        colors: [Color.white.opacity(0.24), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )

            HStack(spacing: 14) {
                if let art = viewModel.coverArt {
                    Image(nsImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 62, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(width: 62, height: 62)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.trackTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(viewModel.artist)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.78))
                        .lineLimit(1)

                    Text(viewModel.album)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    controlButton(symbol: "backward.fill", action: viewModel.previousTrack)
                    controlButton(symbol: viewModel.isPlaying ? "pause.fill" : "play.fill", action: viewModel.togglePlayPause)
                    controlButton(symbol: "forward.fill", action: viewModel.nextTrack)
                }

                FileDropTray(files: $viewModel.droppedFiles)
                    .frame(width: 120)

                Button(action: {
                    NSApp.terminate(nil)
                }) {
                    Text("Quit")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(height: 24)
                        .background(Color.red.opacity(0.7))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 420, height: 110)
    }

    private func controlButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 28, height: 28)
                .foregroundColor(.white)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
