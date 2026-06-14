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
    
    @ViewBuilder var content: (Int) -> Content
    
    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 1)
        return pvc
    }
    
    func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        
        let currentVCs = uiViewController.viewControllers ?? []
        
        if isDoubleSided {
            let leftPage = currentPage % 2 == 1 ? currentPage : max(1, currentPage - 1)
            let rightPage = leftPage + 1
            
            var needsUpdate = true
            if currentVCs.count == 2,
               let leftVC = currentVCs[0] as? PageHostingController,
               let rightVC = currentVCs[1] as? PageHostingController {
                if leftVC.pageIndex == leftPage && rightVC.pageIndex == rightPage {
                    leftVC.rootView = AnyView(content(leftPage))
                    if rightPage <= pageCount {
                        rightVC.rootView = AnyView(content(rightPage))
                    }
                    needsUpdate = false
                }
            }
            
            if needsUpdate {
                let dir: UIPageViewController.NavigationDirection = (leftPage >= context.coordinator.lastPage) ? .forward : .reverse
                context.coordinator.lastPage = leftPage
                
                let leftVC = context.coordinator.createVC(page: leftPage)
                let rightVC = context.coordinator.createVC(page: rightPage)
                
                if uiViewController.spineLocation == .mid {
                    uiViewController.setViewControllers([leftVC, rightVC], direction: dir, animated: true)
                }
            }
        } else {
            var needsUpdate = true
            if currentVCs.count == 1,
               let vc = currentVCs[0] as? PageHostingController {
                if vc.pageIndex == currentPage {
                    vc.rootView = AnyView(content(currentPage))
                    needsUpdate = false
                }
            }
            
            if needsUpdate {
                let dir: UIPageViewController.NavigationDirection = (currentPage >= context.coordinator.lastPage) ? .forward : .reverse
                context.coordinator.lastPage = currentPage
                let vc = context.coordinator.createVC(page: currentPage)
                
                if uiViewController.spineLocation == .min || uiViewController.spineLocation == .max {
                    uiViewController.setViewControllers([vc], direction: dir, animated: true)
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
        
        init(_ parent: BookPagerView) {
            self.parent = parent
            self.lastPage = parent.currentPage
        }
        
        func createVC(page: Int) -> PageHostingController {
            if let cached = cachedVCs[page] {
                cached.rootView = AnyView(parent.content(page))
                preloadAdjacent(center: page)
                pruneCache(center: page)
                return cached
            }
            
            if page <= parent.pageCount && page >= 1 {
                let view = AnyView(parent.content(page))
                let vc = PageHostingController(pageIndex: page, rootView: view)
                cachedVCs[page] = vc
                
                preloadAdjacent(center: page)
                pruneCache(center: page)
                
                return vc
            } else {
                let empty = AnyView(Color(red: 15/255, green: 23/255, blue: 42/255))
                return PageHostingController(pageIndex: page, rootView: empty)
            }
        }
        
        func preloadAdjacent(center: Int) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let pagesToPreload = [center - 1, center - 2, center + 1, center + 2]
                for p in pagesToPreload {
                    if p >= 1 && p <= self.parent.pageCount {
                        if self.cachedVCs[p] == nil {
                            let view = AnyView(self.parent.content(p))
                            let vc = PageHostingController(pageIndex: p, rootView: view)
                            // Force view to load to trigger WKWebView initialization
                            _ = vc.view
                            self.cachedVCs[p] = vc
                        }
                    }
                }
            }
        }
        
        func pruneCache(center: Int) {
            let keys = cachedVCs.keys
            for key in keys {
                if abs(key - center) > 3 {
                    cachedVCs.removeValue(forKey: key)
                }
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
        
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            if let vc = pendingViewControllers.first as? PageHostingController {
                pendingPage = vc.pageIndex
            }
        }
        
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed, let p = pendingPage {
                parent.currentPage = p
                lastPage = p
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
