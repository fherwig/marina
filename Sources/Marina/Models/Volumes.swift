import Foundation
import AppKit
import Combine

/// A place that is a drive rather than a folder: a mounted volume, or the local
/// root of a cloud provider.
struct Volume: Identifiable, Hashable {
    enum Kind: Hashable {
        case startup        // the boot volume
        case internalDisk   // another partition of a built-in disk
        case external       // anything attached: USB, Thunderbolt, a disk image
        case network        // an SMB/AFP/NFS share
        case cloud          // a file-provider root under ~/Library/CloudStorage
    }

    let url: URL
    let name: String
    /// The second line: free space for a real volume, the account for a cloud
    /// root. Nil when there is nothing to add.
    let caption: String?
    let kind: Kind
    /// Whether to offer Eject. Not `volumeIsEjectableKey`: an external
    /// Thunderbolt SSD reports removable = false, ejectable = false and Finder
    /// ejects it anyway (measured on this machine). Anything that is neither
    /// the startup disk nor internal can be unmounted.
    let ejectable: Bool

    var id: String { url.path }

    var symbol: String {
        switch kind {
        case .startup, .internalDisk: return "internaldrive"
        case .external: return "externaldrive"
        case .network: return "externaldrive.connected.to.line.below"
        case .cloud: return url.lastPathComponent.hasPrefix("com~apple~") ? "icloud" : "cloud"
        }
    }
}

/// One list for the whole app, shared by every window — the same arrangement as
/// FavouritesStore. Unlike the Claude sessions this is not a snapshot the user
/// has to ask for again: mounting and unmounting announce themselves, so the
/// section keeps up on its own.
@MainActor
final class VolumesStore: ObservableObject {
    static let shared = VolumesStore()

    @Published private(set) var volumes: [Volume] = []
    private var scanned = false

    private init() {
        let centre = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// Guide mode only: show these instead of the machine's real disks.
    func stage(_ demo: [Volume]) {
        volumes = demo
        scanned = true
    }

    func refresh() {
        guard !GuideShots.isActive else { return }   // its disks are staged
        // off the main actor: mountedVolumeURLs blocks on a stalled network
        // mount, and that would be the whole UI
        Task.detached(priority: .userInitiated) {
            let found = VolumeScan.volumes()
            await MainActor.run { [weak self] in self?.volumes = found }
        }
    }

    /// The first look, once per launch.
    func refreshIfNeeded() {
        guard !scanned else { return }
        scanned = true
        refresh()
    }
}

/// Finds everything that deserves a row in the Volumes section.
///
/// Two quite different things end up side by side. Real volumes come from
/// `mountedVolumeURLs`, which hides the system's own (`/System/Volumes/VM` and
/// friends) when asked to skip hidden ones. Cloud drives are not volumes at
/// all: OneDrive, Google Drive and the rest are file-provider roots that live
/// as directories in `~/Library/CloudStorage`, so they have to be listed
/// separately — which is also why `/Users/…/OneDrive - University of Victoria`
/// in the home folder is only a symlink to one.
enum VolumeScan {
    /// Set on a live file-provider root, absent on the orphaned directories a
    /// provider leaves behind when it re-registers (measured: those show the
    /// same mode, device and Spotlight kind, so nothing else tells them apart).
    private static let domainAttribute = "com.apple.file-provider-domain-id"

    static func volumes() -> [Volume] {
        mounted() + cloud()
    }

    // MARK: - Mounted volumes

    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey,
        .volumeIsBrowsableKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
    ]

    private static func mounted() -> [Volume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> Volume? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            // not browsable means the user has no business opening it
            guard values?.volumeIsBrowsable != false else { return nil }
            let isStartup = url.path == "/"
            let isInternal = values?.volumeIsInternal ?? false
            let isLocal = values?.volumeIsLocal ?? true
            let kind: Volume.Kind = isStartup ? .startup
                : !isLocal ? .network
                : isInternal ? .internalDisk : .external
            return Volume(
                url: url,
                name: values?.volumeLocalizedName ?? url.lastPathComponent,
                caption: free(values),
                kind: kind,
                ejectable: !isStartup && !isInternal)
        }
    }

    private static func free(_ values: URLResourceValues?) -> String? {
        // the "important usage" figure is the one Finder quotes: what you could
        // actually write, purgeable space included
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage
                ?? values?.volumeAvailableCapacity.map(Int64.init),
              bytes > 0 else { return nil }   // "Zero KB free" says nothing
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useTB]
        return "\(formatter.string(fromByteCount: bytes)) free"
    }

    // MARK: - Cloud roots

    private static func cloud() -> [Volume] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out: [Volume] = []

        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) {
            // the one cloud root macOS does give a real name for
            let name = (try? iCloud.resourceValues(forKeys: [.localizedNameKey]))?
                .localizedName ?? "iCloud Drive"
            // ~/Library/Mobile Documents is behind Full Disk Access, so say on
            // the row that opening it will show nothing. access() is enough to
            // tell (measured: EPERM there, fine on the other cloud roots) and
            // unlike the Desktop/Documents classes this one never prompts, so
            // asking costs nothing.
            let readable = access(iCloud.path, R_OK | X_OK) == 0
            out.append(Volume(url: iCloud, name: name,
                              caption: readable ? nil : "needs Full Disk Access",
                              kind: .cloud, ejectable: false))
        }

        let storage = home.appendingPathComponent("Library/CloudStorage")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: storage, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let domain = domainID(of: url) else { continue }
            let (name, caption) = label(folder: url.lastPathComponent, domain: domain)
            out.append(Volume(url: url, name: name, caption: caption, kind: .cloud, ejectable: false))
        }
        return out
    }

    private static func domainID(of url: URL) -> String? {
        let size = getxattr(url.path, domainAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, domainAttribute, &buffer, size, 0, XATTR_NOFOLLOW) == size else {
            return nil
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// The directory is named `Provider-Account` — `OneDrive-UniversityofVictoria`
    /// — and nothing reports the name Finder shows (localizedName, displayName
    /// and kMDItemDisplayName were all measured handing back the raw name). The
    /// provider's domain id sometimes carries the human one, so prefer it:
    /// OneDrive's is literally "OneDrive - University of Victoria", while Google
    /// Drive's is an opaque `gdrive-1073…`.
    private static func label(folder: String, domain: String) -> (String, String?) {
        let identifier = domain.split(separator: "/", maxSplits: 1).last.map(String.init) ?? domain
        if let range = identifier.range(of: " - ") {
            return (String(identifier[..<range.lowerBound]),
                    String(identifier[range.upperBound...]))
        }
        guard let dash = folder.firstIndex(of: "-") else { return (folder, nil) }
        return (String(folder[..<dash]), String(folder[folder.index(after: dash)...]))
    }
}
