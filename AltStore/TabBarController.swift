//
//  TabBarController.swift
//  AltStore
//
//  Created by Riley Testut on 9/19/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

extension TabBarController
{
    private enum Tab: Int, CaseIterable
    {
        // Keep these values aligned with Main.storyboard's existing controller order.
        // The SideStore controllers stay intact; only their Cydia-facing presentation changes.
        case cydia
        case sources
        case search
        case installed
        case manage
    }
}

private enum ClassicCydiaTheme
{
    static let accent = UIColor(red: 0.53, green: 0.34, blue: 0.18, alpha: 1.0)
    static let chrome = UIColor { traits in
        if traits.userInterfaceStyle == .dark
        {
            return UIColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1.0)
        }
        else
        {
            return UIColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1.0)
        }
    }
}

final class TabBarController: UITabBarController
{
    private var initialSegue: (identifier: String, sender: Any?)?
    
    private var _viewDidAppear = false
    
    private var sourcesViewController: SourcesViewController!
    
    required init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)
        
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.importApp(_:)), name: AppDelegate.importAppDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.presentSources(_:)), name: AppDelegate.addSourceDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.openErrorLog(_:)), name: ToastView.openErrorLogNotification, object: nil)
    }
    
    override func viewDidLoad() 
    {
        super.viewDidLoad()
        debugLog("[TabBarController] viewDidLoad()")
        
        guard let viewControllers = self.viewControllers, viewControllers.count >= Tab.allCases.count else
        {
            assertionFailure("Cydia shell expected five SideStore tab controllers.")
            return
        }
        
        self.configureClassicCydiaTab(viewControllers[Tab.cydia.rawValue], title: "Cydia", systemImage: "shippingbox.fill")
        self.configureClassicCydiaTab(viewControllers[Tab.sources.rawValue], title: "Sources", systemImage: "tray.full.fill")
        self.configureClassicCydiaTab(viewControllers[Tab.search.rawValue], title: "Search", systemImage: "magnifyingglass")
        self.configureClassicCydiaTab(viewControllers[Tab.installed.rawValue], title: "Installed", systemImage: "square.stack.3d.up.fill")
        self.configureClassicCydiaTab(viewControllers[Tab.manage.rawValue], title: "Manage", systemImage: "gearshape.fill")
        
        self.configureClassicCydiaAppearance(for: viewControllers)
        
        let sourcesNavigationController = viewControllers[Tab.sources.rawValue] as! UINavigationController
        self.sourcesViewController = sourcesNavigationController.viewControllers.first as? SourcesViewController
    }
    
    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        debugLog("[TabBarController] viewDidAppear() — TabBarController is now visible")
        
        _viewDidAppear = true
        
        if let (identifier, sender) = self.initialSegue
        {
            self.initialSegue = nil
            self.performSegue(withIdentifier: identifier, sender: sender)
        }
    }
    
    override func performSegue(withIdentifier identifier: String, sender: Any?)
    {
        guard _viewDidAppear else {
            self.initialSegue = (identifier, sender)
            return
        }
        
        super.performSegue(withIdentifier: identifier, sender: sender)
    }
}

private extension TabBarController
{
    func configureClassicCydiaTab(_ viewController: UIViewController, title: String, systemImage: String)
    {
        viewController.tabBarItem.title = title
        viewController.tabBarItem.image = UIImage(systemName: systemImage)
        viewController.tabBarItem.selectedImage = UIImage(systemName: systemImage)
    }
    
    func configureClassicCydiaAppearance(for viewControllers: [UIViewController])
    {
        self.tabBar.tintColor = ClassicCydiaTheme.accent
        self.tabBar.unselectedItemTintColor = .secondaryLabel
        
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = ClassicCydiaTheme.chrome
        tabAppearance.stackedLayoutAppearance.selected.iconColor = ClassicCydiaTheme.accent
        tabAppearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: ClassicCydiaTheme.accent]
        
        self.tabBar.standardAppearance = tabAppearance
        if #available(iOS 15.0, *)
        {
            self.tabBar.scrollEdgeAppearance = tabAppearance
        }
        
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = ClassicCydiaTheme.chrome
        navigationAppearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navigationAppearance.shadowColor = UIColor.separator
        
        for case let navigationController as UINavigationController in viewControllers
        {
            navigationController.navigationBar.tintColor = ClassicCydiaTheme.accent
            navigationController.navigationBar.prefersLargeTitles = false
            navigationController.navigationBar.standardAppearance = navigationAppearance
            navigationController.navigationBar.compactAppearance = navigationAppearance
            navigationController.navigationBar.scrollEdgeAppearance = navigationAppearance
        }
    }
}

extension TabBarController
{
    @objc func presentSources(_ sender: Any)
    {
        if let presentedViewController = self.presentedViewController
        {
            presentedViewController.dismiss(animated: true) {
                self.presentSources(sender)
            }
            
            return
        }
                
        if let notification = (sender as? Notification), let sourceURL = notification.userInfo?[AppDelegate.addSourceDeepLinkURLKey] as? URL
        {
            self.sourcesViewController?.deepLinkSourceURL = sourceURL
        }
        
        self.selectedIndex = Tab.sources.rawValue
    }
}

private extension TabBarController
{
    @objc func importApp(_ notification: Notification)
    {
        self.selectedIndex = Tab.installed.rawValue
    }

    @objc func openErrorLog(_ notification: Notification)
    {
        self.selectedIndex = Tab.manage.rawValue
    }
}
