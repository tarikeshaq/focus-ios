/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit
import SnapKit
import Telemetry
import LocalAuthentication
import StoreKit
import Intents
import Glean

class BrowserViewController: UIViewController {
    let appSplashController: AppSplashController

    private var context = LAContext()
    private let mainContainerView = UIView(frame: .zero)
    let darkView = UIView()

    private let webViewController = WebViewController()
    private let webViewContainer = UIView()

    var modalDelegate: ModalDelegate?

    private var keyboardState: KeyboardState?
    private let browserToolbar = BrowserToolbar()
    private var homeViewController: HomeViewController!
    private let overlayView = OverlayView()
    private let searchEngineManager = SearchEngineManager(prefs: UserDefaults.standard)
    private let urlBarContainer = URLBarContainer()
    private var urlBar: URLBar!
    private let requestHandler = RequestHandler()
    private let searchSuggestClient = SearchSuggestClient()
    private var findInPageBar: FindInPageBar?
    private var fillerView: UIView?
    private let alertStackView = UIStackView() // All content that appears above the footer should be added to this view. (Find In Page/SnackBars)
    private let shortcutsContainer = UIStackView()
    private let shortcutsBackground = UIView()

    private var toolbarBottomConstraint: Constraint!
    private var urlBarTopConstraint: Constraint!
    private var homeViewBottomConstraint: Constraint!
    private var browserBottomConstraint: Constraint!
    private var lastScrollOffset = CGPoint.zero
    private var lastScrollTranslation = CGPoint.zero
    private var scrollBarOffsetAlpha: CGFloat = 0
    private var scrollBarState: URLBarScrollState = .expanded
    private var background = UIImageView()

    private enum URLBarScrollState {
        case collapsed
        case expanded
        case transitioning
        case animating
    }

    private var trackingProtectionStatus: TrackingProtectionStatus = .on(TPPageStats()) {
        didSet {
            urlBar.updateTrackingProtectionBadge(trackingStatus: trackingProtectionStatus, shouldDisplayShieldIcon:  urlBar.inBrowsingMode ? self.webViewController.connectionIsSecure : true )
        }
    }

    private var homeViewContainer = UIView()

    fileprivate var showsToolsetInURLBar = false {
        didSet {
            if showsToolsetInURLBar {
                browserBottomConstraint.deactivate()
            } else {
                browserBottomConstraint.activate()
            }
        }
    }

    private let searchSuggestionsDebouncer = Debouncer(timeInterval: 0.1)
    private var shouldEnsureBrowsingMode = false
    private var isIPadRegularDimensions: Bool = false {
        didSet {
            overlayView.isIpadView = isIPadRegularDimensions
        }
    }
    private var initialUrl: URL?
    var tipManager: TipManager
    var shortcutManager: ShortcutsManager

    static let userDefaultsTrackersBlockedKey = "lifetimeTrackersBlocked"

    init(appSplashController: AppSplashController, tipManager: TipManager = TipManager.shared, shortcutManager: ShortcutsManager = ShortcutsManager.shared) {
        self.appSplashController = appSplashController
        self.tipManager = tipManager
        self.shortcutManager = shortcutManager
        super.init(nibName: nil, bundle: nil)
        shortcutManager.delegate = self
        KeyboardHelper.defaultHelper.addDelegate(delegate: self)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("BrowserViewController hasn't implemented init?(coder:)")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    fileprivate func addShortcutsBackgroundConstraints() {
        shortcutsBackground.backgroundColor = isIPadRegularDimensions ? .systemBackground.withAlphaComponent(0.85) : .foundation
        shortcutsBackground.layer.cornerRadius = isIPadRegularDimensions ? 10 : 0
        
        if isIPadRegularDimensions {
            shortcutsBackground.snp.makeConstraints { make in
                make.top.equalTo(urlBarContainer.snp.bottom)
                make.width.equalTo(UIConstants.layout.shortcutsBackgroundWidthIPad)
                make.height.equalTo(UIConstants.layout.shortcutsBackgroundHeightIPad)
                make.centerX.equalTo(urlBarContainer)
            }
        } else {
            shortcutsBackground.snp.makeConstraints { make in
                make.top.equalTo(urlBarContainer.snp.bottom)
                make.left.right.equalToSuperview()
                make.height.equalTo(UIConstants.layout.shortcutsBackgroundHeight)
            }
        }
    }
    
    fileprivate func addShortcutsContainerConstraints() {
        shortcutsContainer.snp.makeConstraints { make in
            make.top.equalTo(urlBarContainer.snp.bottom).offset(isIPadRegularDimensions ? UIConstants.layout.shortcutsContainerOffsetIPad : UIConstants.layout.shortcutsContainerOffset)
            make.width.equalTo(isIPadRegularDimensions ?
                               UIConstants.layout.shortcutsContainerWidthIPad :
                                UIConstants.layout.shortcutsContainerWidth).priority(.medium)
            make.height.equalTo(isIPadRegularDimensions ?
                                UIConstants.layout.shortcutViewHeightIPad :
                                    UIConstants.layout.shortcutViewHeight)
            make.centerX.equalToSuperview()
            make.leading.greaterThanOrEqualTo(mainContainerView).inset(8)
            make.trailing.lessThanOrEqualTo(mainContainerView).inset(-8)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupBiometrics()
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
        view.addSubview(mainContainerView)
        
        isIPadRegularDimensions = traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular

        darkView.isHidden = true
        darkView.backgroundColor = UIConstants.colors.background
        darkView.alpha = 0.4
        view.addSubview(darkView)
        darkView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        mainContainerView.snp.makeConstraints { make in
            make.top.bottom.leading.width.equalToSuperview()
        }

        webViewController.delegate = self

        setupBackgroundImage()
        background.contentMode = .scaleAspectFill
        mainContainerView.addSubview(background)

        mainContainerView.addSubview(homeViewContainer)

        webViewContainer.isHidden = true
        mainContainerView.addSubview(webViewContainer)

        urlBarContainer.alpha = 0
        mainContainerView.addSubview(urlBarContainer)

        browserToolbar.isHidden = true
        browserToolbar.alpha = 0
        browserToolbar.delegate = self
        browserToolbar.translatesAutoresizingMaskIntoConstraints = false
        mainContainerView.addSubview(browserToolbar)

        overlayView.isHidden = true
        overlayView.alpha = 0
        overlayView.delegate = self
        overlayView.backgroundColor = isIPadRegularDimensions ? .clear : .scrim.withAlphaComponent(0.48)
        overlayView.setSearchSuggestionsPromptViewDelegate(delegate: self)
        mainContainerView.addSubview(overlayView)
        
        mainContainerView.addSubview(shortcutsBackground)
        shortcutsBackground.isHidden = true
        addShortcutsBackgroundConstraints()
        setupShortcuts()
        mainContainerView.addSubview(shortcutsContainer)

        background.snp.makeConstraints { make in
            make.edges.equalTo(mainContainerView)
        }

        urlBarContainer.snp.makeConstraints { make in
            make.top.leading.trailing.equalTo(mainContainerView)
            make.height.equalTo(mainContainerView).multipliedBy(0.6).priority(500)
        }

        browserToolbar.snp.makeConstraints { make in
            make.leading.trailing.equalTo(mainContainerView)
            toolbarBottomConstraint = make.bottom.equalTo(mainContainerView).constraint
        }

        homeViewContainer.snp.makeConstraints { make in
            make.top.equalTo(mainContainerView.safeAreaLayoutGuide.snp.top)
            make.leading.trailing.equalTo(mainContainerView)
            homeViewBottomConstraint = make.bottom.equalTo(mainContainerView).constraint
            homeViewBottomConstraint.activate()
        }

        webViewContainer.snp.makeConstraints { make in
            make.top.equalTo(urlBarContainer.snp.bottom).priority(500)
            make.bottom.equalTo(mainContainerView).priority(500)
            browserBottomConstraint = make.bottom.equalTo(browserToolbar.snp.top).priority(1000).constraint

            if !showsToolsetInURLBar {
                browserBottomConstraint.activate()
            }

            make.leading.trailing.equalTo(mainContainerView)
        }
        
        addShortcutsContainerConstraints()
        
        view.addSubview(alertStackView)
        alertStackView.axis = .vertical
        alertStackView.alignment = .center

        // true if device is an iPad or is an iPhone in landscape mode
        showsToolsetInURLBar = (UIDevice.current.userInterfaceIdiom == .pad && (UIScreen.main.bounds.width == view.frame.size.width || view.frame.size.width > view.frame.size.height)) || (UIDevice.current.userInterfaceIdiom == .phone && view.frame.size.width > view.frame.size.height)

        containWebView()
        createHomeView()
        createURLBar()
        updateViewConstraints()
        
        overlayView.snp.makeConstraints { make in
            make.top.equalTo(urlBarContainer.snp.bottom)
            make.leading.trailing.equalTo(mainContainerView)
            make.bottom.equalTo(homeViewController.tipViewTop)
        }

        // Listen for request desktop site notifications
        NotificationCenter.default.addObserver(forName: Notification.Name(rawValue: UIConstants.strings.requestDesktopNotification), object: nil, queue: nil) { _ in
            self.webViewController.requestUserAgentChange()
        }

        // Listen for request mobile site notifications
        NotificationCenter.default.addObserver(forName: Notification.Name(rawValue: UIConstants.strings.requestMobileNotification), object: nil, queue: nil) { _ in
            self.webViewController.requestUserAgentChange()
        }

        let dropInteraction = UIDropInteraction(delegate: self)
        view.addInteraction(dropInteraction)

        // Listen for find in page actvitiy notifications
        NotificationCenter.default.addObserver(forName: Notification.Name(rawValue: UIConstants.strings.findInPageNotification), object: nil, queue: nil) { _ in
            self.updateFindInPageVisibility(visible: true, text: "")
        }

        guard shouldEnsureBrowsingMode else { return }
        ensureBrowsingMode()
        guard let url = initialUrl else { return }
        submit(url: url)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override func viewWillAppear(_ animated: Bool) {
        navigationController?.setNavigationBarHidden(true, animated: animated)

        let homeViewToolset = homeViewController.toolbar.toolset
        homeViewToolset.setHighlightWhatsNew(shouldHighlight: homeViewToolset.shouldShowWhatsNew())
        homeViewController.toolbar.layoutIfNeeded()
        browserToolbar.toolset.setHighlightWhatsNew(shouldHighlight: browserToolbar.toolset.shouldShowWhatsNew())
        browserToolbar.layoutIfNeeded()

        super.viewWillAppear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        // Prevent the keyboard from showing up until after the user has viewed the Intro.
        let userHasSeenIntro = UserDefaults.standard.integer(forKey: AppDelegate.prefIntroDone) == AppDelegate.prefIntroVersion

        if userHasSeenIntro && !urlBar.inBrowsingMode {
            urlBar.activateTextField()
        }

        super.viewDidAppear(animated)
    }

    private func setupBiometrics() {
        // Register for foreground notification to check biometric authentication
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { notification in
            var biometricError: NSError?

            // Check if user is already in a cleared session, or doesn't have biometrics enabled in settings
            if  !Settings.getToggle(SettingsToggle.biometricLogin) || !AppDelegate.needsAuthenticated || self.webViewContainer.isHidden {
                self.appSplashController.toggleSplashView(hide: true)
                return
            }
            AppDelegate.needsAuthenticated = false

            self.context = LAContext()
            self.context.localizedReason = String(format: UIConstants.strings.authenticationReason, AppInfo.productName)
            self.context.localizedCancelTitle = UIConstants.strings.newSessionFromBiometricFailure

            if self.context.canEvaluatePolicy(LAPolicy.deviceOwnerAuthentication, error: &biometricError) {
                self.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: self.context.localizedReason) {
                    [unowned self] (success, _) in
                    DispatchQueue.main.async {
                        if success {
                            self.showToolbars()
                            self.appSplashController.toggleSplashView(hide: true)
                        } else {
                            // Clear the browser session, as the user failed to authenticate
                            self.resetBrowser(hidePreviousSession: true)
                            self.appSplashController.toggleSplashView(hide: true)
                        }
                    }
                }
            } else {
                // Ran into an error with biometrics, so disable them and clear the browser:
                Settings.set(false, forToggle: SettingsToggle.biometricLogin)
                self.resetBrowser()
                self.appSplashController.toggleSplashView(hide: true)
            }
        }
    }
    
    private func addShortcuts() {
        if shortcutManager.numberOfShortcuts != 0 {
            for i in 0..<shortcutManager.numberOfShortcuts {
                let shortcut = shortcutManager.shortcutAt(index: i)
                let shortcutView = ShortcutView(shortcut: shortcut, isIpad: isIPadRegularDimensions)
                shortcutView.setContentCompressionResistancePriority(.required, for: .horizontal)
                shortcutView.setContentHuggingPriority(.required, for: .horizontal)
                shortcutView.delegate = self
                shortcutsContainer.addArrangedSubview(shortcutView)
                shortcutView.snp.makeConstraints { make in
                    make.width.equalTo(isIPadRegularDimensions ?
                                        UIConstants.layout.shortcutViewWidthIPad :
                                        UIConstants.layout.shortcutViewWidth)
                    make.height.equalTo(isIPadRegularDimensions ?
                                            UIConstants.layout.shortcutViewHeightIPad :
                                            UIConstants.layout.shortcutViewHeight)
                }
            }
        }
        if shortcutManager.numberOfShortcuts < UIConstants.maximumNumberOfShortcuts {
            shortcutsContainer.addArrangedSubview(UIView())
        }
    }
    
    private func setupShortcuts() {
        shortcutsContainer.axis = .horizontal
        shortcutsContainer.alignment = .leading
        shortcutsContainer.spacing = isIPadRegularDimensions ?
            UIConstants.layout.shortcutsContainerSpacingIPad :
            UIConstants.layout.shortcutsContainerSpacing
        
        addShortcuts()
    }
    
    @objc func orientationChanged() {
        setupBackgroundImage()
    }
    
    func setupBackgroundImage() {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            background.image = UIApplication.shared.orientation?.isLandscape == true ? #imageLiteral(resourceName: "background_iphone_landscape") : #imageLiteral(resourceName: "background_iphone_portrait")
        case .pad:
            background.image = UIApplication.shared.orientation?.isLandscape == true ? #imageLiteral(resourceName: "background_ipad_landscape") : #imageLiteral(resourceName: "background_ipad_portrait")
        default:
            background.image = #imageLiteral(resourceName: "background_iphone_portrait")
            
        }
    }

    // These functions are used to handle displaying and hiding the keyboard after the splash view is animated
    public func activateUrlBarOnHomeView() {

        // Do not activate if a modal is presented
        if self.presentedViewController != nil {
            return
        }

        // Do not activate if we are showing a web page, nor the overlayView hidden
        if !(urlBar.inBrowsingMode || overlayView.isHidden) {
            return
        }

        urlBar.activateTextField()
    }

    public func deactivateUrlBarOnHomeView() {
        urlBar.dismissTextField()
    }
    
    public func dismissSettings() {
        if self.presentedViewController?.children.first is SettingsViewController {
            self.presentedViewController?.children.first?.dismiss(animated: true, completion: nil)
        }
    }
    
    public func dismissActionSheet() {
        if self.presentedViewController is PhotonActionSheet {
            self.presentedViewController?.dismiss(animated: true, completion: nil)
            photonActionSheetDidDismiss()
        }
    }

    private func containWebView() {
        addChild(webViewController)
        webViewContainer.addSubview(webViewController.view)
        webViewController.didMove(toParent: self)

        webViewController.view.snp.makeConstraints { make in
            make.edges.equalTo(webViewContainer.snp.edges)
        }
    }

    public func exitFullScreenVideo() {
        let js = "document.getElementsByTagName('video')[0].webkitExitFullScreen()"
        webViewController.evaluate(js, completion: nil)
    }

    private func createHomeView() {
        homeViewController = HomeViewController(tipManager: tipManager)
        homeViewController.delegate = self
        homeViewController.toolbar.toolset.delegate = self
        install(homeViewController, on: homeViewContainer)
    }

    private func createURLBar() {
        
        urlBar = URLBar()
        urlBar.delegate = self
        urlBar.toolsetDelegate = self
        urlBar.shrinkFromView = urlBarContainer
        urlBar.isIPadRegularDimensions = isIPadRegularDimensions
        urlBar.shouldShowToolset = showsToolsetInURLBar
        mainContainerView.insertSubview(urlBar, aboveSubview: urlBarContainer)

        addURLBarConstraints()
        
    }
    
    private func addURLBarConstraints() {
        
        urlBar.snp.makeConstraints { make in
            urlBarTopConstraint = make.top.equalTo(mainContainerView.safeAreaLayoutGuide.snp.top).constraint
            
            if isIPadRegularDimensions {
                make.leading.trailing.equalToSuperview()
                make.centerX.equalToSuperview()
                make.bottom.equalTo(urlBarContainer)
            } else {
                make.bottom.equalTo(urlBarContainer)
                make.leading.trailing.equalToSuperview()
            }
        }
    }

    private func buildTrackingProtectionMenu(info: TPPageStats?) -> PhotonActionSheet {
        var actions = [[PhotonActionSheetItem]]()
        if info != nil {
            let titleItem = PhotonActionSheetItem(title: UIConstants.strings.trackingProtectionLabel, text: UIConstants.strings.trackingProtectionLabelDescription, textStyle: .subtitle, iconString: "tracking_protection", isEnabled: true, accessory: .Switch)
            actions.append([titleItem])
        } else {
            let titleItem = PhotonActionSheetItem(title: UIConstants.strings.trackingProtectionLabel, iconString: "tracking_protection_off", isEnabled: false, accessory: .Switch)
            actions.append([titleItem])
        }
        let totalCount = PhotonActionSheetItem(title: UIConstants.strings.trackersBlocked, accessory: .Text, accessoryText: String(info?.total ?? 0), bold: true)
        let adCount = PhotonActionSheetItem(title: UIConstants.strings.adTrackerLabel, accessory: .Text, accessoryText: String(info?.adCount ?? 0))
        let analyticCount = PhotonActionSheetItem(title: UIConstants.strings.analyticTrackerLabel, accessory: .Text, accessoryText: String(info?.analyticCount ?? 0))
        let socialCount = PhotonActionSheetItem(title: UIConstants.strings.socialTrackerLabel, accessory: .Text, accessoryText: String(info?.socialCount ?? 0))
        let contentCount = PhotonActionSheetItem(title: UIConstants.strings.contentTrackerLabel, accessory: .Text, accessoryText: String(info?.contentCount ?? 0))
        actions.append([totalCount, adCount, analyticCount, socialCount, contentCount])
        return PhotonActionSheet(actions: actions)
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()
        alertStackView.snp.remakeConstraints { make in
            make.centerX.equalTo(self.view)
            make.width.equalTo(self.view.snp.width)

            if let keyboardHeight = keyboardState?.intersectionHeightForView(view: self.view), keyboardHeight > 0 {
                make.bottom.equalTo(self.view).offset(-keyboardHeight)
            } else if !browserToolbar.isHidden {
                // is an iPhone
                make.bottom.equalTo(self.browserToolbar.snp.top).priority(.low)
                make.bottom.lessThanOrEqualTo(self.view.safeAreaLayoutGuide.snp.bottom).priority(.required)
            } else {
                // is an iPad
                make.bottom.equalTo(self.view.safeAreaLayoutGuide.snp.bottom)
            }
        }
    }

    func updateFindInPageVisibility(visible: Bool, text: String = "") {
        if visible {
            if findInPageBar == nil {
                Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.open, object: TelemetryEventObject.findInPageBar)

                urlBar.dismiss {
                    // Start our animation after urlBar dismisses
                    let findInPageBar = FindInPageBar()
                    self.findInPageBar = findInPageBar
                    let fillerView = UIView()
                    self.fillerView = fillerView
                    fillerView.backgroundColor = UIConstants.Photon.Grey70
                    findInPageBar.text = text
                    findInPageBar.delegate = self

                    self.alertStackView.addArrangedSubview(findInPageBar)
                    self.mainContainerView.insertSubview(fillerView, belowSubview: self.browserToolbar)

                    findInPageBar.snp.makeConstraints { make in
                        make.height.equalTo(UIConstants.ToolbarHeight)
                        make.leading.trailing.equalTo(self.alertStackView)
                        make.bottom.equalTo(self.alertStackView.snp.bottom)
                    }
                    fillerView.snp.makeConstraints { make in
                        make.top.equalTo(self.alertStackView.snp.bottom)
                        make.bottom.equalTo(self.view)
                        make.leading.trailing.equalTo(self.alertStackView)
                    }

                    self.view.layoutIfNeeded()
                }
            }
            
            self.findInPageBar?.becomeFirstResponder()
        } else if let findInPageBar = self.findInPageBar {
            findInPageBar.endEditing(true)
            webViewController.evaluate("__firefox__.findDone()", completion: nil)
            findInPageBar.removeFromSuperview()
            fillerView?.removeFromSuperview()
            self.findInPageBar = nil
            self.fillerView = nil
            updateViewConstraints()
        }
    }

    func resetBrowser(hidePreviousSession: Bool = false) {

        // Used when biometrics fail and the previous session should be obscured
        if hidePreviousSession {
            clearBrowser()
            urlBar.activateTextField()
            return
        }

        // Screenshot the browser, showing the screenshot on top.
        let screenshotView = view.snapshotView(afterScreenUpdates: true) ?? UIView()

        mainContainerView.addSubview(screenshotView)
        screenshotView.snp.makeConstraints { make in
            make.edges.equalTo(mainContainerView)
        }

        clearBrowser()

        UIView.animate(withDuration: UIConstants.layout.deleteAnimationDuration, animations: {
            screenshotView.snp.remakeConstraints { make in
                make.centerX.equalTo(self.mainContainerView)
                make.top.equalTo(self.mainContainerView.snp.bottom)
                make.size.equalTo(self.mainContainerView).multipliedBy(0.9)
            }
            screenshotView.alpha = 0
            self.mainContainerView.layoutIfNeeded()
        }, completion: { _ in
            self.urlBar.activateTextField()
            Toast(text: UIConstants.strings.eraseMessage).show()
            screenshotView.removeFromSuperview()
        })

        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.click, object: TelemetryEventObject.eraseButton)

        if #available(iOS 12.0, *) {
            userActivity = SiriShortcuts().getActivity(for: .eraseAndOpen)
            let interaction = INInteraction(intent: eraseIntent, response: nil)
            interaction.donate { (error) in
                if let error = error { print(error.localizedDescription) }
            }
        }
    }

    private func clearBrowser() {
        // Helper function for resetBrowser that handles all the logic of actually clearing user data and the browsing session
        overlayView.currentURL = ""
        webViewController.reset()
        webViewContainer.isHidden = true
        browserToolbar.isHidden = true
        browserToolbar.canGoBack = false
        browserToolbar.canGoForward = false
        browserToolbar.canDelete = false
        urlBar.removeFromSuperview()
        urlBarContainer.alpha = 0
        homeViewController.refreshTipsDisplay()
        homeViewController.view.isHidden = false
        createURLBar()
        shortcutsContainer.isHidden = false
        shortcutsBackground.isHidden = true

        // Clear the cache and cookies, starting a new session.
        WebCacheUtils.reset()
        requestReviewIfNecessary()
        mainContainerView.layoutIfNeeded()
    }

    func requestReviewIfNecessary() {
        if AppInfo.isTesting() { return }
        let currentLaunchCount = UserDefaults.standard.integer(forKey: UIConstants.strings.userDefaultsLaunchCountKey)
        let threshold = UserDefaults.standard.integer(forKey: UIConstants.strings.userDefaultsLaunchThresholdKey)

        if threshold == 0 {
            UserDefaults.standard.set(14, forKey: UIConstants.strings.userDefaultsLaunchThresholdKey)
            return
        }

        // Make sure the request isn't within 90 days of last request
        let minimumDaysBetweenReviewRequest = 90
        let daysSinceLastRequest: Int
        if let previousRequest = UserDefaults.standard.object(forKey: UIConstants.strings.userDefaultsLastReviewRequestDate) as? Date {
            daysSinceLastRequest = Calendar.current.dateComponents([.day], from: previousRequest, to: Date()).day ?? 0
        } else {
            // No previous request date found, meaning we've never asked for a review
            daysSinceLastRequest = minimumDaysBetweenReviewRequest
        }

        if currentLaunchCount <= threshold ||  daysSinceLastRequest < minimumDaysBetweenReviewRequest {
            return
        }

        UserDefaults.standard.set(Date(), forKey: UIConstants.strings.userDefaultsLastReviewRequestDate)

        // Increment the threshold by 50 so the user is not constantly pestered with review requests
        switch threshold {
            case 14:
                UserDefaults.standard.set(64, forKey: UIConstants.strings.userDefaultsLaunchThresholdKey)
            case 64:
                UserDefaults.standard.set(114, forKey: UIConstants.strings.userDefaultsLaunchThresholdKey)
            default:
                break
        }

        SKStoreReviewController.requestReview()
    }

    private func showSettings(shouldScrollToSiri: Bool = false) {
        guard let modalDelegate = modalDelegate else { return }

        let settingsViewController = SettingsViewController(searchEngineManager: searchEngineManager, whatsNew: browserToolbar.toolset, shouldScrollToSiri: shouldScrollToSiri)
        let settingsNavController = UINavigationController(rootViewController: settingsViewController)
        settingsNavController.modalPresentationStyle = .formSheet

        modalDelegate.presentModal(viewController: settingsNavController, animated: true)

        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.click, object: TelemetryEventObject.settingsButton)
    }

    @available(iOS 12.0, *)
    private func showSiriFavoriteSettings() {
        guard let modalDelegate = modalDelegate else { return }

        urlBar.shouldPresent = false
        let siriFavoriteViewController = SiriFavoriteViewController()
        let siriFavoriteNavController = UINavigationController(rootViewController: siriFavoriteViewController)
        siriFavoriteNavController.modalPresentationStyle = .formSheet

        modalDelegate.presentModal(viewController: siriFavoriteNavController, animated: true)
    }

    func ensureBrowsingMode() {
        guard urlBar != nil else { shouldEnsureBrowsingMode = true; return }
        guard !urlBar.inBrowsingMode else { return }

        urlBarContainer.alpha = 1
        urlBar.ensureBrowsingMode()

        shouldEnsureBrowsingMode = false
    }
    
    func submit(text: String) {
        var url = URIFixup.getURL(entry: text)
        if url == nil {
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.typeQuery, object: TelemetryEventObject.searchBar)
            Telemetry.default.recordSearch(location: .actionBar, searchEngine: searchEngineManager.activeEngine.getNameOrCustom())
            url = searchEngineManager.activeEngine.urlForQuery(text)
        } else {
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.typeURL, object: TelemetryEventObject.searchBar)
        }
        
        if let url = url {
            submit(url: url)
        }
    }

    func submit(url: URL) {
        // If this is the first navigation, show the browser and the toolbar.
        guard isViewLoaded else { initialUrl = url; return }
        shortcutsContainer.isHidden = true
        shortcutsBackground.isHidden = true
        
        if isIPadRegularDimensions {
            urlBar.snp.makeConstraints { make in
                make.width.equalTo(view)
                make.leading.equalTo(view)
            }
        }

        if webViewContainer.isHidden {
            webViewContainer.isHidden = false
            homeViewController.view.isHidden = true
            urlBar.inBrowsingMode = true

            if !showsToolsetInURLBar {
                browserToolbar.animateHidden(false, duration: UIConstants.layout.toolbarFadeAnimationDuration)
            }
        }

        webViewController.load(URLRequest(url: url))
        if urlBar.url == nil {
            urlBar.url = url
        }
        guard #available(iOS 12.0, *), let savedUrl = UserDefaults.standard.value(forKey: "favoriteUrl") as? String else { return }
        if let currentDomain = url.baseDomain, let savedDomain = URL(string: savedUrl)?.baseDomain, currentDomain == savedDomain {
            userActivity = SiriShortcuts().getActivity(for: .openURL)
        }
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        // Fixes the issue of a user fresh-opening Focus via Split View
        guard isViewLoaded else { return }

        // UIDevice.current.orientation isn't reliable. See https://bugzilla.mozilla.org/show_bug.cgi?id=1315370#c5
        // As a workaround, consider the phone to be in landscape if the new width is greater than the height.
        showsToolsetInURLBar = (UIDevice.current.userInterfaceIdiom == .pad && (UIScreen.main.bounds.width == size.width || size.width > size.height)) || (UIDevice.current.userInterfaceIdiom == .phone && size.width > size.height)
        
        //isIPadRegularDimensions check if the device is a Ipad and the app is not in split mode
        isIPadRegularDimensions = ((UIDevice.current.userInterfaceIdiom == .pad && (UIScreen.main.bounds.width == size.width || size.width > size.height))) || (UIDevice.current.userInterfaceIdiom == .pad &&  UIApplication.shared.orientation?.isPortrait == true && UIScreen.main.bounds.width == size.width)
        urlBar.isIPadRegularDimensions = isIPadRegularDimensions
        
        if urlBar.state == .default {
            urlBar.snp.removeConstraints()
            addURLBarConstraints()
            
        } else {
            urlBarContainer.snp.makeConstraints { make in
                make.width.equalTo(view)
                make.leading.equalTo(view)
            }
        }
        
        urlBar.updateConstraints()
        browserToolbar.updateConstraints()
        
        homeViewController.toolbar.isIPadRegularDimensions = isIPadRegularDimensions
        
        shortcutsContainer.spacing = size.width < UIConstants.layout.smallestSplitViewMaxWidthLimit ?
                                        UIConstants.layout.shortcutsContainerSpacingSmallestSplitView :
                                        (isIPadRegularDimensions ? UIConstants.layout.shortcutsContainerSpacingIPad : UIConstants.layout.shortcutsContainerSpacing)

        coordinator.animate(alongsideTransition: { _ in
            self.urlBar.shouldShowToolset = self.showsToolsetInURLBar

            if self.homeViewController == nil && self.scrollBarState != .expanded {
                self.hideToolbars()
            }

            self.browserToolbar.animateHidden(!self.urlBar.inBrowsingMode || self.showsToolsetInURLBar, duration: coordinator.transitionDuration, completion: {
                self.updateViewConstraints()
            })
        })
        
        shortcutsContainer.snp.removeConstraints()
        addShortcutsContainerConstraints()
        
        shortcutsBackground.snp.removeConstraints()
        addShortcutsBackgroundConstraints()
    }

    private func presentImageActionSheet(title: String, link: String?, saveAction: @escaping () -> Void, copyAction: @escaping () -> Void) {

        var normalizedTitle = title
        if title.count > UIConstants.layout.truncateCharactersLimit {
            normalizedTitle = String("\(title.prefix(UIConstants.layout.truncateHeadCharactersCount))\(UIConstants.strings.truncateLeader)\(title.suffix(UIConstants.layout.truncateTailCharactersCount))")
        }

        let alertController = UIAlertController(title: normalizedTitle, message: nil, preferredStyle: .actionSheet)

        if let link = link {
            alertController.addAction(UIAlertAction(title: UIConstants.strings.copyLink, style: .default) { _ in
                UIPasteboard.general.string = link
            })

            alertController.addAction(UIAlertAction(title: UIConstants.strings.shareLink, style: .default) { _ in
                let activityViewController = UIActivityViewController(activityItems: [link], applicationActivities: nil)
                self.present(activityViewController, animated: true, completion: nil)
            })
        }

        alertController.addAction(UIAlertAction(title: UIConstants.strings.saveImage, style: .default) { _ in saveAction() })
        alertController.addAction(UIAlertAction(title: UIConstants.strings.copyImage, style: .default) { _ in copyAction() })
        alertController.addAction(UIAlertAction(title: UIConstants.strings.cancel, style: .cancel))

        alertController.popoverPresentationController?.permittedArrowDirections = UIPopoverArrowDirection(rawValue: 0)
        alertController.popoverPresentationController?.sourceView = self.view
        alertController.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.size.width / 2.0, y: self.view.bounds.size.height / 2.0, width: 1.0, height: 1.0)
        present(alertController, animated: true, completion: nil)
    }

    @objc private func selectLocationBar() {
        showToolbars()
        urlBar.activateTextField()
        shortcutsContainer.isHidden = false
        shortcutsBackground.isHidden = !urlBar.inBrowsingMode
    }

    @objc private func reload() {
        webViewController.reload()
    }

    @objc private func goBack() {
        webViewController.goBack()
    }

    @objc private func goForward() {
        webViewController.goForward()
    }
    
    @objc private func showFindInPage() {
        self.updateFindInPageVisibility(visible: true)
    }

    private func toggleURLBarBackground(isBright: Bool) {
        if urlBar.isEditing {
            urlBarContainer.barState = .editing
        } else if case .on = trackingProtectionStatus {
            urlBarContainer.barState = .bright
        } else {
            urlBarContainer.barState = .dark
        }
    }

    private func toggleToolbarBackground() {
        switch trackingProtectionStatus {
        case .off:
            browserToolbar.color = .dark
        case .on:
            browserToolbar.color = .bright
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        return [
                UIKeyCommand(title: UIConstants.strings.selectLocationBarTitle,
                             image: nil,
                             action: #selector(BrowserViewController.selectLocationBar),
                             input: "l",
                             modifierFlags: .command,
                             propertyList: nil),
                UIKeyCommand(title: UIConstants.strings.browserReload,
                             image: nil,
                             action: #selector(BrowserViewController.reload),
                             input: "r",
                             modifierFlags: .command,
                             propertyList: nil),
                UIKeyCommand(title: UIConstants.strings.browserBack,
                             image: nil,
                             action: #selector(BrowserViewController.goBack),
                             input: "[",
                             modifierFlags: .command,
                             propertyList: nil),
                UIKeyCommand(title: UIConstants.strings.browserForward,
                             image: nil,
                             action: #selector(BrowserViewController.goForward),
                             input: "]",
                             modifierFlags: .command,
                             propertyList: nil),
                UIKeyCommand(title: UIConstants.strings.shareMenuFindInPage,
                             image: nil,
                             action: #selector(BrowserViewController.showFindInPage),
                             input: "f",
                             modifierFlags: .command,
                             propertyList: nil),
        ]
    }

    func refreshTipsDisplay() {
        homeViewController.refreshTipsDisplay()
    }

    private func getNumberOfLifetimeTrackersBlocked(userDefaults: UserDefaults = UserDefaults.standard) -> Int {
        return userDefaults.integer(forKey: BrowserViewController.userDefaultsTrackersBlockedKey)
    }

    private func setNumberOfLifetimeTrackersBlocked(numberOfTrackers: Int) {
        UserDefaults.standard.set(numberOfTrackers, forKey: BrowserViewController.userDefaultsTrackersBlockedKey)
    }

    func updateURLBar() {
        if webViewController.url?.absoluteString != "about:blank" {
            urlBar.url = webViewController.url
            overlayView.currentURL = urlBar.url?.absoluteString ?? ""
        }
    }
}

extension BrowserViewController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        return session.canLoadObjects(ofClass: URL.self)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        _ = session.loadObjects(ofClass: URL.self) { urls in

            guard let url = urls.first else {
                return
            }

            self.ensureBrowsingMode()
            self.urlBar.fillUrlBar(text: url.absoluteString)
            self.submit(url: url)
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.drop, object: TelemetryEventObject.searchBar)
        }
    }
}

extension BrowserViewController: FindInPageBarDelegate {
    func findInPage(_ findInPage: FindInPageBar, didTextChange text: String) {
        find(text, function: "find")
    }

    func findInPage(_ findInPage: FindInPageBar, didFindNextWithText text: String) {
        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.click, object: TelemetryEventObject.findNext)
        findInPageBar?.endEditing(true)
        find(text, function: "findNext")
    }

    func findInPage(_ findInPage: FindInPageBar, didFindPreviousWithText text: String) {
        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.click, object: TelemetryEventObject.findPrev)
        findInPageBar?.endEditing(true)
        find(text, function: "findPrevious")
    }

    func findInPageDidPressClose(_ findInPage: FindInPageBar) {
        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.close, object: TelemetryEventObject.findInPageBar)
        updateFindInPageVisibility(visible: false)
    }

    private func find(_ text: String, function: String) {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        webViewController.evaluate("__firefox__.\(function)(\"\(escaped)\")", completion: nil)
    }
}

extension BrowserViewController: URLBarDelegate {

    func urlBar(_ urlBar: URLBar, didAddCustomURL url: URL) {
        // Add the URL to the autocomplete list:
        let autocompleteSource = CustomCompletionSource()

        switch autocompleteSource.add(suggestion: url.absoluteString) {
        case .error(.duplicateDomain):
            break
        case .error(let error):
            guard !error.message.isEmpty else { return }
            Toast(text: error.message).show()
        case .success:
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.change, object: TelemetryEventObject.customDomain)
            Toast(text: UIConstants.strings.autocompleteCustomURLAdded).show()
        }
    }

    func urlBar(_ urlBar: URLBar, didEnterText text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        let isOnHomeView = !urlBar.inBrowsingMode
        let shouldShowShortcuts = trimmedText.isEmpty && shortcutManager.numberOfShortcuts != 0
        shortcutsContainer.isHidden = !shouldShowShortcuts
        shortcutsBackground.isHidden = isOnHomeView ? true : !shouldShowShortcuts
        
        if Settings.getToggle(.enableSearchSuggestions) && !trimmedText.isEmpty {
            searchSuggestionsDebouncer.renewInterval()
            searchSuggestionsDebouncer.completion = {
                self.searchSuggestClient.getSuggestions(trimmedText, callback: { suggestions, error in
                    let userInputText = urlBar.userInputText?.trimmingCharacters(in: .whitespaces) ?? ""

                    // Check if this callback is stale (new user input has been requested)
                    if userInputText.isEmpty || userInputText != trimmedText {
                        return
                    }

                    if userInputText == trimmedText {
                        let suggestions = suggestions ?? [trimmedText]
                        DispatchQueue.main.async {
                            self.overlayView.setColorstToSearchButtons()
                            self.overlayView.setSearchQuery(suggestions: suggestions, hideFindInPage: isOnHomeView || text.isEmpty, hideAddToComplete: true)
                        }
                    }
                })
            }
        } else {
            overlayView.setSearchQuery(suggestions: [trimmedText], hideFindInPage: isOnHomeView || text.isEmpty, hideAddToComplete: true)
        }
    }

    func urlBarDidPressScrollTop(_: URLBar, tap: UITapGestureRecognizer) {
        guard !urlBar.isEditing else { return }

        switch scrollBarState {
        case .expanded:
            let y = tap.location(in: urlBar).y

            // If the tap is greater than this threshold, the user wants to type in the URL bar
            if y >= 10 {
                urlBar.activateTextField()
                return
            }

            // Just scroll the vertical position so the page doesn't appear under
            // the notch on the iPhone X
            var point = webViewController.scrollView.contentOffset
            point.y = 0
            webViewController.scrollView.setContentOffset(point, animated: true)
        case .collapsed: showToolbars()
        default: break
        }
    }

    func urlBar(_ urlBar: URLBar, didSubmitText text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)

        guard !text.isEmpty else {
            urlBar.url = webViewController.url
            return
        }

        SearchHistoryUtils.pushSearchToStack(with: text)
        SearchHistoryUtils.isFromURLBar = true

        var url = URIFixup.getURL(entry: text)
        if url == nil {
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.typeQuery, object: TelemetryEventObject.searchBar)
            Telemetry.default.recordSearch(location: .actionBar, searchEngine: searchEngineManager.activeEngine.getNameOrCustom())
            url = searchEngineManager.activeEngine.urlForQuery(text)
        } else {
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.typeURL, object: TelemetryEventObject.searchBar)
        }
        if let urlBarURL = url {
            submit(url: urlBarURL)
            urlBar.url = urlBarURL
        }

        if let urlText = urlBar.url?.absoluteString {
            overlayView.currentURL = urlText
        }

        urlBar.dismiss()
    }

    func urlBarDidDismiss(_ urlBar: URLBar) {
        overlayView.dismiss()
        toggleURLBarBackground(isBright: !webViewController.isLoading)
        shortcutsContainer.isHidden = urlBar.inBrowsingMode
        shortcutsBackground.isHidden = true
    }

    func urlBarDidFocus(_ urlBar: URLBar) {
        let isOnHomeView = !urlBar.inBrowsingMode
        overlayView.present(isOnHomeView: isOnHomeView)
        toggleURLBarBackground(isBright: false)
    }

    func urlBarDidActivate(_ urlBar: URLBar) {
        let shouldShowShortcuts = shortcutManager.numberOfShortcuts != 0
        shortcutsContainer.isHidden = !shouldShowShortcuts
        shortcutsBackground.isHidden = !shouldShowShortcuts || !urlBar.inBrowsingMode
        homeViewController.updateUI(urlBarIsActive: true, isBrowsing: urlBar.inBrowsingMode)
        UIView.animate(withDuration: UIConstants.layout.urlBarTransitionAnimationDuration, animations: {
            self.urlBarContainer.alpha = 1
            self.updateFindInPageVisibility(visible: false)
            self.view.layoutIfNeeded()
        })
    }

    func urlBarDidDeactivate(_ urlBar: URLBar) {
        shortcutsContainer.isHidden = false
        shortcutsBackground.isHidden = true
        homeViewController.updateUI(urlBarIsActive: false)
        UIView.animate(withDuration: UIConstants.layout.urlBarTransitionAnimationDuration) {
            self.urlBarContainer.alpha = 0
            self.view.layoutIfNeeded()
        }
    }

    func urlBarDidTapShield(_ urlBar: URLBar) {
        Telemetry.default.recordEvent(TelemetryEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.open, object: TelemetryEventObject.trackingProtectionDrawer))
        GleanMetrics.TrackingProtection.toolbarShieldClicked.add()

        guard let modalDelegate = modalDelegate else { return }

        switch trackingProtectionStatus {
        case .on:
            Settings.set(true, forToggle: .trackingProtection)
        case .off:
            Settings.set(false, forToggle: .trackingProtection)
        }
        
        let state: TrackingProtectionState = urlBar.inBrowsingMode
        ? .browsing(status: SecureConnectionStatus(
            url: webViewController.url!,
            isSecureConnection: webViewController.connectionIsSecure))
        : .homescreen
        
        let trackingProtectionViewController = TrackingProtectionViewController(state: state)
        trackingProtectionViewController.delegate = self
        if UIDevice.current.userInterfaceIdiom == .pad {
            trackingProtectionViewController.modalPresentationStyle = .popover
            trackingProtectionViewController.popoverPresentationController?.sourceView = urlBar.shieldIcon
            modalDelegate.presentModal(viewController: trackingProtectionViewController, animated: true)
        } else {
            modalDelegate.presentSheet(viewController: trackingProtectionViewController)
        }
    }

    func urlBarDidLongPress(_ urlBar: URLBar) { }
    
    func presentContextMenu(from sender: UIView) {
        var actions: [[PhotonActionSheetItem]] = []
        
        if let url = urlBar.url {
            let utils = OpenUtils(url: url, webViewController: webViewController)
            let items = PageActionSheetItems(url: url)
            
            let shortcut = Shortcut(url: url)
            if shortcutManager.isSaved(shortcut: shortcut) {
                let shortcutItem = [items.removeFromShortcutsItem]
                actions.append(shortcutItem)
            } else if shortcutManager.numberOfShortcuts < UIConstants.maximumNumberOfShortcuts {
                let shortcutItem = [items.addToShortcutsItem]
                actions.append(shortcutItem)
            }
            
            let sharePageItem = PhotonActionSheetItem(title: UIConstants.strings.sharePage, iconString: "icon_openwith_active") { [weak self] _ in
                guard let self = self else { return }
                let shareVC = utils.buildShareViewController()
                
                // Exact frame dimensions taken from presentPhotonActionSheet
                shareVC.popoverPresentationController?.sourceView = sender
                shareVC.popoverPresentationController?.sourceRect = CGRect(x: sender.frame.width/2, y: sender.frame.size.height * 0.75, width: 1, height: 1)
                
                shareVC.becomeFirstResponder()
                self.present(shareVC, animated: true, completion: nil)
            }
            
            var actionItems = [items.findInPageItem]
            actionItems.append(
                webViewController.requestMobileSite
                    ? items.requestMobileItem
                    : items.requestDesktopItem
            )
            
            let copyItem = PhotonActionSheetItem(title: UIConstants.strings.copyAddress, iconString: "icon_link") { [weak self] _ in
                guard let self = self else { return }
                self.urlBar.copyToClipboard()
                Toast(text: UIConstants.strings.copyURLToast).show()
            }
            var shareItems = [copyItem]
            shareItems.append(sharePageItem)
            
            if items.canOpenInFirefox {
                shareItems.append(items.openInFireFoxItem)
            }
            if items.canOpenInChrome {
                shareItems.append(items.openInChromeItem)
            }
            shareItems.append(items.openInSafariItem)
            
            actions.append(actionItems)
            actions.append(shareItems)
        } else {
            let helpItem = PhotonActionSheetItem(title: UIConstants.strings.aboutRowHelp, iconString: "icon_help") { [weak self] _ in
                guard let self = self else { return }
                self.submit(text: "https://support.mozilla.org/en-US/products/focus-firefox/Focus-ios")
            }
            
            actions.append([helpItem])
        }
        
        let settingsItem = PhotonActionSheetItem(title: UIConstants.strings.settingsTitle, iconString: "icon_settings") { [weak self] _ in
            guard let self = self else { return }
            self.showSettings()
        }
        
        actions.append([settingsItem])
        
        let pageActionsMenu = PhotonActionSheet(actions: actions)
        
        presentPhotonActionSheet(pageActionsMenu, from: sender)
    }
}

extension BrowserViewController: PhotonActionSheetDelegate {
    func presentPhotonActionSheet(_ actionSheet: PhotonActionSheet, from sender: UIView, arrowDirection: UIPopoverArrowDirection = .any) {
        actionSheet.modalPresentationStyle = .popover
        
        actionSheet.delegate = self
        
        if let popoverVC = actionSheet.popoverPresentationController {
            popoverVC.delegate = self
            popoverVC.sourceView = sender
            popoverVC.permittedArrowDirections = arrowDirection
        }
        
        present(actionSheet, animated: true, completion: nil)
    }
    
    func photonActionSheetDidDismiss() {
        darkView.isHidden = true
    }
    
    func photonActionSheetDidToggleProtection(enabled: Bool) {
        enabled ? webViewController.enableTrackingProtection() : webViewController.disableTrackingProtection()

        let telemetryEvent = TelemetryEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.change, object: TelemetryEventObject.trackingProtectionToggle)
        telemetryEvent.addExtra(key: "to", value: enabled)
        Telemetry.default.recordEvent(telemetryEvent)
        TipManager.sitesNotWorkingTip = false

        webViewController.reload()
    }
}

extension BrowserViewController: UIAdaptivePresentationControllerDelegate {
    // Returning None here makes sure that the Popover is actually presented as a Popover and
    // not as a full-screen modal, which is the default on compact device classes.
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        return .none
    }
}

extension BrowserViewController: ShortcutViewDelegate {
    func shortcutTapped(shortcut: Shortcut) {
        ensureBrowsingMode()
        urlBar.url = shortcut.url
        deactivateUrlBarOnHomeView()
        submit(url: shortcut.url)
        GleanMetrics.Shortcuts.shortcutOpenedCounter.add()
    }

    func shortcutLongPressed(shortcut: Shortcut, shortcutView: ShortcutView) {
        let removeFromShortcutsItem = PhotonActionSheetItem(title: UIConstants.strings.removeFromShortcuts, iconString: "icon_shortcuts_remove") { action in
            ShortcutsManager.shared.removeFromShortcuts(shortcut: shortcut)
            self.shortcutsBackground.isHidden = self.shortcutManager.numberOfShortcuts == 0 || !self.urlBar.inBrowsingMode ? true : false
            GleanMetrics.Shortcuts.shortcutRemovedCounter["removed_from_home_screen"].add()
        }
        
        var actions: [[PhotonActionSheetItem]] = []
        actions.append([removeFromShortcutsItem])
        
        let shortcutActionsMenu = PhotonActionSheet(actions: actions)
        presentPhotonActionSheet(shortcutActionsMenu, from: shortcutView, arrowDirection: .up)
    }
}

extension BrowserViewController: ShortcutsManagerDelegate {
    func shortcutsUpdated() {
        for subview in shortcutsContainer.subviews {
            subview.removeFromSuperview()
        }
        addShortcuts()
    }
}

extension BrowserViewController: TrackingProtectionDelegate {
    func trackingProtectionDidToggleProtection(enabled: Bool) {
        enabled ? webViewController.enableTrackingProtection() : webViewController.disableTrackingProtection()

        let telemetryEvent = TelemetryEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.change, object: TelemetryEventObject.trackingProtectionToggle)
        telemetryEvent.addExtra(key: "to", value: enabled)
        Telemetry.default.recordEvent(telemetryEvent)
        TipManager.sitesNotWorkingTip = false

        webViewController.reload()
    }
}

extension BrowserViewController: BrowserToolsetDelegate {
    func browserToolsetDidPressBack(_ browserToolset: BrowserToolset) {
        webViewController.goBack()
    }

    private func handleNavigationBack() {
        // Check if the previous site we were on was AMP
        guard let navigatingFromAmpSite = SearchHistoryUtils.pullSearchFromStack()?.hasPrefix(UIConstants.strings.googleAmpURLPrefix) else {
            return
        }

        // Make sure our navigation is not pushed to the SearchHistoryUtils stack (since it already exists there)
        SearchHistoryUtils.isFromURLBar = true

        // This function is now getting called after our new url is set!!
        if !navigatingFromAmpSite {
            SearchHistoryUtils.goBack()
        }
    }

    func browserToolsetDidPressForward(_ browserToolset: BrowserToolset) {
        webViewController.goForward()
    }

    private func handleNavigationForward() {
        // Make sure our navigation is not pushed to the SearchHistoryUtils stack (since it already exists there)
        SearchHistoryUtils.isFromURLBar = true

        // Check if we're navigating to an AMP site *after* the URL bar is updated. This is intentionally grabbing the NEW url
        guard let navigatingToAmpSite = urlBar.url?.absoluteString.hasPrefix(UIConstants.strings.googleAmpURLPrefix) else { return }

        if !navigatingToAmpSite {
            SearchHistoryUtils.goForward()
        }
    }

    func browserToolsetDidPressReload(_ browserToolset: BrowserToolset) {
        webViewController.reload()
    }

    func browserToolsetDidPressStop(_ browserToolset: BrowserToolset) {
        webViewController.stop()
    }
    
    func browserToolsetDidPressDelete(_ browserToolbar: BrowserToolset) {
        updateFindInPageVisibility(visible: false)
        self.resetBrowser()
    }

    func browserToolsetDidPressContextMenu(_ browserToolbar: BrowserToolset, menuButton: InsetButton) {
        updateFindInPageVisibility(visible: false)
        presentContextMenu(from: menuButton)
    }
}

extension BrowserViewController: HomeViewDelegate {

    func shareTrackerStatsButtonTapped(_ sender: UIButton) {
        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.share, object: TelemetryEventObject.trackerStatsShareButton)

        let numberOfTrackersBlocked = getNumberOfLifetimeTrackersBlocked()
        let appStoreUrl = URL(string: String(format: "https://mzl.la/2GZBav0"))
        // Add space after shareTrackerStatsText to add URL in sentence
        let shareTrackerStatsText = "%@, the privacy browser from Mozilla, has already blocked %@ trackers for me. Fewer ads and trackers following me around means faster browsing! Get Focus for yourself here"
        let text = String(format: shareTrackerStatsText + " ", AppInfo.productName, String(numberOfTrackersBlocked))
        let shareController = UIActivityViewController(activityItems: [text, appStoreUrl as Any], applicationActivities: nil)
        // Exact frame dimensions taken from presentPhotonActionSheet
        shareController.popoverPresentationController?.sourceView = sender
        shareController.popoverPresentationController?.sourceRect = CGRect(x: sender.frame.width/2, y: 0, width: 1, height: 1)

        present(shareController, animated: true)
    }
    
    /// Visit the given URL. We make sure we are in browsing mode, and dismiss all modals. This is currently private
    /// because I don't think it is the best API to expose.
    private func visit(url: URL) {
        ensureBrowsingMode()
        deactivateUrlBarOnHomeView()
        dismissSettings()
        dismissActionSheet()
        submit(url: url)
    }

    func didTapTip(_ tip: TipManager.Tip) {
        urlBar.dismiss()
        guard let action = tip.action else { return }
        switch action {
        case .visit(let topic):
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.click, object: TelemetryEventObject.releaseTip)
            visit(url: URL(forSupportTopic: topic))
        case .showSettings(let destination):
            switch destination {
            case .siri:
                Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.click, object: TelemetryEventObject.siriEraseTip)
                showSettings(shouldScrollToSiri: true)
            case .biometric:
                Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.click, object: TelemetryEventObject.biometricTip)
                showSettings()
            case .siriFavorite:
                Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.show, object: TelemetryEventObject.siriFavoriteTip)
                showSiriFavoriteSettings()
            }
        }
    }
}

extension BrowserViewController: OverlayViewDelegate {
    func overlayViewDidPressSettings(_ overlayView: OverlayView) {
        urlBar.dismiss()
        showSettings()
    }

    func overlayViewDidTouchEmptyArea(_ overlayView: OverlayView) {
        urlBar.dismiss()
    }

    func overlayView(_ overlayView: OverlayView, didSearchForQuery query: String) {
        if searchEngineManager.activeEngine.urlForQuery(query) != nil {
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.selectQuery, object: TelemetryEventObject.searchBar)
            Telemetry.default.recordSearch(location: .actionBar, searchEngine: searchEngineManager.activeEngine.getNameOrCustom())
            urlBar(urlBar, didSubmitText: query)
        }

        urlBar.dismiss()
    }

    func overlayView(_ overlayView: OverlayView, didSearchOnPage query: String) {
        updateFindInPageVisibility(visible: true, text: query)
        self.find(query, function: "find")
    }

    func overlayView(_ overlayView: OverlayView, didAddToAutocomplete query: String) {
        urlBar.dismiss()

        let autocompleteSource = CustomCompletionSource()
        switch autocompleteSource.add(suggestion: query) {
        case .error(.duplicateDomain):
            Toast(text: UIConstants.strings.autocompleteCustomURLDuplicate).show()
        case .error(let error):
            guard !error.message.isEmpty else { return }
            Toast(text: error.message).show()
        case .success:
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.change, object: TelemetryEventObject.customDomain)
            Toast(text: UIConstants.strings.autocompleteCustomURLAdded).show()
        }
    }

    func overlayView(_ overlayView: OverlayView, didSubmitText text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            urlBar.url = webViewController.url
            return
        }

        var url = URIFixup.getURL(entry: text)
        if url == nil {
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.typeQuery, object: TelemetryEventObject.searchBar)
            Telemetry.default.recordSearch(location: .actionBar, searchEngine: searchEngineManager.activeEngine.getNameOrCustom())
            url = searchEngineManager.activeEngine.urlForQuery(text)
        } else {
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.typeURL, object: TelemetryEventObject.searchBar)
        }
        if let overlayURL = url {
            submit(url: overlayURL)
            urlBar.url = overlayURL
        }
        urlBar.dismiss()
    }
    
    func overlayView(_ overlayView: OverlayView, didTapArrowText text: String) {
        urlBar.fillUrlBar(text: text + " ")
        searchSuggestClient.getSuggestions(text) { [weak self] suggestions, error in
            if error == nil, let suggestions = suggestions {
                self?.overlayView.setSearchQuery(suggestions: suggestions, hideFindInPage: true, hideAddToComplete: true)
            }
        }
    }
}

extension BrowserViewController: SearchSuggestionsPromptViewDelegate {
    func searchSuggestionsPromptView(_ searchSuggestionsPromptView: SearchSuggestionsPromptView, didEnable: Bool) {
        UserDefaults.standard.set(true, forKey: SearchSuggestionsPromptView.respondedToSearchSuggestionsPrompt)
        Settings.set(didEnable, forToggle: SettingsToggle.enableSearchSuggestions)
        overlayView.updateSearchSuggestionsPrompt(hidden: true)
        if didEnable, let urlbar = self.urlBar, let value = self.urlBar?.userInputText {
            urlBar(urlbar, didEnterText: value)
        }
    }
}

extension BrowserViewController: WebControllerDelegate {

    func webControllerDidStartProvisionalNavigation(_ controller: WebController) {
        urlBar.dismiss()
        updateFindInPageVisibility(visible: false)
    }

    func webController(_ controller: WebController, didUpdateFindInPageResults currentResult: Int?, totalResults: Int?) {
        if let total = totalResults {
            findInPageBar?.totalResults = total
        }

        if let current = currentResult {
            findInPageBar?.currentResult = current
        }
    }

    func webControllerDidReload(_ controller: WebController) {
        SearchHistoryUtils.isReload = true
    }

    func webControllerDidStartNavigation(_ controller: WebController) {
        if !SearchHistoryUtils.isFromURLBar && !SearchHistoryUtils.isNavigating && !SearchHistoryUtils.isReload {
            SearchHistoryUtils.pushSearchToStack(with: (urlBar.url?.absoluteString)!)
        }
        SearchHistoryUtils.isReload = false
        SearchHistoryUtils.isNavigating = false
        SearchHistoryUtils.isFromURLBar = false
        urlBar.isLoading = true
        urlBar.canDelete = true
        browserToolbar.canDelete = true
        browserToolbar.color = .loading
        toggleURLBarBackground(isBright: false)
        updateURLBar()
    }

    func webControllerDidFinishNavigation(_ controller: WebController) {
        updateURLBar()
        urlBar.isLoading = false
        toggleToolbarBackground()
        toggleURLBarBackground(isBright: !urlBar.isEditing)
        urlBar.progressBar.hideProgressBar()
    }

    func webControllerURLDidChange(_ controller: WebController, url: URL) {
        showToolbars()
    }

    func webController(_ controller: WebController, didFailNavigationWithError error: Error) {
        urlBar.url = webViewController.url
        urlBar.isLoading = false
        toggleURLBarBackground(isBright: true)
        toggleToolbarBackground()
        urlBar.progressBar.hideProgressBar()
    }

    func webController(_ controller: WebController, didUpdateCanGoBack canGoBack: Bool) {
        urlBar.canGoBack = canGoBack
        browserToolbar.canGoBack = canGoBack
    }

    func webController(_ controller: WebController, didUpdateCanGoForward canGoForward: Bool) {
        urlBar.canGoForward = canGoForward
        browserToolbar.canGoForward = canGoForward
    }

    func webController(_ controller: WebController, didUpdateEstimatedProgress estimatedProgress: Double) {
        // Don't update progress if the home view is visible. This prevents the centered URL bar
        // from catching the global progress events.
        guard urlBar.inBrowsingMode else { return }

        urlBar.progressBar.alpha = 1
        urlBar.progressBar.isHidden = false
        urlBar.progressBar.setProgress(Float(estimatedProgress), animated: true)
    }

    func webController(_ controller: WebController, scrollViewWillBeginDragging scrollView: UIScrollView) {
        lastScrollOffset = scrollView.contentOffset
        lastScrollTranslation = scrollView.panGestureRecognizer.translation(in: scrollView)
    }

    func webController(_ controller: WebController, scrollViewDidEndDragging scrollView: UIScrollView) {
        snapToolbars(scrollView: scrollView)
    }

    func webController(_ controller: WebController, scrollViewDidScroll scrollView: UIScrollView) {
        let translation = scrollView.panGestureRecognizer.translation(in: scrollView)
        let isDragging = scrollView.panGestureRecognizer.state != .possible

        // This will be 0 if we're moving but not dragging (i.e., gliding after dragging).
        let dragDelta = translation.y - lastScrollTranslation.y

        // This will match dragDelta unless the URL bar is transitioning.
        let offsetDelta = scrollView.contentOffset.y - lastScrollOffset.y

        lastScrollOffset = scrollView.contentOffset
        lastScrollTranslation = translation

        guard scrollBarState != .animating, !scrollView.isZooming else { return }

        guard scrollView.contentOffset.y + scrollView.frame.height < scrollView.contentSize.height && (scrollView.contentOffset.y > 0 || scrollBarOffsetAlpha > 0) else {
            // We're overscrolling, so don't do anything.
            return
        }

        if !isDragging && offsetDelta < 0 {
            // We're gliding up after dragging, so fully show the toolbars.
            showToolbars()
            return
        }

        let pageExtendsBeyondScrollView = scrollView.frame.height + (UIConstants.layout.browserToolbarHeight + view.safeAreaInsets.bottom) + UIConstants.layout.urlBarHeight < scrollView.contentSize.height
        let toolbarsHiddenAtTopOfPage = scrollView.contentOffset.y <= 0 && scrollBarOffsetAlpha > 0

        guard isDragging, (dragDelta < 0 && pageExtendsBeyondScrollView) || toolbarsHiddenAtTopOfPage || scrollBarState == .transitioning else { return }

        let lastOffsetAlpha = scrollBarOffsetAlpha
        scrollBarOffsetAlpha = (0 ... 1).clamp(scrollBarOffsetAlpha - dragDelta / UIConstants.layout.urlBarHeight)
        switch scrollBarOffsetAlpha {
        case 0:
            scrollBarState = .expanded
        case 1:
            scrollBarState = .collapsed
        default:
            scrollBarState = .transitioning
        }

        self.urlBar.collapseUrlBar(expandAlpha: max(0, (1 - scrollBarOffsetAlpha * 2)), collapseAlpha: max(0, -(1 - scrollBarOffsetAlpha * 2)))
        self.urlBarTopConstraint.update(offset: -scrollBarOffsetAlpha * (UIConstants.layout.urlBarHeight - UIConstants.layout.collapsedUrlBarHeight))
        self.toolbarBottomConstraint.update(offset: scrollBarOffsetAlpha * (UIConstants.layout.browserToolbarHeight + view.safeAreaInsets.bottom))
        updateViewConstraints()
        scrollView.bounds.origin.y += (lastOffsetAlpha - scrollBarOffsetAlpha) * UIConstants.layout.urlBarHeight

        lastScrollOffset = scrollView.contentOffset
    }

    func webControllerShouldScrollToTop(_ controller: WebController) -> Bool {
        guard scrollBarOffsetAlpha == 0 else {
            showToolbars()
            return false
        }

        return true
    }

    func webControllerDidNavigateBack(_ controller: WebController) {
        handleNavigationBack()
    }

    func webControllerDidNavigateForward(_ controller: WebController) {
        handleNavigationForward()
    }

    func webController(_ controller: WebController, stateDidChange state: BrowserState) {}

    func webController(_ controller: WebController, didUpdateTrackingProtectionStatus trackingStatus: TrackingProtectionStatus) {
        // Calculate the number of trackers blocked and add that to lifetime total
        if case .on(let info) = trackingStatus,
           case .on(let oldInfo) = trackingProtectionStatus {
            let differenceSinceLastUpdate = max(0, info.total - oldInfo.total)
            let numberOfTrackersBlocked = getNumberOfLifetimeTrackersBlocked()
            setNumberOfLifetimeTrackersBlocked(numberOfTrackers: numberOfTrackersBlocked + differenceSinceLastUpdate)
        }
        trackingProtectionStatus = trackingStatus
    }

    private func showToolbars() {
        let scrollView = webViewController.scrollView

        scrollBarState = .animating

        UIView.animate(withDuration: UIConstants.layout.urlBarTransitionAnimationDuration, delay: 0, options: .allowUserInteraction, animations: {
            self.urlBar.collapseUrlBar(expandAlpha: 1, collapseAlpha: 0)
            self.urlBarTopConstraint.update(offset: 0)
            self.toolbarBottomConstraint.update(inset: 0)
            scrollView.bounds.origin.y += self.scrollBarOffsetAlpha * UIConstants.layout.urlBarHeight
            self.scrollBarOffsetAlpha = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.scrollBarState = .expanded
        })
    }

    private func hideToolbars() {
        let scrollView = webViewController.scrollView

        scrollBarState = .animating
        UIView.animate(withDuration: UIConstants.layout.urlBarTransitionAnimationDuration, delay: 0, options: .allowUserInteraction, animations: {
            self.urlBar.collapseUrlBar(expandAlpha: 0, collapseAlpha: 1)
            self.urlBarTopConstraint.update(offset: -UIConstants.layout.urlBarHeight + UIConstants.layout.collapsedUrlBarHeight)
            self.toolbarBottomConstraint.update(offset: UIConstants.layout.browserToolbarHeight + self.view.safeAreaInsets.bottom)
            scrollView.bounds.origin.y += (self.scrollBarOffsetAlpha - 1) * UIConstants.layout.urlBarHeight
            self.scrollBarOffsetAlpha = 1
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.scrollBarState = .collapsed
        })
    }

    private func snapToolbars(scrollView: UIScrollView) {
        guard scrollBarState == .transitioning else { return }

        if scrollBarOffsetAlpha < 0.05 || scrollView.contentOffset.y < UIConstants.layout.urlBarHeight {
            showToolbars()
        } else {
            hideToolbars()
        }
    }
}

extension BrowserViewController: KeyboardHelperDelegate {

    func keyboardHelper(_ keyboardHelper: KeyboardHelper, keyboardWillShowWithState state: KeyboardState) {
        keyboardState = state
        self.updateViewConstraints()
        UIView.animate(withDuration: state.animationDuration) {
            self.homeViewBottomConstraint.update(offset: -state.intersectionHeightForView(view: self.view))
            self.view.layoutIfNeeded()
        }
    }

    func keyboardHelper(_ keyboardHelper: KeyboardHelper, keyboardWillHideWithState state: KeyboardState) {
        keyboardState = state
        self.updateViewConstraints()
        UIView.animate(withDuration: state.animationDuration) {
            self.homeViewBottomConstraint.update(offset: 0)
            self.view.layoutIfNeeded()
        }
    }

    func keyboardHelper(_ keyboardHelper: KeyboardHelper, keyboardDidHideWithState state: KeyboardState) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            urlBar.dismiss()
        }
    }
    func keyboardHelper(_ keyboardHelper: KeyboardHelper, keyboardDidShowWithState state: KeyboardState) { }
}

extension BrowserViewController: UIPopoverPresentationControllerDelegate {
    func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
        darkView.isHidden = true
    }
    
    func popoverPresentationController(_ popoverPresentationController: UIPopoverPresentationController, willRepositionPopoverTo rect: UnsafeMutablePointer<CGRect>, in view: AutoreleasingUnsafeMutablePointer<UIView>) {
        guard urlBar.inBrowsingMode else { return }
        guard popoverPresentationController.presentedViewController is PhotonActionSheet  else { return }
        view.pointee = self.showsToolsetInURLBar ? urlBar.contextMenuButton : browserToolbar.contextMenuButton
    }
}

@available(iOS 12.0, *)
extension BrowserViewController {
    public var eraseIntent: EraseIntent {
        let intent = EraseIntent()
        intent.suggestedInvocationPhrase = "Erase"
        return intent
    }
}

protocol WhatsNewDelegate {
    func shouldShowWhatsNew() -> Bool
    func didShowWhatsNew()
}
