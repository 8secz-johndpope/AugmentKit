//
//  AKRelativePosiiton.swift
//  AugmentKit
//
//  MIT License
//
//  Copyright (c) 2018 JamieScanlon
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import simd

// MARK: - AKRelativePosition
/**
 A data structure that represents a position relative to another reference position in world space.
 */
open class AKRelativePosition {
    
    /**
     Another `AKRelativePosition` which this object is relative to.
     */
    public var parentPosition: AKRelativePosition?
    /**
     A heading associated with this position.
     */
    public var heading: AKHeading? {
        didSet {
            _headingHasChanged = true
        }
    }
    /**
     The transform that represents the `parentPosition`'s transform. The absolute transform that this object represents can be calulated by multiplying this 'referenceTransform' with the `transform` property. If `parentPosition` is not provided, this will be equal to `matrix_identity_float4x4`
     */
    public private(set) var referenceTransform: matrix_float4x4 = matrix_identity_float4x4
    /**
     The transform that this object represents. If using heading, the matrix provided should NOT contain any rotation component.
     */
    public var transform: matrix_float4x4 = matrix_identity_float4x4 {
        didSet {
            _transformHasChanged = true
        }
    }
    /**
     When `true`, `referenceTransform` and `transform` don't represent the current state. In this case updateTransforms() should to be called before using `referenceTransform` and `transform` for any position calculations.
     */
    public var transformHasChanged: Bool {
        return _transformHasChanged || (parentPosition?.transformHasChanged == true)
    }
    
    /**
     Initalize a new `AKRelativePosition` with a transform and a parent `AKRelativePosition`
     - Parameters:
        - withTransform: A `matrix_float4x4` representing a relative position
        - relativeTo: A parent `AKRelativePosition`. If provided, this object's transform is relative to the provided parent.
     */
    public init(withTransform transform: matrix_float4x4, relativeTo parentPosition: AKRelativePosition? = nil) {
        self.transform = transform
        self.parentPosition = parentPosition
        updateTransforms()
    }
    
    /**
     Updates the `transform` and `referenceTransform` properties to represent the current state.
     */
    public func updateTransforms() {
        if let parentPosition = parentPosition, parentPosition.transformHasChanged == true {
            parentPosition.updateTransforms()
            referenceTransform = parentPosition.referenceTransform * parentPosition.transform
        }
        
        if let heading = heading {
            
            var mutableHeading = heading
            let oldHeading = mutableHeading.offsetRotation
            mutableHeading.updateHeading(withPosition: self)
            if oldHeading != mutableHeading.offsetRotation {
                self.heading = mutableHeading
            }
            
            if (_transformHasChanged || _headingHasChanged) {
            
                // Heading
                var newTransform = mutableHeading.offsetRotation.quaternion.toMatrix4()
                
                if mutableHeading.type == .absolute {
                    newTransform = newTransform * float4x4(
                        SIMD4<Float>(transform.columns.0.x, 0, 0, 0),
                        SIMD4<Float>(0, transform.columns.1.y, 0, 0),
                        SIMD4<Float>(0, 0, transform.columns.2.z, 0),
                        SIMD4<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, 1)
                    )
                    transform = newTransform
                } else if mutableHeading.type == .relative {
                    transform = transform * newTransform
                }
            }
            
        }
        _transformHasChanged = false
        _headingHasChanged = false
    }
    
    // MARK: Private
    
    private var _transformHasChanged = false
    private var _headingHasChanged = false
    
}
