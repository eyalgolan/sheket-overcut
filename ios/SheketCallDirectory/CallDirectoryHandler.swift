import CallKit
import Foundation
import SheketCore

/// Installs the blocked numbers from the app group's Call Directory file.
///
/// Every request is a full load. A missing file installs zero entries. A
/// corrupt or unreadable file, or no app group, cancels the request so iOS
/// keeps the entries it installed before.
final class CallDirectoryHandler: CXCallDirectoryProvider {
    private enum CallDirectoryHandlerError: Error {
        case noAppGroup
        case unreadable
    }

    override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        guard let container = AppGroup.containerURL() else {
            context.cancelRequest(withError: CallDirectoryHandlerError.noAppGroup)
            return
        }

        if context.isIncremental {
            context.removeAllBlockingEntries()
        }

        let url = container.appendingPathComponent(BlocklistStore.callDirectoryFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            context.completeRequest()
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch CocoaError.fileReadNoSuchFile {
            // Removed between the check and the read.
            context.completeRequest()
            return
        } catch {
            context.cancelRequest(withError: CallDirectoryHandlerError.unreadable)
            return
        }

        do {
            try CallDirectoryEntries.forEachEntry(in: data) {
                context.addBlockingEntry(withNextSequentialPhoneNumber: $0)
            }
        } catch {
            // Entries may already have been added; cancelling discards them.
            context.cancelRequest(withError: error)
            return
        }
        context.completeRequest()
    }
}
