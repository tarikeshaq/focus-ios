/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit

private struct Color {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
}

extension UIColor {
    
    static let above = UIColor(named: "Above")!
    static let accent = UIColor(named: "Accent")!
    static let cfrFirst = UIColor(named: "CfrFirst")!
    static let cfrSecond = UIColor(named: "CfrSecond")!
    static let divider = UIColor(named: "Divider")!
    static let foundation = UIColor(named: "Foundation")!
    static let gradientFirst = UIColor(named: "GradientFirst")!
    static let gradientSecond = UIColor(named: "GradientSecond")!
    static let gradientThird = UIColor(named: "GradientThird")!
    static let locationBar = UIColor(named: "LocationBar")!
    static let primaryDark = UIColor(named: "PrimaryDark")!
    static let primaryText = UIColor(named: "PrimaryText")!
    static let scrim = UIColor(named: "Scrim")!
    static let searchGradientFirst = UIColor(named: "SearchGradientFirst")!
    static let searchGradientSecond = UIColor(named: "SearchGradientSecond")!
    static let searchGradientThird = UIColor(named: "SearchGradientThird")!
    static let searchGradientFourth = UIColor(named: "SearchGradientFourth")!
    static let searchSeparator = UIColor(named: "SearchSeparator")!
    static let secondaryDark = UIColor(named: "SecondaryDark")!
    static let secondaryText = UIColor(named: "SecondaryText")!
    static let secondaryButton = UIColor(named: "SecondaryButton")!
    static let warning = UIColor(named: "Warning")!
    
    /**
     * Initializes and returns a color object for the given RGB hex integer.
     */
    public convenience init(rgb: Int, alpha: Float = 1) {
        self.init(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8)  / 255.0,
            blue: CGFloat((rgb & 0x0000FF) >> 0)  / 255.0,
            alpha: CGFloat(alpha))
    }

    func lerp(toColor: UIColor, step: CGFloat) -> UIColor {
        var fromR: CGFloat = 0
        var fromG: CGFloat = 0
        var fromB: CGFloat = 0
        getRed(&fromR, green: &fromG, blue: &fromB, alpha: nil)

        var toR: CGFloat = 0
        var toG: CGFloat = 0
        var toB: CGFloat = 0
        toColor.getRed(&toR, green: &toG, blue: &toB, alpha: nil)

        let r = fromR + (toR - fromR) * step
        let g = fromG + (toG - fromG) * step
        let b = fromB + (toB - fromB) * step

        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}
