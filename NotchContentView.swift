import SwiftUI
import UniformTypeIdentifiers

struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.trackTitle)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(viewModel.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 12) {
                        Button(action: {
                            viewModel.previousTrack()
                        }) {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            viewModel.togglePlayPause()
                        }) {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            viewModel.nextTrack()
                        }) {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 0)

                        Button(action: {
                            NSApp.terminate(nil)
                        }) {
                            Text("Quit")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(height: 26)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                FileDropTray(files: $viewModel.droppedFiles)
                    .frame(width: 170)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 420, height: 90)
    }
}
