import SwiftUI
import UIKit

class PageHostingController: UIHostingController<AnyView> {
    var pageIndex: Int
    
    init(pageIndex: Int, rootView: AnyView) {
        self.pageIndex = pageIndex
        super.init(rootView: rootView)
        self.view.backgroundColor = .clear
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct BookPagerView<Content: View>: UIViewControllerRepresentable {
    var pageCount: Int
    @Binding var currentPage: Int
    var isDoubleSided: Bool // True if landscape iPad
    var overlayRevision: Int = 0
    var isPencilModeActive: Bool = false
    
    @ViewBuilder var content: (Int) -> Content
    
    func makeUIViewController(context: Context) -> UIPageViewController {
        // Use pageCurl on iPad for the book feel, scroll on iPhone to avoid
        // gesture conflicts with WKWebView's scroll view
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        let style: UIPageViewController.TransitionStyle = isIPad ? .pageCurl : .scroll
        let pvc = UIPageViewController(
            transitionStyle: style,
            navigationOrientation: .horizontal,
            options: [UIPageViewController.OptionsKey.interPageSpacing: 16]
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 1)
        return pvc
    }
    
    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        
        // Avoid resetting view controllers while the user is mid-swipe.
        if context.coordinator.pendingPage != nil {
            return
        }
        
        let currentVCs = uiViewController.viewControllers ?? []
        
        if isDoubleSided {
            let leftPage = currentPage % 2 == 1 ? currentPage : max(1, currentPage - 1)
            let rightPage = leftPage + 1
            
            var needsUpdate = true
            if currentVCs.count == 2,
               let leftVC = currentVCs[0] as? PageHostingController,
               let rightVC = currentVCs[1] as? PageHostingController {
                if leftVC.pageIndex == leftPage && rightVC.pageIndex == rightPage {
                    let shouldRefreshContent =
                        context.coordinator.lastLeftPage != leftPage
                        || context.coordinator.lastRightPage != rightPage
                        || context.coordinator.lastOverlayRevision != overlayRevision
                        || context.coordinator.lastPencilModeActive != isPencilModeActive
                    if shouldRefreshContent {
                        leftVC.rootView = AnyView(content(leftPage))
                        if rightPage <= pageCount {
                            rightVC.rootView = AnyView(content(rightPage))
                        }
                        context.coordinator.lastLeftPage = leftPage
                        context.coordinator.lastRightPage = rightPage
                        context.coordinator.lastOverlayRevision = overlayRevision
                        context.coordinator.lastPencilModeActive = isPencilModeActive
                    }
                    needsUpdate = false
                }
            }
            
            if needsUpdate {
                let dir: UIPageViewController.NavigationDirection = (leftPage >= context.coordinator.lastPage) ? .forward : .reverse
                context.coordinator.lastPage = leftPage
                context.coordinator.lastLeftPage = leftPage
                context.coordinator.lastRightPage = rightPage
                context.coordinator.lastOverlayRevision = overlayRevision
                context.coordinator.lastPencilModeActive = isPencilModeActive
                
                let leftVC = context.coordinator.createVC(page: leftPage)
                let rightVC = context.coordinator.createVC(page: rightPage)
                
                if uiViewController.spineLocation == .mid {
                    uiViewController.setViewControllers([leftVC, rightVC], direction: dir, animated: false)
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    context.coordinator.preloadNeighbors()
                }
            }
        } else {
            var needsUpdate = true
            if currentVCs.count == 1,
               let vc = currentVCs[0] as? PageHostingController {
                if vc.pageIndex == currentPage {
                    let shouldRefreshContent =
                        context.coordinator.lastSinglePage != currentPage
                        || context.coordinator.lastOverlayRevision != overlayRevision
                        || context.coordinator.lastPencilModeActive != isPencilModeActive
                    if shouldRefreshContent {
                        vc.rootView = AnyView(content(currentPage))
                        context.coordinator.lastSinglePage = currentPage
                        context.coordinator.lastOverlayRevision = overlayRevision
                        context.coordinator.lastPencilModeActive = isPencilModeActive
                    }
                    needsUpdate = false
                }
            }
            
            if needsUpdate {
                let dir: UIPageViewController.NavigationDirection = (currentPage >= context.coordinator.lastPage) ? .forward : .reverse
                // Phone: slide programmatic jumps (jump-to-page, sync catch-up)
                // instead of snapping. Not on the very first presentation
                // (lastSinglePage == -1), and left untouched on iPad.
                let animateJump = UIDevice.current.userInterfaceIdiom == .phone
                    && context.coordinator.lastSinglePage != -1
                context.coordinator.lastPage = currentPage
                context.coordinator.lastSinglePage = currentPage
                context.coordinator.lastOverlayRevision = overlayRevision
                context.coordinator.lastPencilModeActive = isPencilModeActive
                let vc = context.coordinator.createVC(page: currentPage)

                if uiViewController.spineLocation == .min || uiViewController.spineLocation == .max || uiViewController.spineLocation == .none {
                    uiViewController.setViewControllers([vc], direction: dir, animated: animateJump)
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    context.coordinator.preloadNeighbors()
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator { 
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: BookPagerView
        var lastPage: Int
        var pendingPage: Int?
        var cachedVCs: [Int: PageHostingController] = [:]
        var lastOverlayRevision: Int = -1
        var lastLeftPage: Int = -1
        var lastRightPage: Int = -1
        var lastSinglePage: Int = -1
        var lastPencilModeActive: Bool? = nil
        
        init(_ parent: BookPagerView) {
            self.parent = parent
            self.lastPage = parent.currentPage
        }
        
        func pruneCache() {
            let center = parent.currentPage
            let threshold = parent.isDoubleSided ? 4 : 2
            let keys = cachedVCs.keys
            for key in keys {
                if abs(key - center) > threshold {
                    cachedVCs.removeValue(forKey: key)
                }
            }
        }
        
        func preloadNeighbors() {
            let p = parent.currentPage
            if parent.isDoubleSided {
                let leftPage = p % 2 == 1 ? p : max(1, p - 1)
                let rightPage = leftPage + 1
                if leftPage > 2 {
                    _ = createVC(page: leftPage - 2).view
                    _ = createVC(page: leftPage - 1).view
                }
                if rightPage < parent.pageCount {
                    _ = createVC(page: rightPage + 1).view
                    _ = createVC(page: rightPage + 2).view
                }
            } else {
                if p > 1 {
                    _ = createVC(page: p - 1).view
                }
                if p < parent.pageCount {
                    _ = createVC(page: p + 1).view
                }
            }
        }
        
        func createVC(page: Int) -> PageHostingController {
            if let cached = cachedVCs[page] {
                cached.rootView = AnyView(parent.content(page))
                pruneCache()
                return cached
            }
            
            if page <= parent.pageCount && page >= 1 {
                let view = AnyView(parent.content(page))
                let vc = PageHostingController(pageIndex: page, rootView: view)
                cachedVCs[page] = vc
                
                pruneCache()
                
                return vc
            } else {
                let empty = AnyView(Color(red: 15/255, green: 23/255, blue: 42/255))
                return PageHostingController(pageIndex: page, rootView: empty)
            }
        }
        

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let currentVC = viewController as? PageHostingController else { return nil }
            if currentVC.pageIndex > 1 {
                return createVC(page: currentVC.pageIndex - 1)
            }
            return nil
        }
        
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let currentVC = viewController as? PageHostingController else { return nil }
            
            if parent.isDoubleSided {
                let maxPage = parent.pageCount % 2 == 1 ? parent.pageCount + 1 : parent.pageCount
                if currentVC.pageIndex < maxPage {
                    return createVC(page: currentVC.pageIndex + 1)
                }
            } else {
                if currentVC.pageIndex < parent.pageCount {
                    return createVC(page: currentVC.pageIndex + 1)
                }
            }
            return nil
        }
        
        private func normalizedCurrentPage(from pageIndex: Int) -> Int {
            if parent.isDoubleSided {
                return pageIndex % 2 == 1 ? pageIndex : max(1, pageIndex - 1)
            }
            return pageIndex
        }
        
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            if let vc = pendingViewControllers.first as? PageHostingController {
                pendingPage = vc.pageIndex
            }
        }
        
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed, let p = pendingPage {
                let normalizedPage = normalizedCurrentPage(from: p)
                parent.currentPage = normalizedPage
                lastPage = normalizedPage
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.preloadNeighbors()
                }
            }
            pendingPage = nil
        }
        
        func pageViewController(_ pageViewController: UIPageViewController, spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation {
            if parent.isDoubleSided {
                pageViewController.isDoubleSided = true
                let leftPage = parent.currentPage % 2 == 1 ? parent.currentPage : max(1, parent.currentPage - 1)
                let rightPage = leftPage + 1
                
                let currentVCs = pageViewController.viewControllers ?? []
                if currentVCs.count != 2 {
                    let leftVC = createVC(page: leftPage)
                    let rightVC = createVC(page: rightPage)
                    pageViewController.setViewControllers([leftVC, rightVC], direction: .forward, animated: false)
                }
                return .mid
            } else {
                pageViewController.isDoubleSided = false
                let currentVCs = pageViewController.viewControllers ?? []
                if currentVCs.count != 1 {
                    let vc = createVC(page: parent.currentPage)
                    pageViewController.setViewControllers([vc], direction: .forward, animated: false)
                }
                return .min
            }
        }
    }
}
