//
//  SceneDelegate.swift
//  AltStore
//
//  Created by Riley Testut on 7/6/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit


@available(iOS 13, *)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate
{
    var window: UIWindow?

    // Holds an imported .ipa URL when the scene isn't active yet (cold launch),
    // so the import notification can be posted once the scene becomes active.
    private var pendingImportIPAURL: URL?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions)
    {
        debugLog("[SceneDelegate] scene(willConnectTo:) invoked")
        guard let _ = (scene as? UIWindowScene) else { return }
        
        if let context = connectionOptions.urlContexts.first
        {
            self.open(context)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene)
    {
        guard DatabaseManager.shared.isStarted else { return }
        
        Task {
            await AppManager.shared.reconcileInstalledApps()
            await WidgetDataManager.publishCurrentInstalledAppsIfNeeded(in: DatabaseManager.shared.viewContext)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene)
    {
        debugLog("[SceneDelegate] sceneDidBecomeActive() invoked")
        defer {
            Task.detached { await AppDelegate.dumpSideBackupLogsIfNeeded() }
        }
        
        if DatabaseManager.shared.isStarted {
            Task {
                await WidgetDataManager.publishCurrentInstalledAppsIfNeeded(in: DatabaseManager.shared.viewContext)
            }
        }
        
        guard let url = self.pendingImportIPAURL else { return }
        self.pendingImportIPAURL = nil
        NotificationCenter.default.post(name: AppDelegate.importAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.importAppDeepLinkURLKey: url])
    }

    func sceneDidEnterBackground(_ scene: UIScene)
    {
        guard UIApplication.shared.applicationState == .background else { return }
        guard let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date()) else { return }
        
        let midnightOneMonthAgo = Calendar.current.startOfDay(for: oneMonthAgo)
        DatabaseManager.shared.purgeLoggedErrors(before: midnightOneMonthAgo) { result in
            switch result
            {
            case .success: break
            case .failure(let error): debugLog("[ALTLog] Failed to purge logged errors before \(midnightOneMonthAgo). \(error)")
            }
        }
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>)
    {
        guard let context = URLContexts.first else { return }
        debugLog("[SceneDelegate] scene(_:openURLContexts:) called with URL: \(context.url)")
        self.open(context)
    }
}

private extension SceneDelegate
{
    func open(_ context: UIOpenURLContext)
    {
        debugLog("[SceneDelegate] open(_:) called with URL: \(context.url)")
        if context.url.isFileURL
        {
            guard context.url.pathExtension.lowercased() == "ipa" else { return }

            if !context.url.startAccessingSecurityScopedResource() {
                debugLog("[ALTLog] Failed to access security-scoped resource for imported IPA")
                return
            }
            defer { context.url.stopAccessingSecurityScopedResource() }

            let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
            do {
                try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                debugLog("[ALTLog] Failed to create temp directory for imported IPA: \(error)")
                return
            }

            let ipa = temporaryDirectory.appendingPathComponent(context.url.lastPathComponent)

            do {
                try FileManager.default.copyItem(at: context.url, to: ipa)
            } catch {
                debugLog("[ALTLog] Failed to copy imported IPA: \(error)")
                return
            }

            if UIApplication.shared.applicationState == .active {
                NotificationCenter.default.post(name: AppDelegate.importAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.importAppDeepLinkURLKey: ipa])
            } else {
                self.pendingImportIPAURL = ipa
            }
        }
        else
        {
            if ClassicCydiaURLRouter.handle(context.url)
            {
                return
            }

            URLHandler.shared.handle(context.url)
        }
    }
}


func exportPairingFile(_ urlname: String) {
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first, let viewcontroller = window.rootViewController {
        let fm = FileManager.default
        let documentsPath = fm.documentsDirectory.appendingPathComponent("ALTPairingFile.mobiledevicepairing")
        
        guard let data = try? Data(contentsOf: documentsPath) else {
            let toastView = ToastView(text: NSLocalizedString("Failed to find Pairing File!", comment: ""), detailText: nil)
            toastView.show(in: viewcontroller)
            return
        }
        
        let base64encodedCert = data.base64EncodedString()
        var allowedQueryParamAndKey = NSCharacterSet.urlQueryAllowed
        allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")
        guard let encodedCert = base64encodedCert.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey) else {
            let toastView = ToastView(text: NSLocalizedString("Failed to encode pairingFile!", comment: ""), detailText: nil)
            toastView.show(in: viewcontroller)
            return
        }
        
        let urlStr = "\(urlname)://pairingFile?data=$(BASE64_PAIRING)"
        let finished = urlStr.replacingOccurrences(of: "$(BASE64_PAIRING)", with: encodedCert, options: .literal, range: nil)
        
        debugLog(finished)
        guard let callbackUrl = URL(string: finished) else {
            let toastView = ToastView(text: NSLocalizedString("Failed to initialize callback URL!", comment: ""), detailText: nil)
            toastView.show(in: viewcontroller)
            return
        }
        UIApplication.shared.open(callbackUrl)
    }
}

extension BrowseViewController
{
    /// Opens SideStore's existing source-wide search UI and optionally seeds a
    /// Cydia package/search query without introducing a second search backend.
    func activateClassicSearch(query: String?)
    {
        self.loadViewIfNeeded()
        self.title = NSLocalizedString("Search", comment: "")
        self.navigationItem.searchController?.isActive = true

        guard let query, !query.isEmpty else
        {
            self.navigationItem.searchController?.searchBar.becomeFirstResponder()
            return
        }

        self.navigationItem.searchController?.searchBar.text = query
        self.searchPredicate = NSPredicate(format: "%K CONTAINS[cd] %@ OR %K CONTAINS[cd] %@ OR %K CONTAINS[cd] %@ OR %K CONTAINS[cd] %@",
                                           #keyPath(StoreApp.name), query,
                                           #keyPath(StoreApp.subtitle), query,
                                           #keyPath(StoreApp.developerName), query,
                                           #keyPath(StoreApp.bundleIdentifier), query)
        self.navigationItem.searchController?.searchBar.becomeFirstResponder()
    }
}
