//
//  SharedBuffersRenderModule.swift
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
import ARKit
import AugmentKitShader
import MetalKit

// Module for creating and updating the shared data used across all render elements
class SharedBuffersRenderModule: SharedRenderModule {
    
    static var identifier = "SharedBuffersRenderModule"
    
    //
    // Setup
    //
    
    var moduleIdentifier: String {
        return SharedBuffersRenderModule.identifier
    }
    var renderLayer: Int {
        return 1
    }
    var isInitialized: Bool = false
    var sharedModuleIdentifiers: [String]? = nil
    var renderDistance: Double = 500
    var errors = [AKError]()
    
    // MARK: - RenderModule
    
    func initializeBuffers(withDevice device: MTLDevice, maxInFlightBuffers: Int) {
        
        // Calculate our uniform buffer sizes. We allocate Constants.maxBuffersInFlight instances for uniform
        // storage in a single buffer. This allows us to update uniforms in a ring (i.e. triple
        // buffer the uniforms) so that the GPU reads from one slot in the ring wil the CPU writes
        // to another. Anchor uniforms should be specified with a max instance count for instancing.
        // Also uniform storage must be aligned (to 256 bytes) to meet the requirements to be an
        // argument in the constant address space of our shading functions.
        let sharedUniformBufferSize = Constants.alignedSharedUniformsSize * maxInFlightBuffers
        
        // Create and allocate our uniform buffer objects. Indicate shared storage so that both the
        // CPU can access the buffer
        sharedUniformBuffer = device.makeBuffer(length: sharedUniformBufferSize, options: .storageModeShared)
        sharedUniformBuffer?.label = "SharedUniformBuffer"
        
    }
    
    func loadAssets(forGeometricEntities: [AKGeometricEntity], fromModelProvider: ModelProvider?, textureLoader: MTKTextureLoader, completion: (() -> Void)) {
        completion()
    }
    
    func loadPipeline(withMetalLibrary: MTLLibrary, renderDestination: RenderDestinationProvider) {
        isInitialized = true
    }
    
    //
    // Per Frame Updates
    //
    
    func updateBufferState(withBufferIndex bufferIndex: Int) {
        sharedUniformBufferOffset = Constants.alignedSharedUniformsSize * bufferIndex
        sharedUniformBufferAddress = sharedUniformBuffer?.contents().advanced(by: sharedUniformBufferOffset)
    }
    
    func updateBuffers(withARFrame frame: ARFrame, cameraProperties: CameraProperties) {
        
        let uniforms = sharedUniformBufferAddress?.assumingMemoryBound(to: SharedUniforms.self)
        
        uniforms?.pointee.viewMatrix = frame.camera.viewMatrix(for: cameraProperties.orientation)
        uniforms?.pointee.projectionMatrix = frame.camera.projectionMatrix(for: cameraProperties.orientation, viewportSize: cameraProperties.viewportSize, zNear: 0.001, zFar: CGFloat(renderDistance))
        
        // Set up lighting for the scene using the ambient intensity if provided
        let ambientIntensity: Float = {
            if let lightEstimate = frame.lightEstimate {
                return Float(lightEstimate.ambientIntensity) / 1000.0
            } else {
                return 1
            }
        }()
        
        let ambientLightColor: vector_float3 = {
            if let lightEstimate = frame.lightEstimate {
                return getRGB(from: lightEstimate.ambientColorTemperature)
            } else {
                return vector3(0.5, 0.5, 0.5)
            }
        }()
        
        uniforms?.pointee.ambientLightColor = ambientLightColor// * ambientIntensity
        
        var directionalLightDirection : vector_float3 = vector3(0.0, -1.0, 0.0)
        directionalLightDirection = simd_normalize(directionalLightDirection)
        uniforms?.pointee.directionalLightDirection = directionalLightDirection
        
        let directionalLightColor: vector_float3 = vector3(0.6, 0.6, 0.6)
        uniforms?.pointee.directionalLightColor = directionalLightColor * ambientIntensity
        
    }
    
    func updateBuffers(withTrackers: [AKAugmentedTracker], targets: [AKTarget], cameraProperties: CameraProperties) {
        // Do Nothing
    }
    
    func updateBuffers(withPaths: [AKPath], cameraProperties: CameraProperties) {
        // Do Nothing
    }
    
    func draw(withRenderEncoder renderEncoder: MTLRenderCommandEncoder, sharedModules: [SharedRenderModule]?) {
        // Since this is a shared module, it is up to the module that depends on it to setup
        // the vertex and fragment shaders and issue the draw calls
    }
    
    func frameEncodingComplete() {
        //
    }
    
    //
    // Util
    //
    
    func recordNewError(_ akError: AKError) {
        errors.append(akError)
    }
    
    // MARK: - SharedRenderModule
    
    var sharedUniformBuffer: MTLBuffer?
    
    // Offset within _sharedUniformBuffer to set for the current frame
    var sharedUniformBufferOffset: Int = 0
    
    // Addresses to write shared uniforms to each frame
    var sharedUniformBufferAddress: UnsafeMutableRawPointer?
    
    // MARK: - Private
    
    private enum Constants {
        
        // The 16 byte aligned size of our uniform structures
        static let alignedSharedUniformsSize = (MemoryLayout<SharedUniforms>.stride & ~0xFF) + 0x100
       
    }
    
    private func getRGB(from colorTemperature: CGFloat) -> vector_float3 {
    
        let temp = Float(colorTemperature) / 100
        
        var red: Float = 127
        var green: Float = 127
        var blue: Float = 127
        
        if temp <= 66 {
            red = 255
            green = temp
            green = 99.4708025861 * log(green) - 161.1195681661
            if temp <= 19 {
                blue = 0
            } else {
                blue = temp - 10
                blue = 138.5177312231 * log(blue) - 305.0447927307
            }
        } else {
            red = temp - 60
            red = 329.698727446 * pow(red, -0.1332047592)
            green = temp - 60
            green = 288.1221695283 * pow(green, -0.0755148492 )
            blue = 255
        }
        
        let clamped = clamp(float3(red, green, blue), min: 0, max: 255)
        return vector3(clamped.x, clamped.y, clamped.z)
    
    }
    
}
