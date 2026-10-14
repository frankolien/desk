import UIKit

/// Desk hides the navigation bar on its pages and draws its own back button, and UIKit turns the
/// back swipe off with the bar. This turns it back on for every stack: from the left edge, and on
/// iOS 26 from anywhere on the page, as long as there is a page to go back to.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        if #available(iOS 26.0, *) { interactiveContentPopGestureRecognizer?.delegate = self }
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1 && transitionCoordinator == nil
    }
}
