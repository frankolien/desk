import SafariServices
import SwiftUI

/// Apple's in-app Safari: native privacy controls, cookies and dismissal behavior,
/// while keeping the user inside Desk's setup flow.
struct InAppSafari: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .done
        controller.preferredControlTintColor = .white
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
