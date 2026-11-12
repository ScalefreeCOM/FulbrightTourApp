import SwiftUI
import UniformTypeIdentifiers
import StudyToursCore
#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
import AuthenticationServices
public typealias PlatformImage = UIImage
#endif

/// The few things that differ between the Mac and the iPad app.
enum Platform {
    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Mac screenshot mode for the README (opaque panels instead of glass).
    static var snapshotActive: Bool {
        #if os(macOS)
        Snapshot.active
        #else
        false
        #endif
    }

    @MainActor static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    @MainActor static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Shows a saved file: Finder on the Mac; nothing to do on the iPad (the Files app already has it).
    @MainActor static func reveal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    /// Whether the app is in front (the chat refreshes faster then).
    @MainActor static var isActive: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    static func image(_ img: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: img)
        #else
        Image(uiImage: img)
        #endif
    }

    static func image(contentsOf url: URL) -> PlatformImage? {
        #if os(macOS)
        NSImage(contentsOf: url)
        #else
        UIImage(contentsOfFile: url.path)
        #endif
    }

    static func cgImage(_ img: PlatformImage) -> CGImage? {
        #if os(macOS)
        img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        img.cgImage
        #endif
    }

    static func image(cgImage c: CGImage) -> PlatformImage {
        #if os(macOS)
        NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
        #else
        UIImage(cgImage: c)
        #endif
    }

    /// Lets the user save a generated file. Mac: Save dialog (Downloads by default). iPad: share sheet
    /// ("Save to Files", AirDrop, Mail …). Returns the saved/shared file, or nil if cancelled.
    @MainActor static func saveFile(_ data: Data, name: String, title: String) throws -> URL? {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: (name as NSString).pathExtension) ?? .data]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: [.atomic])
        reveal(url)
        return url
        #else
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }  // no copy left behind
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController else { return nil }
        var top = root; while let p = top.presentedViewController { top = p }
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(vc, animated: true)
        return url
        #endif
    }

    static func fontAvailable(_ name: String) -> Bool {
        #if os(macOS)
        NSFont(name: name, size: 12) != nil
        #else
        UIFont(name: name, size: 12) != nil
        #endif
    }
}

/// Resizable side-by-side panes on the Mac (HSplitView); fixed side-by-side on the iPad.
struct SplitPane<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(macOS)
        HSplitView { content }
        #else
        HStack(spacing: 0) { content }
        #endif
    }
}

#if os(iOS)
/// Sign-in on the iPad: the provider's page opens in an in-app browser sheet, so the app stays active and its
/// loopback receiver (http://localhost:<port>/callback — the same redirect the Mac app uses) gets the code.
/// The sheet is closed as soon as the code has arrived (or when the user cancels).
@MainActor final class InAppSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = InAppSignIn()
    private var session: ASWebAuthenticationSession?
    private var finished = false

    func start(_ url: URL, onCancel: @escaping () -> Void) {
        finished = false
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "fulbrighttours") { [weak self] _, error in
            if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                Task { @MainActor in if self?.finished == false { onCancel() } }   // the user closed the sheet
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    /// Called when the loopback receiver has the code.
    func finish() { finished = true; session?.cancel(); session = nil }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
#endif
