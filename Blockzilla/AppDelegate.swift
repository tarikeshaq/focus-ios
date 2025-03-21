/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import Telemetry
import Glean
import Viaduct
import RustLog
import Nimbus

protocol AppSplashController {
    var splashView: UIView { get }

    func toggleSplashView(hide: Bool)
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, ModalDelegate, AppSplashController {
    var nimbusApi: NimbusApi?
    
    static let prefIntroDone = "IntroDone"
    static let prefIntroVersion = 2
    static let prefWhatsNewDone = "WhatsNewDone"
    static let prefWhatsNewCounter = "WhatsNewCounter"
    static var needsAuthenticated = false

    // This enum can be expanded to support all new shortcuts added to menu.
    enum ShortcutIdentifier: String {
        case EraseAndOpen
        init?(fullIdentifier: String) {
            guard let shortIdentifier = fullIdentifier.components(separatedBy: ".").last else {
                return nil
            }
            self.init(rawValue: shortIdentifier)
        }
    }

    var window: UIWindow?

    var splashView: UIView = UIView()
    private lazy var browserViewController = {
        BrowserViewController(appSplashController: self)
    }()

    private var queuedUrl: URL?
    private var queuedString: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if AppInfo.testRequestsReset() {
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
            UserDefaults.standard.removePersistentDomain(forName: AppInfo.sharedContainerIdentifier)
        }

        setupTelemetry()
        setupExperimentation()
        
        TPStatsBlocklistChecker.shared.startup()
        
        // Fix transparent navigation bar issue in iOS 15
        if #available(iOS 15, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.primaryText]
            appearance.backgroundColor = .systemBackground
            appearance.shadowColor = .clear
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }

        // Count number of app launches for requesting a review
        let currentLaunchCount = UserDefaults.standard.integer(forKey: UIConstants.strings.userDefaultsLaunchCountKey)
        UserDefaults.standard.set(currentLaunchCount + 1, forKey: UIConstants.strings.userDefaultsLaunchCountKey)

        // Disable localStorage.
        // We clear the Caches directory after each Erase, but WebKit apparently maintains
        // localStorage in-memory (bug 1319208), so we just disable it altogether.
        UserDefaults.standard.set(false, forKey: "WebKitLocalStorageEnabledPreferenceKey")
        UserDefaults.standard.removeObject(forKey: "searchedHistory")

        // Re-register the blocking lists at startup in case they've changed.
        Utils.reloadSafariContentBlocker()

        window = UIWindow(frame: UIScreen.main.bounds)

        browserViewController.modalDelegate = self
        window?.rootViewController = browserViewController
        window?.makeKeyAndVisible()
        window?.overrideUserInterfaceStyle = UserDefaults.standard.theme.userInterfaceStyle

        WebCacheUtils.reset()

        displaySplashAnimation()
        KeyboardHelper.defaultHelper.startObserving()

        let prefIntroDone = UserDefaults.standard.integer(forKey: AppDelegate.prefIntroDone)

        // Short circuit if we are testing. We special case the first run handling and completely
        // skip the what's new handling. This logic could be put below but that is already way
        // too complicated. Everything under this commen should really be refactored.
        
        if AppInfo.isTesting() {
            // Only show the First Run UI if the test asks for it.
            if AppInfo.isFirstRunUIEnabled() {
                let firstRunViewController = IntroViewController()
                firstRunViewController.modalPresentationStyle = .fullScreen
                self.browserViewController.present(firstRunViewController, animated: false, completion: nil)
            }
            return true
        }

        let needToShowFirstRunExperience = prefIntroDone < AppDelegate.prefIntroVersion
        if needToShowFirstRunExperience {
            // Show the first run UI asynchronously to avoid the "unbalanced calls to begin/end appearance transitions" warning.
            DispatchQueue.main.async {
                // Set the prefIntroVersion viewed number in the same context as the presentation.
                UserDefaults.standard.set(AppDelegate.prefIntroVersion, forKey: AppDelegate.prefIntroDone)
                UserDefaults.standard.set(AppInfo.shortVersion, forKey: AppDelegate.prefWhatsNewDone)
                let introViewController = IntroViewController()
                introViewController.modalPresentationStyle = .fullScreen
                self.browserViewController.present(introViewController, animated: false, completion: nil)
            }
        }

        // Don't highlight whats new on a fresh install (prefIntroDone == 0 on a fresh install)
        if let lastShownWhatsNew = UserDefaults.standard.string(forKey: AppDelegate.prefWhatsNewDone)?.first, let currentMajorRelease = AppInfo.shortVersion.first {
            if prefIntroDone != 0 && lastShownWhatsNew != currentMajorRelease {

                let counter = UserDefaults.standard.integer(forKey: AppDelegate.prefWhatsNewCounter)
                switch counter {
                case 4:
                    // Shown three times, remove counter
                    UserDefaults.standard.set(AppInfo.shortVersion, forKey: AppDelegate.prefWhatsNewDone)
                    UserDefaults.standard.removeObject(forKey: AppDelegate.prefWhatsNewCounter)
                default:
                    // Show highlight
                    UserDefaults.standard.set(counter+1, forKey: AppDelegate.prefWhatsNewCounter)
                }
            }
        }

        return true
    }

    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }

        guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [AnyObject],
            let urlSchemes = urlTypes.first?["CFBundleURLSchemes"] as? [String] else {
                // Something very strange has happened; org.mozilla.Blockzilla should be the zeroeth URL type.
                return false
        }

        guard let scheme = components.scheme,
            let host = url.host,
            urlSchemes.contains(scheme) else {
            return false
        }

        let query = getQuery(url: url)
        let isHttpScheme = scheme == "http" || scheme == "https"

        if isHttpScheme {
            if application.applicationState == .active {
                // If we are active then we can ask the BVC to open the new tab right away.
                // Otherwise, we remember the URL and we open it in applicationDidBecomeActive.
                browserViewController.submit(url: url)
            } else {
                queuedUrl = url
            }
        } else if host == "open-url" {
            let urlString = unescape(string: query["url"]) ?? ""
            guard let url = URL(string: urlString) else { return false }

            if application.applicationState == .active {
                // If we are active then we can ask the BVC to open the new tab right away.
                // Otherwise, we remember the URL and we open it in applicationDidBecomeActive.
                browserViewController.submit(url: url)
            } else {
                queuedUrl = url
            }
        } else if host == "open-text" || isHttpScheme {
            let text = unescape(string: query["text"]) ?? ""

            // If we are active then we can ask the BVC to open the new tab right away.
            // Otherwise, we remember the URL and we open it in applicationDidBecomeActive.
            if application.applicationState == .active {
                if let fixedUrl = URIFixup.getURL(entry: text) {
                    browserViewController.submit(url: fixedUrl)
                } else {
                    browserViewController.submit(text: text)
                }
            } else {
                queuedString = text
            }
        } else if host == "glean" {
            Glean.shared.handleCustomUrl(url: url)
        }

        return true
    }

    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: (Bool) -> Void) {

        completionHandler(handleShortcut(shortcutItem: shortcutItem))
    }

    private func handleShortcut(shortcutItem: UIApplicationShortcutItem) -> Bool {
        let shortcutType = shortcutItem.type
        guard let shortcutIdentifier = ShortcutIdentifier(fullIdentifier: shortcutType) else {
            return false
        }
        switch shortcutIdentifier {
        case .EraseAndOpen:
            browserViewController.resetBrowser(hidePreviousSession: true)
        }
        return true
    }

    public func getQuery(url: URL) -> [String: String] {
        var results = [String: String]()
        let keyValues =  url.query?.components(separatedBy: "&")

        if keyValues?.count ?? 0 > 0 {
            for pair in keyValues! {
                let kv = pair.components(separatedBy: "=")
                if kv.count > 1 {
                    results[kv[0]] = kv[1]
                }
            }
        }

        return results
    }

    public func unescape(string: String?) -> String? {
        guard let string = string else {
            return nil
        }
        return CFURLCreateStringByReplacingPercentEscapes(
            kCFAllocatorDefault,
            string as CFString,
            "" as CFString) as String
    }

    private func displaySplashAnimation() {
        let splashView = self.splashView
        splashView.backgroundColor = UIConstants.colors.background
        window!.addSubview(splashView)

        let logoImage = UIImageView(image: AppInfo.config.wordmark)
        splashView.addSubview(logoImage)

        splashView.snp.makeConstraints { make in
            make.edges.equalTo(window!)
        }

        logoImage.snp.makeConstraints { make in
            make.center.equalTo(splashView)
        }

        let animationDuration = 0.25
        UIView.animate(withDuration: animationDuration, delay: 0.0, options: UIView.AnimationOptions(), animations: {
            logoImage.layer.transform = CATransform3DMakeScale(0.8, 0.8, 1.0)
        }, completion: { success in
            UIView.animate(withDuration: animationDuration, delay: 0.0, options: UIView.AnimationOptions(), animations: {
                splashView.alpha = 0
                logoImage.layer.transform = CATransform3DMakeScale(2.0, 2.0, 1.0)
            }, completion: { success in
                splashView.isHidden = true
                logoImage.layer.transform = CATransform3DIdentity
            })
        })
    }

    func applicationWillResignActive(_ application: UIApplication) {
        toggleSplashView(hide: false)
        browserViewController.exitFullScreenVideo()
        browserViewController.dismissActionSheet()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        if Settings.siriRequestsErase() {
            browserViewController.photonActionSheetDidDismiss()
            browserViewController.dismiss(animated: true, completion: nil)
            browserViewController.navigationController?.popViewController(animated: true)
            browserViewController.resetBrowser(hidePreviousSession: true)
            Settings.setSiriRequestErase(to: false)
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.siri, object: TelemetryEventObject.eraseInBackground)
        }
        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.foreground, object: TelemetryEventObject.app)

        if let url = queuedUrl {
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.openedFromExtension, object: TelemetryEventObject.app)

            browserViewController.ensureBrowsingMode()
            browserViewController.deactivateUrlBarOnHomeView()
            browserViewController.dismissSettings()
            browserViewController.dismissActionSheet()
            browserViewController.submit(url: url)
            queuedUrl = nil
        } else if let text = queuedString {
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.openedFromExtension, object: TelemetryEventObject.app)

            browserViewController.ensureBrowsingMode()
            browserViewController.deactivateUrlBarOnHomeView()
            browserViewController.dismissSettings()
            browserViewController.dismissActionSheet()

            if let fixedUrl = URIFixup.getURL(entry: text) {
                browserViewController.submit(url: fixedUrl)
            } else {
                browserViewController.submit(text: text)
            }

            queuedString = nil
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Record an event indicating that we have entered the background and end our telemetry
        // session. This gets called every time the app goes to background but should not get
        // called for *temporary* interruptions such as an incoming phone call until the user
        // takes action and we are officially backgrounded.
        AppDelegate.needsAuthenticated = true
        let orientation = UIDevice.current.orientation.isPortrait ? "Portrait" : "Landscape"
        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.background, object:
            TelemetryEventObject.app, value: nil, extras: ["orientation": orientation])
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        guard #available(iOS 12.0, *) else { return false }
        browserViewController.photonActionSheetDidDismiss()
        browserViewController.dismiss(animated: true, completion: nil)
        browserViewController.navigationController?.popViewController(animated: true)

        switch userActivity.activityType {
        case "org.mozilla.ios.Klar.eraseAndOpen":
            browserViewController.resetBrowser(hidePreviousSession: true)
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.siri, object: TelemetryEventObject.eraseAndOpen)
        case "org.mozilla.ios.Klar.openUrl":
            guard let urlString = userActivity.userInfo?["url"] as? String,
                let url = URL(string: urlString) else { return false }
            browserViewController.resetBrowser(hidePreviousSession: true)
            browserViewController.ensureBrowsingMode()
            browserViewController.deactivateUrlBarOnHomeView()
            browserViewController.submit(url: url)
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.siri, object: TelemetryEventObject.openFavoriteSite)
        case "EraseIntent":
            guard userActivity.interaction?.intent as? EraseIntent != nil else { return false }
            browserViewController.resetBrowser()
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.siri, object: TelemetryEventObject.eraseInBackground)
        default: break
        }
        return true
    }

    func toggleSplashView(hide: Bool) {
        let duration = 0.25
        splashView.animateHidden(hide, duration: duration)

        if !hide {
            browserViewController.deactivateUrlBarOnHomeView()
        } else {
            browserViewController.activateUrlBarOnHomeView()
        }
    }
}

// MARK: - Telemetry & Tooling setup
extension AppDelegate {

    func setupTelemetry() {

        let telemetryConfig = Telemetry.default.configuration
        telemetryConfig.appName = AppInfo.isKlar ? "Klar" : "Focus"
        telemetryConfig.userDefaultsSuiteName = AppInfo.sharedContainerIdentifier
        telemetryConfig.appVersion = AppInfo.shortVersion

        // Since Focus always clears the caches directory and Telemetry files are
        // excluded from iCloud backup, we store pings in documents.
        telemetryConfig.dataDirectory = .documentDirectory

        let activeSearchEngine = SearchEngineManager(prefs: UserDefaults.standard).activeEngine
        let defaultSearchEngineProvider = activeSearchEngine.isCustom ? "custom" : activeSearchEngine.name
        telemetryConfig.defaultSearchEngineProvider = defaultSearchEngineProvider

        telemetryConfig.measureUserDefaultsSetting(forKey: SearchEngineManager.prefKeyEngine, withDefaultValue: defaultSearchEngineProvider)
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.blockAds, withDefaultValue: Settings.getToggle(.blockAds))
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.blockAnalytics, withDefaultValue: Settings.getToggle(.blockAnalytics))
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.blockSocial, withDefaultValue: Settings.getToggle(.blockSocial))
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.blockOther, withDefaultValue: Settings.getToggle(.blockOther))
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.blockFonts, withDefaultValue: Settings.getToggle(.blockFonts))
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.biometricLogin, withDefaultValue: Settings.getToggle(.biometricLogin))
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.enableSearchSuggestions, withDefaultValue: Settings.getToggle(.enableSearchSuggestions))

        #if DEBUG
            telemetryConfig.updateChannel = "debug"
            telemetryConfig.isCollectionEnabled = false
            telemetryConfig.isUploadEnabled = false
        #else
            telemetryConfig.updateChannel = "release"
            telemetryConfig.isCollectionEnabled = Settings.getToggle(.sendAnonymousUsageData)
            telemetryConfig.isUploadEnabled = Settings.getToggle(.sendAnonymousUsageData)
        #endif

        Telemetry.default.add(pingBuilderType: CorePingBuilder.self)
        Telemetry.default.add(pingBuilderType: FocusEventPingBuilder.self)

        // Start the telemetry session and record an event indicating that we have entered the
        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.foreground, object: TelemetryEventObject.app)

        if let clientId = UserDefaults
            .standard.string(forKey: "telemetry-key-prefix-clientId")
            .flatMap(UUID.init(uuidString:)) {
            GleanMetrics.LegacyIds.clientId.set(clientId)
        }

        Glean.shared.initialize(uploadEnabled: Settings.getToggle(.sendAnonymousUsageData))
        
        // Send "at startup" telemetry
        GleanMetrics.Shortcuts.shortcutsOnHomeNumber.set(Int64(ShortcutsManager.shared.numberOfShortcuts))
        GleanMetrics.TrackingProtection.hasAdvertisingBlocked.set(Settings.getToggle(.blockAds))
        GleanMetrics.TrackingProtection.hasAnalyticsBlocked.set(Settings.getToggle(.blockAnalytics))
        GleanMetrics.TrackingProtection.hasContentBlocked.set(Settings.getToggle(.blockOther))
        GleanMetrics.TrackingProtection.hasSocialBlocked.set(Settings.getToggle(.blockSocial))
        GleanMetrics.MozillaProducts.hasFirefoxInstalled.set(UIApplication.shared.canOpenURL(URL(string: "firefox://")!))
    }
        
    func setupExperimentation() {
        if !Settings.getToggle(.sendAnonymousUsageData) {
            NSLog("Not setting up Nimbus because sendAnonymousUsageData is disabled") // TODO Remove
            return
        }
        
        // Hook up basic logging.
        if !RustLog.shared.tryEnable({ (level, tag, message) -> Bool in
            NSLog("[RUST][\(tag ?? "no-tag")] \(message)")
            return true
        }) {
            NSLog("ERROR: Unable to enable logging from Rust")
        }

        // Enable networking.
        Viaduct.shared.useReqwestBackend()

        let errorReporter: NimbusErrorReporter = { err in
            NSLog("NIMBUS ERROR: \(err)")
        }
        
        do {
            guard let nimbusServerSettings = NimbusServerSettings.createFromInfoDictionary(), let nimbusAppSettings = NimbusAppSettings.createFromInfoDictionary() else {
                NSLog("Nimbus not enabled: could not load settings from Info.plist")
                return
            }
            
            guard let databasePath = Nimbus.defaultDatabasePath() else {
                NSLog("Nimbus not enabled: unable to determine database path")
                return
            }
            
            self.nimbusApi = try Nimbus.create(nimbusServerSettings, appSettings: nimbusAppSettings, dbPath: databasePath, resourceBundles: [], errorReporter: errorReporter)
            self.nimbusApi?.initialize()
            self.nimbusApi?.fetchExperiments()
        } catch {
            NSLog("ERROR: Unable to create Nimbus: \(error)")
        }
    }

    func presentModal(viewController: UIViewController, animated: Bool) {
        window?.rootViewController?.present(viewController, animated: animated, completion: nil)
    }
    
    func presentSheet(viewController: UIViewController) {
        let vc = SheetModalViewController(containerViewController: viewController)
        vc.modalPresentationStyle = .overCurrentContext
        // keep false
        // modal animation will be handled in VC itself
        window?.rootViewController?.present(vc, animated: false)
    }
}

protocol ModalDelegate {
    func presentModal(viewController: UIViewController, animated: Bool)
    func presentSheet(viewController: UIViewController)
}

extension UINavigationController {
    override open var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}
