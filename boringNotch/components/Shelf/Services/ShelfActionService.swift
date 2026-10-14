//
//  ShelfActionService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-07.
//

import AppKit
import Foundation

/// A service providing common actions for `ShelfItem`s, such as opening, revealing, or copying paths.
@MainActor
enum ShelfActionService {

    static func open(_ item: ShelfItem) {
        switch item.kind {
        case .file(let bookmark):
            handleBookmarkedFile(bookmark) { url in
                NSWorkspace.shared.open(url)
            }
        case .link(let url):
            NSWorkspace.shared.open(url)
        case .text(let string):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    }

    static func reveal(_ item: ShelfItem) {
        guard case .file(let bookmark) = item.kind else { return }
        handleBookmarkedFile(bookmark) { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    static func copyPath(_ item: ShelfItem) {
        guard case .file(let bookmark) = item.kind else { return }
        handleBookmarkedFile(bookmark) { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }

    static func remove(_ item: ShelfItem) {
        ShelfStateViewModel.shared.remove(item)
    }

    // MARK: Selection & clipboard (⌘A / ⌘C / ⌘X / ⌘V, Clear)

    private static var selectedItems: [ShelfItem] {
        ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
    }

    /// Files copied to the pasteboard keep their security-scoped access until the next copy,
    /// so they can still be pasted in Finder.
    private static var copiedURLs: [URL] = []

    static func selectAll() {
        ShelfSelectionModel.shared.selectAll(ShelfStateViewModel.shared.items)
    }

    static func copySelection() {
        copy(selectedItems)
    }

    /// Copies the selection, then takes it off the shelf (the files themselves are untouched).
    static func cutSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        copy(items)
        // Keep temporary files on disk: they're on the pasteboard now
        ShelfStateViewModel.shared.remove(items, cleanup: false)
        ShelfSelectionModel.shared.clear()
    }

    static func removeSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        ShelfStateViewModel.shared.remove(items)
        ShelfSelectionModel.shared.clear()
    }

    static func clearShelf() {
        ShelfStateViewModel.shared.remove(ShelfStateViewModel.shared.items)
        ShelfSelectionModel.shared.clear()
    }

    static var canPaste: Bool {
        let pb = NSPasteboard.general
        return pb.canReadObject(forClasses: [NSURL.self, NSString.self], options: nil)
            || pb.availableType(from: [.png, .tiff]) != nil
    }

    static func copy(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        for url in copiedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        copiedURLs.removeAll()

        var objects: [NSPasteboardWriting] = []
        for item in items {
            switch item.kind {
            case .file:
                if let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) {
                    if url.startAccessingSecurityScopedResource() {
                        copiedURLs.append(url)
                    }
                    objects.append(url as NSURL)
                }
            case .link(let url):
                objects.append(url as NSURL)
            case .text(let string):
                objects.append(string as NSString)
            }
        }
        guard !objects.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(objects)
    }

    /// Adds the pasteboard's files, links, text or image to the shelf.
    static func paste() {
        let pb = NSPasteboard.general
        var newItems: [ShelfItem] = []

        let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        for url in urls {
            if url.isFileURL {
                if let bookmark = try? Bookmark(url: url) {
                    newItems.append(ShelfItem(kind: .file(bookmark: bookmark.data)))
                }
            } else if url.scheme != nil {
                newItems.append(ShelfItem(kind: .link(url: url)))
            }
        }

        if newItems.isEmpty, let imageData = pngData(from: pb) {
            Task {
                guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
                    for: .data(imageData, suggestedName: "Pasted Image.png")),
                    let bookmark = try? Bookmark(url: tempURL) else { return }
                ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)])
            }
            return
        }

        if newItems.isEmpty, let string = pb.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newItems.append(ShelfItem(kind: .text(string: string)))
        }

        ShelfStateViewModel.shared.add(newItems)
    }

    private static func pngData(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func handleBookmarkedFile(_ bookmarkData: Data, action: @escaping @Sendable (URL) -> Void) {
        Task {
            let bookmark = Bookmark(data: bookmarkData)
            if let url = bookmark.resolveURL() {
                url.accessSecurityScopedResource { accessibleURL in
                    action(accessibleURL)
                }
            }
        }
    }
}

