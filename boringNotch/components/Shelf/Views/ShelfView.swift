//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    @State private var hostWindow: NSWindow?
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .environmentObject(vm)
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
        .background(WindowReader { hostWindow = $0 })
        .onDisappear {
            ShelfKeyboardController.shared.deactivate()
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                vm.dragDetectorTargeting
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                content
                    .padding()
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selection.clear()
                ShelfKeyboardController.shared.activate(in: hostWindow)
            }
            .contextMenu {
                Button("Select All") {
                    ShelfActionService.selectAll()
                    ShelfKeyboardController.shared.activate(in: hostWindow)
                }
                .keyboardShortcut("a")
                .disabled(tvm.isEmpty)
                Button("Paste") {
                    ShelfActionService.paste()
                }
                .keyboardShortcut("v")
                .disabled(!ShelfActionService.canPaste)
                Divider()
                Button("Clear Shelf", role: .destructive) {
                    ShelfActionService.clearShelf()
                }
                .disabled(tvm.isEmpty)
            }
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)
                    
                    Text("Drop files here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(tvm.items) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}

// MARK: - Keyboard

/// Gives the shelf keyboard focus after a click in it, so ⌘A / ⌘C / ⌘X / ⌘V / ⌫ work, and
/// hands focus back to the frontmost app when the shelf goes away.
@MainActor
final class ShelfKeyboardController {
    static let shared = ShelfKeyboardController()

    private weak var window: BoringNotchSkyLightWindow?
    private var monitor: Any?

    func activate(in window: NSWindow?) {
        guard let window = window as? BoringNotchSkyLightWindow else { return }
        if self.window !== window {
            deactivate()
        }
        self.window = window
        window.acceptsKeyboardFocus = true
        window.makeKey()
        installMonitor()
    }

    func deactivate() {
        removeMonitor()
        guard let window else { return }
        self.window = nil
        window.acceptsKeyboardFocus = false
        guard window.isKeyWindow else { return }
        window.resignKey()
        // The notch panel never activates the app, so give the keyboard back to the app in front
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost != NSRunningApplication.current {
            frontmost.activate()
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  !(window.firstResponder is NSText) else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Returns true when the event was handled.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        // ⌘ like everywhere on macOS; ⌃ too for muscle memory from other systems
        if flags == .command || flags == .control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": ShelfActionService.selectAll()
            case "c": ShelfActionService.copySelection()
            case "x": ShelfActionService.cutSelection()
            case "v": ShelfActionService.paste()
            default: return false
            }
            return true
        }

        let deleteKey: UInt16 = 51, forwardDeleteKey: UInt16 = 117, escapeKey: UInt16 = 53
        if flags.isEmpty || flags == .command {
            switch event.keyCode {
            case deleteKey, forwardDeleteKey:
                ShelfActionService.removeSelection()
                return true
            case escapeKey where flags.isEmpty:
                ShelfSelectionModel.shared.clear()
                return true
            default:
                break
            }
        }
        return false
    }
}

/// Reports the NSWindow hosting a SwiftUI view.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [onWindow] in onWindow?(window) }
        }
    }
}
