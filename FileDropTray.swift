import SwiftUI
import UniformTypeIdentifiers

struct FileDropTray: View {
    @Binding var files: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(files, id: \.self) { url in
                        FileTrayItem(url: url)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onDrop(of: [.fileURL], delegate: FileDropDelegate { droppedURLs in
            for url in droppedURLs {
                if !files.contains(url) {
                    files.append(url)
                }
            }
        })
    }
}

struct FileTrayItem: View {
    let url: URL

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "doc.fill")
                .font(.title2)
                .foregroundStyle(.primary)

            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(width: 54)
        }
        .frame(width: 58, height: 52)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onDrag {
            let provider = NSItemProvider(object: url as NSURL)
            return provider
        }
    }
}

struct FileDropDelegate: DropDelegate {
    let onDrop: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        var urls: [URL] = []

        let providers = info.itemProviders(for: [.fileURL])

        for provider in providers {
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? URL {
                    urls.append(url)
                }
            }
        }

        DispatchQueue.main.async {
            self.onDrop(urls)
        }

        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }
}