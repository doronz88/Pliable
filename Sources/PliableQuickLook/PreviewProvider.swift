import Foundation
import PliableCore
import QuickLookUI
import UniformTypeIdentifiers

/// Data-based Quick Look preview: shows the plist as an HTML tree instead of the built-in raw text view.
/// The explicit ObjC name is what NSExtensionPrincipalClass in QuickLook-Info.plist refers to.
@objc(PliablePreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let title = url.lastPathComponent
        let html: String
        // An error page reads better in Quick Look than the generic failure shown for a thrown error.
        do {
            html = PlistHTML.render(try PlistFile.read(Data(contentsOf: url)), title: title)
        } catch {
            html = PlistHTML.errorPage(title: title, message: error.localizedDescription)
        }
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { reply in
            reply.stringEncoding = .utf8
            return Data(html.utf8)
        }
    }
}
