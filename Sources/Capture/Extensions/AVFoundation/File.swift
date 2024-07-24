//
//  File.swift
//  
//
//  Created by Olivier LAPRAYE on 24/07/2024.
//

import Foundation
import UIKit

extension UIDeviceOrientation {
    var rotationAngleValue: Double {
        switch self {
        case .unknown, .faceUp, .faceDown, .portrait: 90
        case .portraitUpsideDown: 270
        case .landscapeLeft: 0
        case .landscapeRight: 180
        @unknown default: 90
        }

    }
}
