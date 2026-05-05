import Foundation
import Darwin

final class FolderWatcher {
    private struct WatchRegistration {
        let url: URL
        let fileDescriptor: CInt
        let source: DispatchSourceFileSystemObject
    }

    private let queue = DispatchQueue(label: "com.capture-your-screen.folder-watcher", qos: .utility)
    private var registrations: [WatchRegistration] = []

    var onChange: (() -> Void)?
    private(set) var watchedFolderURL: URL?

    var isWatching: Bool {
        !registrations.isEmpty
    }

    func start(watching folderURL: URL) {
        stop()

        let standardizedRoot = folderURL.standardizedFileURL
        let urlsToWatch = watchedURLs(for: standardizedRoot)
        guard !urlsToWatch.isEmpty else { return }

        var newRegistrations: [WatchRegistration] = []
        for url in urlsToWatch {
            guard let registration = makeRegistration(for: url) else { continue }
            newRegistrations.append(registration)
        }

        guard !newRegistrations.isEmpty else { return }

        registrations = newRegistrations
        watchedFolderURL = standardizedRoot

        for registration in registrations {
            registration.source.resume()
        }
    }

    func stop() {
        watchedFolderURL = nil

        let activeRegistrations = registrations
        registrations.removeAll()

        for registration in activeRegistrations {
            registration.source.cancel()
        }
    }

    deinit {
        stop()
    }

    private func watchedURLs(for rootURL: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        let childDirectories = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?
            .compactMap { url -> URL? in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true ? url.standardizedFileURL : nil
            } ?? []

        return [rootURL] + childDirectories
    }

    private func makeRegistration(for folderURL: URL) -> WatchRegistration? {
        let fileDescriptor = open(folderURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.onChange?()
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        return WatchRegistration(url: folderURL, fileDescriptor: fileDescriptor, source: source)
    }
}
