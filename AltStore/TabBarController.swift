//
//  TabBarController.swift
//  AltStore
//
//  Created by Riley Testut on 9/19/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import CoreData

extension TabBarController
{
    private enum Tab: Int, CaseIterable
    {
        case cydia
        case sources
        case changes
        case installed
        case search
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

/// Stock-iOS Cydia URL dispatcher. It deliberately handles only the Cydia-facing
/// routes and leaves SideStore's existing URLHandler untouched for sidestore://
/// callbacks, pairing, installation and authentication flows.
enum ClassicCydiaURLRouter
{
    static let routeNotification = Notification.Name("ClassicCydiaRouteNotification")
    static let destinationKey = "destination"
    static let queryKey = "query"

    enum Destination: String
    {
        case cydia
        case sources
        case changes
        case installed
        case search
    }

    @discardableResult
    static func handle(_ url: URL) -> Bool
    {
        guard url.scheme?.lowercased() == "cydia" else { return false }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = (components?.host ?? "").lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let firstPathComponent = pathComponents.first?.lowercased()
        let route = host.isEmpty ? (firstPathComponent ?? "cydia") : host

        let queryItems = components?.queryItems ?? []
        let sourceValue = queryItems.first(where: { ["url", "source"].contains($0.name.lowercased()) })?.value

        // Cydia-style source links are forwarded into SideStore's real source-add flow.
        if ["source", "sources", "addsource"].contains(route),
           let sourceValue,
           let sourceURL = URL(string: sourceValue)
        {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: AppDelegate.addSourceDeepLinkNotification,
                                                object: nil,
                                                userInfo: [AppDelegate.addSourceDeepLinkURLKey: sourceURL])
            }
            return true
        }

        let destination: Destination
        var query = queryItems.first(where: { ["q", "query"].contains($0.name.lowercased()) })?.value

        switch route
        {
        case "source", "sources", "addsource": destination = .sources
        case "changes", "updates": destination = .changes
        case "installed", "packages", "manage": destination = .installed
        case "search": destination = .search
        case "package":
            destination = .search
            if query == nil
            {
                query = pathComponents.first
            }
        default: destination = .cydia
        }

        DispatchQueue.main.async {
            var userInfo: [AnyHashable: Any] = [destinationKey: destination.rawValue]
            if let query, !query.isEmpty
            {
                userInfo[queryKey] = query
            }
            NotificationCenter.default.post(name: routeNotification, object: nil, userInfo: userInfo)
        }

        return true
    }
}

/// A classic "Changes" list backed by SideStore's real supported-update fetch and
/// install/update pipeline. Nothing in this controller simulates package state.
private final class ClassicChangesViewController: UITableViewController
{
    private var updates = [InstalledApp]()

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.title = NSLocalizedString("Changes", comment: "")
        self.tableView.rowHeight = 64
        self.tableView.tableFooterView = UIView()

        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(refreshSourcesAndChanges(_:)), for: .valueChanged)
        self.refreshControl = refreshControl

        self.reloadUpdates()
    }

    override func viewWillAppear(_ animated: Bool)
    {
        super.viewWillAppear(animated)
        self.reloadUpdates()
    }

    private func reloadUpdates()
    {
        let fetchRequest = InstalledApp.supportedUpdatesFetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \InstalledApp.storeApp?.latestSupportedVersion?.date, ascending: false),
                                        NSSortDescriptor(keyPath: \InstalledApp.name, ascending: true)]
        fetchRequest.returnsObjectsAsFaults = false

        do
        {
            self.updates = try DatabaseManager.shared.viewContext.fetch(fetchRequest)
        }
        catch
        {
            self.updates = []
            debugLog("[ClassicChanges] Failed to fetch available updates: \(error)")
        }

        self.navigationController?.tabBarItem.badgeValue = self.updates.isEmpty ? nil : String(self.updates.count)
        self.tableView.reloadData()
        self.refreshControl?.endRefreshing()
    }

    @objc private func refreshSourcesAndChanges(_ sender: UIRefreshControl)
    {
        AppManager.shared.updateAllSources { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                if case .failure(let error) = result
                {
                    ToastView(error: error).show(in: self)
                }

                self.reloadUpdates()
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int
    {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int
    {
        return max(self.updates.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell
    {
        if self.updates.isEmpty
        {
            let identifier = "NoClassicChangesCell"
            let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
            cell.textLabel?.text = NSLocalizedString("No Updates Available", comment: "")
            cell.detailTextLabel?.text = NSLocalizedString("Pull down to refresh your sources.", comment: "")
            cell.textLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.textColor = .tertiaryLabel
            cell.selectionStyle = .none
            cell.accessoryView = nil
            cell.imageView?.image = UIImage(systemName: "checkmark.circle")
            return cell
        }

        let installedApp = self.updates[indexPath.row]
        let identifier = "ClassicChangeCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)

        cell.textLabel?.text = installedApp.name
        if let latestVersion = installedApp.storeApp?.latestSupportedVersion
        {
            cell.detailTextLabel?.text = String(format: NSLocalizedString("Version %@ available", comment: ""), latestVersion.localizedVersion)
        }
        else
        {
            cell.detailTextLabel?.text = NSLocalizedString("Update available", comment: "")
        }
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.imageView?.image = UIImage(systemName: "shippingbox.fill")
        cell.selectionStyle = .none

        let button = UIButton(type: .system)
        button.setTitle(NSLocalizedString("Upgrade", comment: ""), for: .normal)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .subheadline)
        button.tintColor = ClassicCydiaTheme.accent
        button.tag = indexPath.row
        button.addTarget(self, action: #selector(updateApp(_:)), for: .primaryActionTriggered)
        button.sizeToFit()
        cell.accessoryView = button

        return cell
    }

    @objc private func updateApp(_ sender: UIButton)
    {
        guard self.updates.indices.contains(sender.tag) else { return }
        let installedApp = self.updates[sender.tag]

        if let previousProgress = AppManager.shared.installationProgress(for: installedApp)
        {
            previousProgress.cancel()
            return
        }

        sender.isEnabled = false
        sender.setTitle(NSLocalizedString("Updating…", comment: ""), for: .normal)
        sender.sizeToFit()

        _ = AppManager.shared.update(installedApp, presentingViewController: self) { [weak self, weak sender] result in
            DispatchQueue.main.async {
                guard let self else { return }

                sender?.isEnabled = true
                sender?.setTitle(NSLocalizedString("Upgrade", comment: ""), for: .normal)
                sender?.sizeToFit()

                switch result
                {
                case .failure(let error) where error is CancellationError:
                    break
                case .failure(let error):
                    ToastView(error: error, opensLog: true).show(in: self)
                case .success:
                    debugLog("[ClassicChanges] Updated app: \(installedApp.bundleIdentifier)")
                }

                self.reloadUpdates()
            }
        }
    }
}

final class TabBarController: UITabBarController
{
    private var initialSegue: (identifier: String, sender: Any?)?
    private var _viewDidAppear = false

    private var sourcesViewController: SourcesViewController!
    private weak var searchViewController: BrowseViewController?
    private var settingsNavigationController: UINavigationController?

    required init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)

        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.importApp(_:)), name: AppDelegate.importAppDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.presentSources(_:)), name: AppDelegate.addSourceDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.openErrorLog(_:)), name: ToastView.openErrorLogNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.handleClassicCydiaRoute(_:)), name: ClassicCydiaURLRouter.routeNotification, object: nil)
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()
        debugLog("[TabBarController] viewDidLoad()")

        guard let originalControllers = self.viewControllers, originalControllers.count >= 5 else
        {
            assertionFailure("Cydia shell expected five SideStore storyboard tab controllers.")
            return
        }

        // Main.storyboard order before conversion: News, Sources, Browse, My Apps, Settings.
        let cydiaNavigationController = originalControllers[0]
        let sourcesNavigationController = originalControllers[1]
        let searchNavigationController = originalControllers[2]
        let installedNavigationController = originalControllers[3]
        self.settingsNavigationController = originalControllers[4] as? UINavigationController

        let changesNavigationController = UINavigationController(rootViewController: ClassicChangesViewController(style: .plain))

        let classicControllers = [cydiaNavigationController,
                                  sourcesNavigationController,
                                  changesNavigationController,
                                  installedNavigationController,
                                  searchNavigationController]
        self.setViewControllers(classicControllers, animated: false)

        self.configureClassicCydiaTab(cydiaNavigationController, title: "Cydia", systemImage: "shippingbox.fill")
        self.configureClassicCydiaTab(sourcesNavigationController, title: "Sources", systemImage: "tray.full.fill")
        self.configureClassicCydiaTab(changesNavigationController, title: "Changes", systemImage: "clock.arrow.circlepath")
        self.configureClassicCydiaTab(installedNavigationController, title: "Installed", systemImage: "square.stack.3d.up.fill")
        self.configureClassicCydiaTab(searchNavigationController, title: "Search", systemImage: "magnifyingglass")

        self.configureClassicCydiaAppearance(for: classicControllers)
        if let settingsNavigationController
        {
            self.configureClassicCydiaAppearance(for: [settingsNavigationController])
        }

        if let navigationController = cydiaNavigationController as? UINavigationController
        {
            navigationController.viewControllers.first?.title = NSLocalizedString("Cydia", comment: "")
            let gearButton = UIBarButtonItem(image: UIImage(systemName: "gearshape.fill"),
                                             style: .plain,
                                             target: self,
                                             action: #selector(presentSettings(_:)))
            let existingItems = navigationController.viewControllers.first?.navigationItem.rightBarButtonItems ?? []
            navigationController.viewControllers.first?.navigationItem.rightBarButtonItems = [gearButton] + existingItems
        }

        if let navigationController = installedNavigationController as? UINavigationController
        {
            navigationController.viewControllers.first?.title = NSLocalizedString("Installed", comment: "")
        }

        let sourcesNav = sourcesNavigationController as? UINavigationController
        self.sourcesViewController = sourcesNav?.viewControllers.first as? SourcesViewController

        let searchNav = searchNavigationController as? UINavigationController
        self.searchViewController = searchNav?.viewControllers.first as? BrowseViewController
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

    @objc func presentSettings(_ sender: Any?)
    {
        guard let settingsNavigationController = self.settingsNavigationController else { return }

        if settingsNavigationController.presentingViewController != nil
        {
            return
        }

        settingsNavigationController.modalPresentationStyle = .formSheet
        settingsNavigationController.navigationBar.tintColor = ClassicCydiaTheme.accent
        settingsNavigationController.viewControllers.first?.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                                                                                target: self,
                                                                                                                action: #selector(dismissSettings(_:)))
        self.present(settingsNavigationController, animated: true)
    }

    @objc func dismissSettings(_ sender: Any?)
    {
        self.settingsNavigationController?.dismiss(animated: true)
    }

    @objc func handleClassicCydiaRoute(_ notification: Notification)
    {
        guard let rawDestination = notification.userInfo?[ClassicCydiaURLRouter.destinationKey] as? String,
              let destination = ClassicCydiaURLRouter.Destination(rawValue: rawDestination) else { return }

        if self.presentedViewController != nil
        {
            self.dismiss(animated: false) { [weak self] in
                self?.handleClassicCydiaRoute(notification)
            }
            return
        }

        switch destination
        {
        case .cydia:
            self.selectedIndex = Tab.cydia.rawValue
        case .sources:
            self.selectedIndex = Tab.sources.rawValue
        case .changes:
            self.selectedIndex = Tab.changes.rawValue
        case .installed:
            self.selectedIndex = Tab.installed.rawValue
        case .search:
            self.selectedIndex = Tab.search.rawValue
            let query = notification.userInfo?[ClassicCydiaURLRouter.queryKey] as? String
            self.searchViewController?.activateClassicSearch(query: query)
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
        self.presentSettings(notification)
    }
}
