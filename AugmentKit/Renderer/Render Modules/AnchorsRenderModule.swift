//
//  AnchorsRenderModule.swift
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

class AnchorsRenderModule: RenderModule, SkinningModule {
    
    static var identifier = "AnchorsRenderModule"
    
    //
    // Setup
    //
    
    var moduleIdentifier: String {
        return AnchorsRenderModule.identifier
    }
    var renderLayer: Int {
        return 11
    }
    var isInitialized: Bool = false
    var sharedModuleIdentifiers: [String]? = [SharedBuffersRenderModule.identifier]
    var renderDistance: Double = 500
    var errors = [AKError]()
    
    // The number of anchor instances to render
    private(set) var anchorInstanceCount: Int = 0
    
    func initializeBuffers(withDevice aDevice: MTLDevice, maxInFlightFrames: Int, maxInstances: Int) {
        
        guard device == nil else {
            return
        }
        
        device = aDevice
        
        // Calculate our uniform buffer sizes. We allocate `maxInFlightFrames` instances for uniform
        // storage in a single buffer. This allows us to update uniforms in a ring (i.e. triple
        // buffer the uniforms) so that the GPU reads from one slot in the ring wil the CPU writes
        // to another. Anchor uniforms should be specified with a max instance count for instancing.
        // Also uniform storage must be aligned (to 256 bytes) to meet the requirements to be an
        // argument in the constant address space of our shading functions.
        let anchorUniformBufferSize = Constants.alignedAnchorInstanceUniformsSize * maxInFlightFrames
        let materialUniformBufferSize = RenderModuleConstants.alignedMaterialSize * maxInFlightFrames
        let paletteBufferSize = Constants.alignedPaletteSize * Constants.maxPaletteSize * maxInFlightFrames
        let effectsUniformBufferSize = Constants.alignedEffectsUniformSize * maxInFlightFrames
        let environmentUniformBufferSize = Constants.alignedEnvironmentUniformSize * maxInFlightFrames
        
        // Create and allocate our uniform buffer objects. Indicate shared storage so that both the
        // CPU can access the buffer
        anchorUniformBuffer = device?.makeBuffer(length: anchorUniformBufferSize, options: .storageModeShared)
        anchorUniformBuffer?.label = "AnchorUniformBuffer"
        
        materialUniformBuffer = device?.makeBuffer(length: materialUniformBufferSize, options: .storageModeShared)
        materialUniformBuffer?.label = "MaterialUniformBuffer"
        
        paletteBuffer = device?.makeBuffer(length: paletteBufferSize, options: [])
        paletteBuffer?.label = "PaletteBuffer"
        
        effectsUniformBuffer = device?.makeBuffer(length: effectsUniformBufferSize, options: .storageModeShared)
        effectsUniformBuffer?.label = "EffectsUniformBuffer"
        
        environmentUniformBuffer = device?.makeBuffer(length: environmentUniformBufferSize, options: .storageModeShared)
        environmentUniformBuffer?.label = "EnvironemtUniformBuffer"
        
        geometricEntities = []
        
    }
    
    func loadAssets(forGeometricEntities theGeometricEntities: [AKGeometricEntity], fromModelProvider modelProvider: ModelProvider?, textureLoader aTextureLoader: MTKTextureLoader, completion: (() -> Void)) {
        
        guard let modelProvider = modelProvider else {
            print("Serious Error - Model Provider not found.")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeModelProviderNotFound, userInfo: nil)
            let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            completion()
            return
        }
        
        textureLoader = aTextureLoader
        geometricEntities.append(contentsOf: theGeometricEntities)
        
        //
        // Create and load our models
        //
        
        var numModels = theGeometricEntities.count
        
        // Load the default model
        modelProvider.loadAsset(forObjectType: "AnyAnchor", identifier: nil) { [weak self] asset in
            
            guard let asset = asset else {
                print("Warning (AnchorsRenderModule) - Failed to get a MDLAsset for type  \"AnyAnchor\") from the modelProvider. Aborting the render phase.")
                let newError = AKError.warning(.modelError(.modelNotFound(ModelErrorInfo(type:  "AnyAnchor"))))
                recordNewError(newError)
                completion()
                return
            }
            
            self?.modelAssetsByUUID[generalUUID] = asset
            
            if numModels == 0 {
                completion()
            }
            
        }
        
        // Load the per-geometry models
        for geometricEntity in theGeometricEntities {
            
            if let identifier = geometricEntity.identifier {
                modelProvider.loadAsset(forObjectType:  "AnyAnchor", identifier: identifier) { [weak self] asset in
                    
                    guard let asset = asset else {
                        print("Warning (AnchorsRenderModule) - Failed to get a MDLAsset for type \"AnyAnchor\") with identifier \(identifier) from the modelProvider. Aborting the render phase.")
                        let newError = AKError.warning(.modelError(.modelNotFound(ModelErrorInfo(type:  "AnyAnchor", identifier: identifier))))
                        recordNewError(newError)
                        completion()
                        return
                    }
                    
                    self?.modelAssetsByUUID[identifier] = asset
                    self?.shaderPreferenceByUUID[identifier] = geometricEntity.shaderPreference
                }
            }
            
            numModels -= 1
            if numModels <= 0 {
                completion()
            }
            
        }
        
    }
    
    func loadPipeline(withMetalLibrary metalLibrary: MTLLibrary, renderDestination: RenderDestinationProvider, textureBundle: Bundle, forRenderPass renderPass: RenderPass? = nil) -> [DrawCallGroup] {
        
        guard let device = device else {
            print("Serious Error - device not found")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeDeviceNotFound, userInfo: nil)
            let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            return []
        }
            
        // Make sure there is at least one general purpose model
        guard modelAssetsByUUID[generalUUID] != nil else {
            print("Warning (AnchorsRenderModule) - Anchor Model was not found. Aborting the render phase.")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeModelNotFound, userInfo: nil)
            let newError = AKError.warning(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            return []
        }
        
        var drawCallGroups = [DrawCallGroup]()
        
        // Get a list of uuids
        let filteredGeometryUUIDs = geometricEntities.compactMap({$0.identifier})
        
        // filter the `modelAssetsByUUID` by the model asses contained in the list of uuids
        let filteredModelsByUUID = modelAssetsByUUID.filter { (uuid, asset) in
            filteredGeometryUUIDs.contains(uuid)
        }
        
        // Create a draw call group for every model asset. Each model asset may have multiple instances.
        for item in filteredModelsByUUID {
            
            // Check to make sure this geometry should be rendered in this render pass by calling the `geometryFilterFunction` function on the geometric enitiy and see if it passes the test.
            if let geometricEntity = geometricEntities.first(where: {$0.identifier == item.key}), let geometryFilterFunction = renderPass?.geometryFilterFunction {
                guard geometryFilterFunction(geometricEntity) else {
                    continue
                }
            }
            
            let uuid = item.key
            let mdlAsset = item.value
            let shaderPreference: ShaderPreference = {
                if let prefernece = shaderPreferenceByUUID[uuid] {
                    return prefernece
                } else {
                    return .pbr
                }
            }()
            
            // Build the GPU Data
            let meshGPUData = ModelIOTools.meshGPUData(from: mdlAsset, device: device, textureBundle: textureBundle, vertexDescriptor: RenderUtilities.createStandardVertexDescriptor(), frameRate: 60, shaderPreference: shaderPreference)
            
            // Create a draw call group that contins all of the individual draw calls for this model
            let drawCallGroup = createDrawCallGroup(forUUID: uuid, withMetalLibrary: metalLibrary, renderDestination: renderDestination, renderPass: renderPass, meshGPUData: meshGPUData)
            drawCallGroup.moduleIdentifier = moduleIdentifier
            
            drawCallGroups.append(drawCallGroup)
            
        }
        
        // Because there must be a deterministic way to order the draw calls so the draw call groups are sorted by UUID.
        drawCallGroups.sort { $0.uuid.uuidString < $1.uuid.uuidString }
        isInitialized = true
        
        return drawCallGroups
        
    }
    
    //
    // Per Frame Updates
    //
    
    func updateBufferState(withBufferIndex bufferIndex: Int) {
        
        anchorUniformBufferOffset = Constants.alignedAnchorInstanceUniformsSize * bufferIndex
        materialUniformBufferOffset = RenderModuleConstants.alignedMaterialSize * bufferIndex
        paletteBufferOffset = Constants.alignedPaletteSize * Constants.maxPaletteSize * bufferIndex
        effectsUniformBufferOffset = Constants.alignedEffectsUniformSize * bufferIndex
        environmentUniformBufferOffset = Constants.alignedEnvironmentUniformSize * bufferIndex
        
        anchorUniformBufferAddress = anchorUniformBuffer?.contents().advanced(by: anchorUniformBufferOffset)
        materialUniformBufferAddress = materialUniformBuffer?.contents().advanced(by: materialUniformBufferOffset)
        paletteBufferAddress = paletteBuffer?.contents().advanced(by: paletteBufferOffset)
        effectsUniformBufferAddress = effectsUniformBuffer?.contents().advanced(by: effectsUniformBufferOffset)
        environmentUniformBufferAddress = environmentUniformBuffer?.contents().advanced(by: environmentUniformBufferOffset)
        
    }
    
    func updateBuffers(withAllGeometricEntities: [AKGeometricEntity], moduleGeometricEntities: [AKGeometricEntity], cameraProperties: CameraProperties, environmentProperties: EnvironmentProperties, shadowProperties: ShadowProperties, forRenderPass renderPass: RenderPass) {
        
        let anchors: [AKAugmentedAnchor] = moduleGeometricEntities.compactMap({
            if let anAnchor = $0 as? AKAugmentedAnchor {
                return anAnchor
            } else {
                return nil
            }
        })
        
        // Update the anchor uniform buffer with transforms of the current frame's anchors
        anchorInstanceCount = 0
        var anchorsByUUID = [UUID: [AKAugmentedAnchor]]()
        environmentTextureByUUID = [:]
        
        //
        // Gather the UUID's
        //
        
        for akAnchor in anchors {
            
            guard let anchor = akAnchor.arAnchor else {
                continue
            }
            
            // Ignore anchors that are beyond the renderDistance
            let distance = anchorDistance(withTransform: anchor.transform, cameraProperties: cameraProperties)
            guard Double(distance) < renderDistance else {
                continue
            }
            
            anchorInstanceCount += 1
            
            if anchorInstanceCount > Constants.maxAnchorInstanceCount {
                anchorInstanceCount = Constants.maxAnchorInstanceCount
                break
            }
            
            // If an anchor is passed in that does not seem to be associated with any model, assign it the `generalUUD` so it will be rendered with a general model
            let uuid: UUID = {
                if modelAssetsByUUID[anchor.identifier] != nil {
                    return anchor.identifier
                } else {
                    return generalUUID
                }
            }()
            
            // collect all of the anchors by uuid. A uuid can be associated with multiple anchors (like the general uuid).
            if let currentAnchors = anchorsByUUID[uuid] {
                var mutableCurrentAnchors = currentAnchors
                mutableCurrentAnchors.append(akAnchor)
                anchorsByUUID[uuid] = mutableCurrentAnchors
            } else {
                anchorsByUUID[uuid] = [akAnchor]
            }
            
            // see if this anchor is associated with an environment anchor. An environment anchor applies to a regino of space which may contain serveral anchors.
            let environmentProperty = environmentProperties.environmentAnchorsWithReatedAnchors.first(where: {
                $0.value.contains(anchor.identifier)
            })
            if let environmentProbeAnchor = environmentProperty?.key, let texture = environmentProbeAnchor.environmentTexture {
                environmentTextureByUUID[uuid] = texture
            }
            
        }
        
        //
        // Update the Anchor uniform
        //
        
        var anchorMeshIndex = 0
        
        for drawCallGroup in renderPass.drawCallGroups {
            
            let uuid = drawCallGroup.uuid
            
            for drawCall in drawCallGroup.drawCalls {
                
                let akAnchors = anchorsByUUID[uuid] ?? []
                anchorCountByUUID[uuid] = akAnchors.count
                guard let drawData = drawCall.drawData else {
                    continue
                }
                
                for akAnchor in akAnchors {
                    
                    // Flip Z axis to convert geometry from right handed to left handed
                    var coordinateSpaceTransform = matrix_identity_float4x4
                    coordinateSpaceTransform.columns.2.z = -1.0
                    
                    // Apply the world transform (as defined in the imported model) if applicable
                    let worldTransform: matrix_float4x4 = {
                        if drawData.worldTransformAnimations.count > 0 {
                            let index = Int(cameraProperties.currentFrame % UInt(drawData.worldTransformAnimations.count))
                            return drawData.worldTransformAnimations[index]
                        } else {
                            return drawData.worldTransform
                        }
                    }()
                    coordinateSpaceTransform = simd_mul(coordinateSpaceTransform, worldTransform)
                    
                    // Update Heading
                    let headingTransform = akAnchor.heading.offsetRotation.quaternion.toMatrix4()
                    
                    if akAnchor.heading.type == .absolute {
                        let newTransform = headingTransform * float4x4(
                            float4(coordinateSpaceTransform.columns.0.x, 0, 0, 0),
                            float4(0, coordinateSpaceTransform.columns.1.y, 0, 0),
                            float4(0, 0, coordinateSpaceTransform.columns.2.z, 0),
                            float4(coordinateSpaceTransform.columns.3.x, coordinateSpaceTransform.columns.3.y, coordinateSpaceTransform.columns.3.z, 1)
                        )
                        coordinateSpaceTransform = newTransform
                    } else if akAnchor.heading.type == .relative {
                        coordinateSpaceTransform = coordinateSpaceTransform * headingTransform
                    }
                    
                    let modelMatrix = akAnchor.worldLocation.transform * coordinateSpaceTransform
                    let anchorUniforms = anchorUniformBufferAddress?.assumingMemoryBound(to: AnchorInstanceUniforms.self).advanced(by: anchorMeshIndex)
                    anchorUniforms?.pointee.hasGeometry = 1
                    anchorUniforms?.pointee.hasHeading = 1
                    anchorUniforms?.pointee.headingType = akAnchor.heading.type == .absolute ? 0 : 1
                    anchorUniforms?.pointee.headingTransform = headingTransform
                    anchorUniforms?.pointee.locationTransform = akAnchor.worldLocation.transform;
                    anchorUniforms?.pointee.worldTransform = worldTransform
                    anchorUniforms?.pointee.modelMatrix = modelMatrix
                    anchorUniforms?.pointee.normalMatrix = modelMatrix.normalMatrix
                    
                    //
                    // Update puppet animation
                    //
                    
                    updatePuppetAnimation(from: drawData, frameNumber: cameraProperties.currentFrame, frameRate: cameraProperties.frameRate)
                    
                    //
                    // Update Environment
                    //
                    
                    environmentData = {
                        var myEnvironmentData = EnvironmentData()
                        if let texture = environmentTextureByUUID[uuid] {
                            myEnvironmentData.environmentTexture = texture
                            myEnvironmentData.hasEnvironmentMap = true
                            return myEnvironmentData
                        } else {
                            myEnvironmentData.hasEnvironmentMap = false
                        }
                        return myEnvironmentData
                    }()
                    
                    let environmentUniforms = environmentUniformBufferAddress?.assumingMemoryBound(to: EnvironmentUniforms.self).advanced(by: anchorMeshIndex)
                    
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
                            return getRGB(from: lightEstimate.ambientColorTemperature)
                        } else {
                            return vector3(0.5, 0.5, 0.5)
                        }
                    }()
                    
                    environmentUniforms?.pointee.ambientLightColor = ambientLightColor// * ambientIntensity
                    
                    var directionalLightDirection : vector_float3 = environmentProperties.directionalLightDirection
                    directionalLightDirection = simd_normalize(directionalLightDirection)
                    environmentUniforms?.pointee.directionalLightDirection = directionalLightDirection
                    
                    let directionalLightColor: vector_float3 = vector3(0.6, 0.6, 0.6)
                    environmentUniforms?.pointee.directionalLightColor = directionalLightColor * ambientIntensity
                    
                    environmentUniforms?.pointee.directionalLightMVP = environmentProperties.directionalLightMVP
                    environmentUniforms?.pointee.shadowMVPTransformMatrix = shadowProperties.shadowMVPTransformMatrix
                    
                    if environmentData?.hasEnvironmentMap == true {
                        environmentUniforms?.pointee.hasEnvironmentMap = 1
                    } else {
                        environmentUniforms?.pointee.hasEnvironmentMap = 0
                    }
                    
                    //
                    // Update Effects uniform
                    //
                    
                    let effectsUniforms = effectsUniformBufferAddress?.assumingMemoryBound(to: AnchorEffectsUniforms.self).advanced(by: anchorMeshIndex)
                    var hasSetAlpha = false
                    var hasSetGlow = false
                    var hasSetTint = false
                    var hasSetScale = false
                    if let effects = akAnchor.effects {
                        let currentTime: TimeInterval = Double(cameraProperties.currentFrame) / cameraProperties.frameRate
                        for effect in effects {
                            switch effect.effectType {
                            case .alpha:
                                if let value = effect.value(forTime: currentTime) as? Float {
                                    effectsUniforms?.pointee.alpha = value
                                    hasSetAlpha = true
                                }
                            case .glow:
                                if let value = effect.value(forTime: currentTime) as? Float {
                                    effectsUniforms?.pointee.glow = value
                                    hasSetGlow = true
                                }
                            case .tint:
                                if let value = effect.value(forTime: currentTime) as? float3 {
                                    effectsUniforms?.pointee.tint = value
                                    hasSetTint = true
                                }
                            case .scale:
                                if let value = effect.value(forTime: currentTime) as? Float {
                                    let scaleMatrix = matrix_identity_float4x4
                                    effectsUniforms?.pointee.scale = scaleMatrix.scale(x: value, y: value, z: value)
                                    hasSetScale = true
                                }
                            }
                        }
                    }
                    if !hasSetAlpha {
                        effectsUniforms?.pointee.alpha = 1
                    }
                    if !hasSetGlow {
                        effectsUniforms?.pointee.glow = 0
                    }
                    if !hasSetTint {
                        effectsUniforms?.pointee.tint = float3(1,1,1)
                    }
                    if !hasSetScale {
                        effectsUniforms?.pointee.scale = matrix_identity_float4x4
                    }
                    
                    anchorMeshIndex += 1
                    
                }
                
            }
            
        }
        
        //
        // Update the shadow map
        //
        shadowMap = shadowProperties.shadowMap
        
    }
    
    func draw(withRenderPass renderPass: RenderPass, sharedModules: [SharedRenderModule]?) {
        
        guard anchorInstanceCount > 0 else {
            return
        }
        
        guard let renderEncoder = renderPass.renderCommandEncoder else {
            return
        }
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("Draw Anchors")
        
        if let sharedBuffer = sharedModules?.first(where: {$0.moduleIdentifier == SharedBuffersRenderModule.identifier}), renderPass.usesSharedBuffer {
            
            renderEncoder.pushDebugGroup("Draw Shared Uniforms")
            
            renderEncoder.setVertexBuffer(sharedBuffer.sharedUniformBuffer, offset: sharedBuffer.sharedUniformBufferOffset, index: Int(kBufferIndexSharedUniforms.rawValue))
            renderEncoder.setFragmentBuffer(sharedBuffer.sharedUniformBuffer, offset: sharedBuffer.sharedUniformBufferOffset, index: Int(kBufferIndexSharedUniforms.rawValue))
            
            renderEncoder.popDebugGroup()
            
        }
        
        if let environmentUniformBuffer = environmentUniformBuffer, renderPass.usesEnvironment {
            
            renderEncoder.pushDebugGroup("Draw Environment Uniforms")
            if let environmentTexture = environmentData?.environmentTexture, environmentData?.hasEnvironmentMap == true {
                renderEncoder.setFragmentTexture(environmentTexture, index: Int(kTextureIndexEnvironmentMap.rawValue))
            }
            renderEncoder.setVertexBuffer(environmentUniformBuffer, offset: environmentUniformBufferOffset, index: Int(kBufferIndexEnvironmentUniforms.rawValue))
            renderEncoder.setFragmentBuffer(environmentUniformBuffer, offset: environmentUniformBufferOffset, index: Int(kBufferIndexEnvironmentUniforms.rawValue))
            renderEncoder.popDebugGroup()
            
        }
        
        if let effectsBuffer = effectsUniformBuffer, renderPass.usesEffects {
            
            renderEncoder.pushDebugGroup("Draw Effects Uniforms")
            renderEncoder.setVertexBuffer(effectsBuffer, offset: effectsUniformBufferOffset, index: Int(kBufferIndexAnchorEffectsUniforms.rawValue))
            renderEncoder.setFragmentBuffer(effectsBuffer, offset: effectsUniformBufferOffset, index: Int(kBufferIndexAnchorEffectsUniforms.rawValue))
            renderEncoder.popDebugGroup()
            
        }
        
        if let shadowMap = shadowMap, renderPass.usesShadows {
            
            renderEncoder.pushDebugGroup("Attach Shadow Buffer")
            renderEncoder.setFragmentTexture(shadowMap, index: Int(kTextureIndexShadowMap.rawValue))
            renderEncoder.popDebugGroup()
            
        }
        
        var baseIndex = 0
        
        for drawCallGroup in renderPass.drawCallGroups.filter({ $0.moduleIdentifier == moduleIdentifier }) {
            
            let uuid = drawCallGroup.uuid
            
            let anchorcount = (anchorCountByUUID[uuid] ?? 0)
            
            // Geometry Draw Calls. The order of the draw calls in the draw call group determines the order in which they are dispatched to the GPU for rendering.
            for drawCall in drawCallGroup.drawCalls {
                
                guard let drawData = drawCall.drawData else {
                    continue
                }
                
                drawCall.prepareDrawCall(withRenderPass: renderPass)
                
                // Set any buffers fed into our render pipeline
                renderEncoder.setVertexBuffer(anchorUniformBuffer, offset: anchorUniformBufferOffset, index: Int(kBufferIndexAnchorInstanceUniforms.rawValue))
                renderEncoder.setVertexBuffer(paletteBuffer, offset: paletteBufferOffset, index: Int(kBufferIndexMeshPalettes.rawValue))
                
                var mutableDrawData = drawData
                mutableDrawData.instanceCount = anchorcount
                
                // Set the mesh's vertex data buffers and draw
                draw(withDrawData: mutableDrawData, with: renderEncoder, baseIndex: baseIndex)
                
                baseIndex += anchorcount
                
            }
            
        }
        
        renderEncoder.popDebugGroup()
        
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
    
    // MARK: - Private
    
    private enum Constants {
        static let maxAnchorInstanceCount = 256
        static let maxPaletteSize = 100
        static let alignedAnchorInstanceUniformsSize = ((MemoryLayout<AnchorInstanceUniforms>.stride * Constants.maxAnchorInstanceCount) & ~0xFF) + 0x100
        static let alignedPaletteSize = (MemoryLayout<matrix_float4x4>.stride & ~0xFF) + 0x100
        static let alignedEffectsUniformSize = ((MemoryLayout<AnchorEffectsUniforms>.stride * Constants.maxAnchorInstanceCount) & ~0xFF) + 0x100
        static let alignedEnvironmentUniformSize = ((MemoryLayout<EnvironmentUniforms>.stride * Constants.maxAnchorInstanceCount) & ~0xFF) + 0x100
    }
    
    private var device: MTLDevice?
    private var textureLoader: MTKTextureLoader?
    private var geometricEntities = [AKGeometricEntity]()
    private var generalUUID = UUID()
    private var modelAssetsByUUID = [UUID: MDLAsset]()
    private var shaderPreferenceByUUID = [UUID: ShaderPreference]()
    private var anchorUniformBuffer: MTLBuffer?
    private var materialUniformBuffer: MTLBuffer?
    private var paletteBuffer: MTLBuffer?
    private var effectsUniformBuffer: MTLBuffer?
    private var environmentUniformBuffer: MTLBuffer?
    private var environmentData: EnvironmentData?
    private var shadowMap: MTLTexture?
    
    // Offset within anchorUniformBuffer to set for the current frame
    private var anchorUniformBufferOffset: Int = 0
    
    // Offset within materialUniformBuffer to set for the current frame
    private var materialUniformBufferOffset: Int = 0
    
    // Offset within paletteBuffer to set for the current frame
    private var paletteBufferOffset = 0
    
    // Offset within effectsUniformBuffer to set for the current frame
    private var effectsUniformBufferOffset: Int = 0
    
    // Offset within environmentUniformBuffer to set for the current frame
    private var environmentUniformBufferOffset: Int = 0
    
    // Addresses to write anchor uniforms to each frame
    private var anchorUniformBufferAddress: UnsafeMutableRawPointer?
    
    // Addresses to write anchor uniforms to each frame
    private var materialUniformBufferAddress: UnsafeMutableRawPointer?
    
    // Addresses to write palette to each frame
    private var paletteBufferAddress: UnsafeMutableRawPointer?
    
    // Addresses to write effects uniforms to each frame
    private var effectsUniformBufferAddress: UnsafeMutableRawPointer?
    
    // Addresses to write environment uniforms to each frame
    private var environmentUniformBufferAddress: UnsafeMutableRawPointer?
    
    // number of frames in the anchor animation by anchor index
    private var anchorAnimationFrameCount = [Int]()
    
    private var anchorCountByUUID = [UUID: Int]()
    private var environmentTextureByUUID = [UUID: MTLTexture]()
    
    private func createDrawCallGroup(forUUID uuid: UUID, withMetalLibrary metalLibrary: MTLLibrary, renderDestination: RenderDestinationProvider, renderPass: RenderPass?, meshGPUData: MeshGPUData) -> DrawCallGroup {
        
        let myVertexDescriptor: MTLVertexDescriptor? = meshGPUData.vertexDescriptor
        
        guard let aVertexDescriptor = myVertexDescriptor else {
            print("Serious Error - Failed to create a MetalKit vertex descriptor from ModelIO.")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeInvalidMeshData, userInfo: nil)
            let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            return DrawCallGroup(drawCalls: [], uuid: uuid)
        }
        
        let shaderPreference = meshGPUData.shaderPreference
        
        // Create a draw call group containing draw calls. Each draw call is associated with a `DrawData` object in the `MeshGPUData`
        var drawCalls = [DrawCall]()
        for drawData in meshGPUData.drawData {
            
            let funcConstants = RenderUtilities.getFuncConstants(forDrawData: drawData)
            
            let fragFunc: MTLFunction = {
                do {
                    let fragmentShaderName: String = {
                        if shaderPreference == .simple {
                            return "anchorGeometryFragmentLightingSimple"
                        } else {
                            return "anchorGeometryFragmentLighting"
                        }
                    }()
                    return try metalLibrary.makeFunction(name: fragmentShaderName, constantValues: funcConstants)
                } catch let error {
                    print("Failed to create fragment function for pipeline state descriptor, error \(error)")
                    let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: error))))
                    recordNewError(newError)
                    fatalError()
                }
            }()
            
            let vertFunc: MTLFunction = {
                do {
                    // Specify which shader to use based on if the model has skinned puppet suppot
                    let vertexName = drawData.isSkinned ? "anchorGeometryVertexTransformSkinned" : "anchorGeometryVertexTransform"
                    return try metalLibrary.makeFunction(name: vertexName, constantValues: funcConstants)
                } catch let error {
                    print("Failed to create vertex function for pipeline state descriptor, error \(error)")
                    let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: error))))
                    recordNewError(newError)
                    fatalError()
                }
            }()

            let pipelineStateDescriptor: MTLRenderPipelineDescriptor = {
                if let renderPass = renderPass, let aPipelineDescriptor = renderPass.renderPipelineDescriptor(withVertexDescriptor: aVertexDescriptor, vertexFunction: vertFunc, fragmentFunction: fragFunc) {
                    return aPipelineDescriptor
                } else {
                    let aPipelineDescriptor = MTLRenderPipelineDescriptor()
                    aPipelineDescriptor.vertexDescriptor = aVertexDescriptor
                    aPipelineDescriptor.vertexFunction = vertFunc
                    aPipelineDescriptor.fragmentFunction = fragFunc
                    aPipelineDescriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
                    aPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
                    aPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                    aPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                    aPipelineDescriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
                    aPipelineDescriptor.stencilAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
                    aPipelineDescriptor.sampleCount = renderDestination.sampleCount
                    return aPipelineDescriptor
                }
            }()
            
            let anchorDepthStateDescriptor: MTLDepthStencilDescriptor = {
                if let renderPass = renderPass {
                    let aDepthStateDescriptor = renderPass.depthStencilDescriptor(withDepthComareFunction: .less, isDepthWriteEnabled: true)
                    return aDepthStateDescriptor
                } else {
                    let aDepthStateDescriptor = MTLDepthStencilDescriptor()
                    aDepthStateDescriptor.depthCompareFunction = .less
                    aDepthStateDescriptor.isDepthWriteEnabled = true
                    return aDepthStateDescriptor
                }
            }()
            
            if let drawCall = renderPass?.drawCall(withRenderPipelineDescriptor: pipelineStateDescriptor, depthStencilDescriptor: anchorDepthStateDescriptor, drawData: drawData) {
                drawCalls.append(drawCall)
            }
            
        }
        
        let drawCallGroup = DrawCallGroup(drawCalls: drawCalls, uuid: uuid)
        return drawCallGroup
        
    }
    
    private func updatePuppetAnimation(from drawData: DrawData, frameNumber: UInt, frameRate: Double = 60) {
        
        let capacity = Constants.alignedPaletteSize * Constants.maxPaletteSize
        let boundPaletteData = paletteBufferAddress?.bindMemory(to: matrix_float4x4.self, capacity: capacity)
        let paletteData = UnsafeMutableBufferPointer<matrix_float4x4>(start: boundPaletteData, count: Constants.maxPaletteSize)
        
        var jointPaletteOffset = 0
        for skin in drawData.skins {
            if let animationIndex = skin.animationIndex {
                let curAnimation = drawData.skeletonAnimations[animationIndex]
                let worldPose = evaluateAnimation(curAnimation, at: (Double(frameNumber) * 1.0 / frameRate))
                let matrixPalette = evaluateMatrixPalette(worldPose, skin)
                
                for k in 0..<matrixPalette.count {
                    paletteData[k + jointPaletteOffset] = matrixPalette[k]
                }
                
                jointPaletteOffset += matrixPalette.count
            }
        }
    }
    
}
