/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import SnapKit

class SheetModalViewController: UIViewController {
    
    private lazy var containerView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.layer.cornerRadius = metrics.cornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = Float(metrics.shadowOpacity)
        view.layer.shadowRadius = metrics.shadowRadius
        view.layer.shadowOffset = CGSize(width: 0, height: -1)
        view.clipsToBounds = true
        return view
    }()
    
    private lazy var dimmedView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.alpha = maximumDimmingAlpha
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(animateDismissView))
        view.addGestureRecognizer(tapGesture)
        return view
    }()
    
    private lazy var closeButton: UIButton = {
        var button = UIButton()
        button.setImage(UIImage(named: "close-button")!, for: .normal)
        button.addTarget(self, action: #selector(animateDismissView), for: .touchUpInside)
        button.accessibilityIdentifier = "closeSheetButton"
        return button
    }()
    
    private let containerViewController: UIViewController
    private let metrics: SheetMetrics
    private let minimumDimmingAlpha: CGFloat = 0.1
    private let maximumDimmingAlpha: CGFloat = 0.5
    
    private var containerViewHeightConstraint: Constraint!
    private var containerViewBottomConstraint: Constraint!
    
    init(containerViewController: UIViewController, metrics: SheetMetrics = .default) {
        self.containerViewController = containerViewController
        self.metrics = metrics
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        let height = min(container.preferredContentSize.height, metrics.maximumContainerHeight)
        animateContainerHeight(height)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setupConstraints()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateShowDimmedView()
        animatePresentContainer()
    }
    
    func setupConstraints() {
        view.addSubview(dimmedView)
        view.addSubview(containerView)
        dimmedView.translatesAutoresizingMaskIntoConstraints = false
        containerView.translatesAutoresizingMaskIntoConstraints = false
        
        install(containerViewController, on: containerView)
        
        dimmedView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        containerView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            containerViewHeightConstraint = make.height.equalTo(metrics.bufferHeight).constraint
            containerViewBottomConstraint = make.bottom.equalTo(view).offset(metrics.bufferHeight).constraint
        }
        
        containerView.addSubview(closeButton)
        closeButton.snp.makeConstraints { make in
            make.trailing.top.equalToSuperview().inset(16)
            make.height.width.equalTo(30)
        }
    }
    
    // MARK: Present and dismiss animation
    
    func animatePresentContainer() {
        let springTiming = UISpringTimingParameters(dampingRatio: 0.75, initialVelocity: CGVector(dx: 0, dy: 4))
        let animator = UIViewPropertyAnimator(duration: 0.4, timingParameters: springTiming)
        
        animator.addAnimations {
            self.containerViewBottomConstraint.update(offset: 0)
            self.view.layoutIfNeeded()
        }
        animator.startAnimation()
    }
    
    func animateContainerHeight(_ height: CGFloat) {
        let animator = UIViewPropertyAnimator(duration: 0.4, curve: .easeInOut) {
            self.containerViewHeightConstraint?.update(offset: height)
            self.view.layoutIfNeeded()
        }
        animator.startAnimation()
    }
    
    func animateShowDimmedView() {
        dimmedView.alpha = 0
        UIView.animate(withDuration: 0.4) {
            self.dimmedView.alpha = self.maximumDimmingAlpha
        }
    }
    
    @objc func animateDismissView() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dimmedView.alpha = maximumDimmingAlpha
        
        let springTiming = UISpringTimingParameters(dampingRatio: 0.75, initialVelocity: CGVector(dx: 0, dy: 4))
        let dimmAnimator = UIViewPropertyAnimator(duration: 0.4, timingParameters: springTiming)
        let dismissAnimator = UIViewPropertyAnimator(duration: 0.3, curve: .easeOut)
        
        dismissAnimator.addAnimations {
            self.containerViewBottomConstraint?.update(offset: 1000)
            self.view.layoutIfNeeded()
        }
        dimmAnimator.addAnimations {
            self.dimmedView.alpha = 0
        }
        dimmAnimator.addCompletion { _ in
            self.dismiss(animated: false)
        }
        dimmAnimator.startAnimation()
        dismissAnimator.startAnimation()
    }
}
