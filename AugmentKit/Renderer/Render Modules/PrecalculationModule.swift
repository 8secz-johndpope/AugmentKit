//
//  PrecalculationModule.swift
//  AugmentKit
//
//  MIT License
//
//  Copyright (c) 2019 JamieScanlon
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
//

import AugmentKitShader
import Foundation
import MetalKit

class PrecalculationModule: PreRenderComputeModule {
    
    var moduleIdentifier: String {
        return "PrecalculationModule"
    }
    var isInitialized: Bool = false
    var renderLayer: Int {
        return -3
    }
    
    var errors = [AKError]()
    var renderDistance: Double = 500
    var sharedModuleIdentifiers: [String]? = [SharedBuffersRenderModule.identifier]
    
    fileprivate(set) var argumentOutputBuffer: MTLBuffer?
    fileprivate(set) var argumentOutputBufferSize: Int = 0
    
    func initializeBuffers(withDevice device: MTLDevice, maxInFlightFrames: Int, maxInstances: Int) {
        
        instanceCount = maxInstances
        
        alignedGeometryInstanceUniformsSize = ((MemoryLayout<AnchorInstanceUniforms>.stride * instanceCount) & ~0xFF) + 0x100
        alignedEffectsUniformSize = ((MemoryLayout<AnchorEffectsUniforms>.stride * instanceCount) & ~0xFF) + 0x100
        alignedEnvironmentUniformSize = ((MemoryLayout<EnvironmentUniforms>.stride * instanceCount) & ~0xFF) + 0x100
        
        // Output buffer
        argumentOutputBufferSize = MemoryLayout<PrecalculatedParameters>.stride * instanceCount
        argumentOutputBuffer = device.makeBuffer(length: argumentOutputBufferSize * maxInFlightFrames, options: .storageModePrivate)
        
        // Calculate our uniform buffer sizes. We allocate `maxInFlightFrames` instances for uniform
        // storage in a single buffer. This allows us to update uniforms in a ring (i.e. triple
        // buffer the uniforms) so that the GPU reads from one slot in the ring wil the CPU writes
        // to another. Geometry uniforms should be specified with a max instance count for instancing.
        // Also uniform storage must be aligned (to 256 bytes) to meet the requirements to be an
        // argument in the constant address space of our shading functions.
        let geometryUniformBufferSize = alignedGeometryInstanceUniformsSize * maxInFlightFrames
        let paletteBufferSize = Constants.alignedPaletteSize * Constants.maxPaletteCount * maxInFlightFrames
        let effectsUniformBufferSize = alignedEffectsUniformSize * maxInFlightFrames
        let environmentUniformBufferSize = alignedEnvironmentUniformSize * maxInFlightFrames
        
        // Create and allocate our uniform buffer objects. Indicate shared storage so that both the
        // CPU can access the buffer
        geometryUniformBuffer = device.makeBuffer(length: geometryUniformBufferSize, options: .storageModeShared)
        geometryUniformBuffer?.label = "GeometryUniformBuffer"
        
        paletteBuffer = device.makeBuffer(length: paletteBufferSize, options: [])
        paletteBuffer?.label = "PaletteBuffer"
        
        effectsUniformBuffer = device.makeBuffer(length: effectsUniformBufferSize, options: .storageModeShared)
        effectsUniformBuffer?.label = "EffectsUniformBuffer"
        
        environmentUniformBuffer = device.makeBuffer(length: environmentUniformBufferSize, options: .storageModeShared)
        environmentUniformBuffer?.label = "EnvironemtUniformBuffer"
        
    }
    
    func loadPipeline(withMetalLibrary metalLibrary: MTLLibrary, renderDestination: RenderDestinationProvider, textureBundle: Bundle, forComputePass computePass: ComputePass?) -> ThreadGroup? {
        
        guard let precalculationFunction = metalLibrary.makeFunction(name: "precalculationComputeShader") else {
            print("Serious Error - failed to create the precalculationComputeShader function")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeShaderInitializationFailed, userInfo: nil)
            let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            return nil
        }
        
        // If all of the instances are layed out in a square, how big is that square.
        let gridSize = Int(Double(instanceCount).squareRoot())
        
        guard let threadGroup = computePass?.threadGroup(withComputeFunction: precalculationFunction, size: (width: gridSize, height: gridSize, depth: 1)) else {
            return nil
        }
      
        isInitialized = true
        return threadGroup
    }
    
    func updateBufferState(withBufferIndex bufferIndex: Int) {
        
        geometryUniformBufferOffset = alignedGeometryInstanceUniformsSize * bufferIndex
        paletteBufferOffset = Constants.alignedPaletteSize * Constants.maxPaletteCount * bufferIndex
        effectsUniformBufferOffset = alignedEffectsUniformSize * bufferIndex
        environmentUniformBufferOffset = alignedEnvironmentUniformSize * bufferIndex
        outputBufferOffset = argumentOutputBufferSize * bufferIndex
        
        geometryUniformBufferAddress = geometryUniformBuffer?.contents().advanced(by: geometryUniformBufferOffset)
        paletteBufferAddress = paletteBuffer?.contents().advanced(by: paletteBufferOffset)
        effectsUniformBufferAddress = effectsUniformBuffer?.contents().advanced(by: effectsUniformBufferOffset)
        environmentUniformBufferAddress = environmentUniformBuffer?.contents().advanced(by: environmentUniformBufferOffset)
        
    }
    
    func prepareToDraw(withAllEntities allEntities: [AKEntity], cameraProperties: CameraProperties, environmentProperties: EnvironmentProperties, shadowProperties: ShadowProperties, computePass: ComputePass, renderPass: RenderPass?) {
        
        var drawCallGroupOffset = 0
        var drawCallGroupIndex = 0
        
        let geometryUniforms = geometryUniformBufferAddress?.assumingMemoryBound(to: AnchorInstanceUniforms.self)
        let environmentUniforms = environmentUniformBufferAddress?.assumingMemoryBound(to: EnvironmentUniforms.self)
        let effectsUniforms = effectsUniformBufferAddress?.assumingMemoryBound(to: AnchorEffectsUniforms.self)
        
        // Get all of the AKGeometricEntity's
        var allGeometricEntities: [AKGeometricEntity] = allEntities.compactMap({
            if let geoEntity = $0 as? AKGeometricEntity {
                return geoEntity
            } else {
                return nil
            }
        })
        let allGeometricEntityGroups: [AKGeometricEntityGroup] = allEntities.compactMap({
            if let geoEntity = $0 as? AKGeometricEntityGroup {
                return geoEntity
            } else {
                return nil
            }
        })
        let groupGeometries = allGeometricEntityGroups.flatMap({$0.geometries})
        allGeometricEntities.append(contentsOf: groupGeometries)
        
        renderPass?.drawCallGroups.forEach { drawCallGroup in
            
            let uuid = drawCallGroup.uuid
            let geometricEntity = allGeometricEntities.first(where: {$0.identifier == uuid})
            var drawCallIndex = 0
            
            for drawCall in drawCallGroup.drawCalls {
                
                //
                // Environment Uniform Setup
                //
                
                if let environmentUniform = environmentUniforms?.advanced(by: drawCallGroupOffset + drawCallIndex), computePass.usesEnvironment {
                    
                    // see if this geometry is associated with an environment anchor. An environment anchor applies to a regino of space which may contain serveral anchors.
                    let environmentProperty = environmentProperties.environmentAnchorsWithReatedAnchors.first(where: {
                        $0.value.contains(uuid)
                    })
                    // Get the environment texture if available
                    let environmentTexture: MTLTexture? = {
                        if let environmentProbeAnchor = environmentProperty?.key, let aTexture = environmentProbeAnchor.environmentTexture {
                            return aTexture
                        } else {
                            return nil
                        }
                    }()
                    let environmentData: EnvironmentData = {
                        var myEnvironmentData = EnvironmentData()
                        if let texture = environmentTexture {
                            myEnvironmentData.environmentTexture = texture
                            myEnvironmentData.hasEnvironmentMap = true
                            return myEnvironmentData
                        } else {
                            myEnvironmentData.hasEnvironmentMap = false
                        }
                        return myEnvironmentData
                    }()
                    // Set up lighting for the scene using the ambient intensity if provided
                    let ambientIntensity: Float = {
                        if let lightEstimate = environmentProperties.lightEstimate {
                            return Float(lightEstimate.ambientIntensity) / 1000.0
                        } else {
                            return 1
                        }
                    }()
                    let ambientLightColor: vector_float3 = {
                        if let lightEstimate = environmentProperties.lightEstimate {
                            // FIXME: Remove
                            return getRGB(from: lightEstimate.ambientColorTemperature)
                        } else {
                            return vector3(0.5, 0.5, 0.5)
                        }
                    }()
                    
                    environmentUniform.pointee.ambientLightColor = ambientLightColor// * ambientIntensity
                    
                    var directionalLightDirection : vector_float3 = environmentProperties.directionalLightDirection
                    directionalLightDirection = simd_normalize(directionalLightDirection)
                    environmentUniform.pointee.directionalLightDirection = directionalLightDirection
                    
                    let directionalLightColor: vector_float3 = vector3(0.6, 0.6, 0.6)
                    environmentUniform.pointee.directionalLightColor = directionalLightColor * ambientIntensity
                    
                    environmentUniform.pointee.directionalLightMVP = environmentProperties.directionalLightMVP
                    environmentUniform.pointee.shadowMVPTransformMatrix = shadowProperties.shadowMVPTransformMatrix
                    
                    if environmentData.hasEnvironmentMap == true {
                        environmentUniform.pointee.hasEnvironmentMap = 1
                    } else {
                        environmentUniform.pointee.hasEnvironmentMap = 0
                    }
                    
                }
                
                //
                // Effects Uniform Setup
                //
                
                if let effectsUniform = effectsUniforms?.advanced(by: drawCallGroupOffset + drawCallIndex), computePass.usesEnvironment {
                    
                    var hasSetAlpha = false
                    var hasSetGlow = false
                    var hasSetTint = false
                    var hasSetScale = false
                    if let effects = geometricEntity?.effects {
                        let currentTime: TimeInterval = Double(cameraProperties.currentFrame) / cameraProperties.frameRate
                        for effect in effects {
                            switch effect.effectType {
                            case .alpha:
                                if let value = effect.value(forTime: currentTime) as? Float {
                                    effectsUniform.pointee.alpha = value
                                    hasSetAlpha = true
                                }
                            case .glow:
                                if let value = effect.value(forTime: currentTime) as? Float {
                                    effectsUniform.pointee.glow = value
                                    hasSetGlow = true
                                }
                            case .tint:
                                if let value = effect.value(forTime: currentTime) as? float3 {
                                    effectsUniform.pointee.tint = value
                                    hasSetTint = true
                                }
                            case .scale:
                                if let value = effect.value(forTime: currentTime) as? Float {
                                    let scaleMatrix = matrix_identity_float4x4
                                    effectsUniform.pointee.scale = scaleMatrix.scale(x: value, y: value, z: value)
                                    hasSetScale = true
                                }
                            }
                        }
                    }
                    if !hasSetAlpha {
                        effectsUniform.pointee.alpha = 1
                    }
                    if !hasSetGlow {
                        effectsUniform.pointee.glow = 0
                    }
                    if !hasSetTint {
                        effectsUniform.pointee.tint = float3(1,1,1)
                    }
                    if !hasSetScale {
                        effectsUniform.pointee.scale = matrix_identity_float4x4
                    }
                    
                }
            
                //
                // Geometry Uniform Setup
                //
                
                if let geometryUniform = geometryUniforms?.advanced(by: drawCallGroupOffset + drawCallIndex), computePass.usesGeometry {
                    
                    guard let drawData = drawCall.drawData, drawCallIndex <= instanceCount else {
                        geometryUniform.pointee.hasGeometry = 0
                        drawCallIndex += 1
                        continue
                    }
                    
                    // FIXME: - Let the compute shader do most of this
                    
                    // Apply the world transform (as defined in the imported model) if applicable
                    let worldTransform: matrix_float4x4 = {
                        if drawData.worldTransformAnimations.count > 0 {
                            let index = Int(cameraProperties.currentFrame % UInt(drawData.worldTransformAnimations.count))
                            return drawData.worldTransformAnimations[index]
                        } else {
                            return drawData.worldTransform
                        }
                    }()
                    
                    var hasHeading = false
                    var headingType: HeadingType = .absolute
                    var headingTransform = matrix_identity_float4x4
                    var locationTransform = matrix_identity_float4x4
                    var modelMatrix = matrix_identity_float4x4
                    var normalMatrix = matrix_identity_float3x3
                    // Flip Z axis to convert geometry from right handed to left handed
                    var coordinateSpaceTransform = matrix_identity_float4x4
                    coordinateSpaceTransform.columns.2.z = -1.0
                    coordinateSpaceTransform = coordinateSpaceTransform * worldTransform
                    
                    if let akAnchor = geometricEntity as? AKAnchor {
                        
                        // TODO: Move this logic to shader
                        // Ignore anchors that are beyond the renderDistance
                        let distance = anchorDistance(withTransform: akAnchor.worldLocation.transform, cameraProperties: cameraProperties)
                        guard Double(distance) < renderDistance else {
                            geometryUniform.pointee.hasGeometry = 0
                            drawCallIndex += 1
                            continue
                        }
                        
                        // Update Heading
                        let myHeadingTransform = akAnchor.heading.offsetRotation.quaternion.toMatrix4()
                        
                        if akAnchor.heading.type == .absolute {
                            let newTransform = myHeadingTransform * float4x4(
                                float4(coordinateSpaceTransform.columns.0.x, 0, 0, 0),
                                float4(0, coordinateSpaceTransform.columns.1.y, 0, 0),
                                float4(0, 0, coordinateSpaceTransform.columns.2.z, 0),
                                float4(coordinateSpaceTransform.columns.3.x, coordinateSpaceTransform.columns.3.y, coordinateSpaceTransform.columns.3.z, 1)
                            )
                            coordinateSpaceTransform = newTransform
                        } else if akAnchor.heading.type == .relative {
                            coordinateSpaceTransform = coordinateSpaceTransform * myHeadingTransform
                        }
                        
                        let myModelMatrix = akAnchor.worldLocation.transform * coordinateSpaceTransform
                        hasHeading = true
                        headingType = akAnchor.heading.type
                        headingTransform = myHeadingTransform
                        locationTransform = akAnchor.worldLocation.transform
                        modelMatrix = myModelMatrix
                        normalMatrix = myModelMatrix.normalMatrix
                        
                    } else if let akTarget = geometricEntity as? AKTarget {
                        
                        // Apply the transform of the target relative to the reference transform
                        let targetAbsoluteTransform = akTarget.position.referenceTransform * akTarget.position.transform
                        
                        // TODO: Move this logic to shader
                        // Ignore anchors that are beyond the renderDistance
                        let distance = anchorDistance(withTransform: targetAbsoluteTransform, cameraProperties: cameraProperties)
                        guard Double(distance) < renderDistance else {
                            drawCallIndex += 1
                            geometryUniform.pointee.hasGeometry = 0
                            continue
                        }
                        
                        let myModelMatrix = targetAbsoluteTransform * coordinateSpaceTransform
                        
                        locationTransform = targetAbsoluteTransform
                        modelMatrix = myModelMatrix
                        normalMatrix = myModelMatrix.normalMatrix
                        
                    } else if let akTracker = geometricEntity as? AKTracker {
                        
                        // Apply the transform of the target relative to the reference transform
                        let trackerAbsoluteTransform = akTracker.position.referenceTransform * akTracker.position.transform
                        
                        // TODO: Move this logic to shader
                        // Ignore anchors that are beyond the renderDistance
                        let distance = anchorDistance(withTransform: trackerAbsoluteTransform, cameraProperties: cameraProperties)
                        guard Double(distance) < renderDistance else {
                            drawCallIndex += 1
                            geometryUniform.pointee.hasGeometry = 0
                            continue
                        }
                        
                        let myModelMatrix = trackerAbsoluteTransform * coordinateSpaceTransform
                        
                        locationTransform = trackerAbsoluteTransform
                        modelMatrix = myModelMatrix
                        normalMatrix = myModelMatrix.normalMatrix
                        
                    }
                    
                    geometryUniform.pointee.hasGeometry = 1
                    geometryUniform.pointee.hasHeading = hasHeading ? 1 : 0
                    geometryUniform.pointee.headingType = headingType == .absolute ? 0 : 1
                    geometryUniform.pointee.headingTransform = headingTransform
                    geometryUniform.pointee.worldTransform = worldTransform
                    geometryUniform.pointee.locationTransform = locationTransform
                    geometryUniform.pointee.modelMatrix = modelMatrix
                    geometryUniform.pointee.normalMatrix = normalMatrix
                }
                
                drawCallIndex += 1
                
            }
            
            drawCallGroupOffset += drawCallGroup.drawCalls.count
            drawCallGroupIndex += 1
            
        }
    }
    
    func dispatch(withComputePass computePass: ComputePass, sharedModules: [SharedRenderModule]?) {
        
        guard let computeEncoder = computePass.computeCommandEncoder else {
            return
        }
        
        guard let threadGroup = computePass.threadGroup else {
            return
        }
        
        computeEncoder.pushDebugGroup("Dispatch Precalculation")
        
        if let sharedBuffer = sharedModules?.first(where: {$0.moduleIdentifier == SharedBuffersRenderModule.identifier}), computePass.usesSharedBuffer {
            
            computeEncoder.pushDebugGroup("Shared Uniforms")
            computeEncoder.setBuffer(sharedBuffer.sharedUniformBuffer, offset: sharedBuffer.sharedUniformBufferOffset, index: Int(kBufferIndexSharedUniforms.rawValue))
            computeEncoder.popDebugGroup()
            
        }
        
        if let environmentUniformBuffer = environmentUniformBuffer, computePass.usesEnvironment {
            
            computeEncoder.pushDebugGroup("Environment Uniforms")
            computeEncoder.setBuffer(environmentUniformBuffer, offset: environmentUniformBufferOffset, index: Int(kBufferIndexEnvironmentUniforms.rawValue))
            computeEncoder.popDebugGroup()
            
        }
        
        if let effectsBuffer = effectsUniformBuffer, computePass.usesEffects {
            
            computeEncoder.pushDebugGroup("Effects Uniforms")
            computeEncoder.setBuffer(effectsBuffer, offset: effectsUniformBufferOffset, index: Int(kBufferIndexAnchorEffectsUniforms.rawValue))
            computeEncoder.popDebugGroup()
            
        }
        
        if computePass.usesGeometry {
            computeEncoder.pushDebugGroup("Geometry Uniforms")
            computeEncoder.setBuffer(geometryUniformBuffer, offset: geometryUniformBufferOffset, index: Int(kBufferIndexAnchorInstanceUniforms.rawValue))
            computeEncoder.popDebugGroup()
        
            computeEncoder.pushDebugGroup("Palette Uniforms")
            computeEncoder.setBuffer(paletteBuffer, offset: paletteBufferOffset, index: Int(kBufferIndexMeshPalettes.rawValue))
            computeEncoder.popDebugGroup()
        }
        
        // Output Buffer
        computeEncoder.pushDebugGroup("Output Buffer")
        computeEncoder.setBuffer(argumentOutputBuffer, offset: outputBufferOffset, index: Int(kBufferIndexPrecalculationOutputBuffer.rawValue))
        computeEncoder.popDebugGroup()
        
        threadGroup.prepareThreadGroup(withComputePass: computePass)
        
        // Requires the device supports non-uniform threadgroup sizes
        computeEncoder.dispatchThreads(MTLSize(width: threadGroup.size.width, height: threadGroup.size.height, depth: threadGroup.size.depth), threadsPerThreadgroup: MTLSize(width: threadGroup.threadsPerGroup.width, height: threadGroup.threadsPerGroup.height, depth: 1))
        
        computeEncoder.popDebugGroup()
        
    }
    
    func frameEncodingComplete() {
        //
    }
    
    func recordNewError(_ akError: AKError) {
        errors.append(akError)
    }
    
    // MARK: - Private
    
    fileprivate enum Constants {
        static let maxPaletteCount = 100
        static let alignedPaletteSize = ((MemoryLayout<matrix_float4x4>.stride * maxPaletteCount) & ~0xFF) + 0x100
    }
    
    fileprivate var instanceCount: Int = 0
    
    fileprivate var alignedGeometryInstanceUniformsSize: Int = 0
    fileprivate var alignedEffectsUniformSize: Int = 0
    fileprivate var alignedEnvironmentUniformSize: Int = 0
    
    fileprivate var geometryUniformBuffer: MTLBuffer?
    fileprivate var paletteBuffer: MTLBuffer?
    fileprivate var effectsUniformBuffer: MTLBuffer?
    fileprivate var environmentUniformBuffer: MTLBuffer?
    
    
    
    // Offset within geometryUniformBuffer to set for the current frame
    fileprivate var geometryUniformBufferOffset: Int = 0
    // Offset within paletteBuffer to set for the current frame
    fileprivate var paletteBufferOffset = 0
    // Offset within effectsUniformBuffer to set for the current frame
    fileprivate var effectsUniformBufferOffset: Int = 0
    // Offset within environmentUniformBuffer to set for the current frame
    fileprivate var environmentUniformBufferOffset: Int = 0
    // Offset within argumentOutputBuffer to set for the current frame
    fileprivate var outputBufferOffset = 0
    // Addresses to write geometry uniforms to each frame
    fileprivate var geometryUniformBufferAddress: UnsafeMutableRawPointer?
    // Addresses to write palette to each frame
    fileprivate var paletteBufferAddress: UnsafeMutableRawPointer?
    // Addresses to write effects uniforms to each frame
    fileprivate var effectsUniformBufferAddress: UnsafeMutableRawPointer?
    // Addresses to write environment uniforms to each frame
    fileprivate var environmentUniformBufferAddress: UnsafeMutableRawPointer?
    
    // FIXME: Remove - put in compute shader
    fileprivate func anchorDistance(withTransform transform: matrix_float4x4, cameraProperties: CameraProperties?) -> Float {
        guard let cameraProperties = cameraProperties else {
            return 0
        }
        let point = float3(transform.columns.3.x, transform.columns.3.x, transform.columns.3.z)
        return length(point - cameraProperties.position)
    }
    
}
