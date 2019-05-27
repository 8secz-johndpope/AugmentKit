//
//  SurfacesRenderModule.swift
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

/**
 A module for rendering to Real Surfaces. The most common use is for rendering shadows from Augmented geometries onto real surfaces. It can also be used to visualize the detected real surfaces for debugging and diagnostics
 */
class SurfacesRenderModule: RenderModule {
    
    static var identifier = "SurfacesRenderModule"
    
    //
    // Setup
    //
    
    var moduleIdentifier: String {
        return SurfacesRenderModule.identifier
    }
    var renderLayer: Int {
        return 2
    }
    var isInitialized: Bool = false
    var sharedModuleIdentifiers: [String]? = [SharedBuffersRenderModule.identifier]
    var renderDistance: Double = 500
    var errors = [AKError]()
    
    // The number of surface instances to render
    private(set) var instanceCount: Int = 0
    
    func initializeBuffers(withDevice aDevice: MTLDevice, maxInFlightFrames: Int, maxInstances: Int) {
        
        device = aDevice
        
        // Calculate our uniform buffer sizes. We allocate `maxInFlightFrames` instances for uniform
        // storage in a single buffer. This allows us to update uniforms in a ring (i.e. triple
        // buffer the uniforms) so that the GPU reads from one slot in the ring wil the CPU writes
        // to another. Surface uniforms should be specified with a max instance count for instancing.
        // Also uniform storage must be aligned (to 256 bytes) to meet the requirements to be an
        // argument in the constant address space of our shading functions.
        let materialUniformBufferSize = RenderModuleConstants.alignedMaterialSize * maxInFlightFrames
        let effectsUniformBufferSize = Constants.alignedEffectsUniformSize * maxInFlightFrames
        let environmentUniformBufferSize = Constants.alignedEnvironmentUniformSize * maxInFlightFrames
        
        // Create and allocate our uniform buffer objects. Indicate shared storage so that both the
        // CPU can access the buffer
        
        materialUniformBuffer = device?.makeBuffer(length: materialUniformBufferSize, options: .storageModeShared)
        materialUniformBuffer?.label = "MaterialUniformBuffer"
        
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
        modelProvider.loadAsset(forObjectType: "AnySurface", identifier: nil) { [weak self] asset in
            
            guard let asset = asset else {
                print("Warning (AnchorsRenderModule) - Failed to get a MDLAsset for type  \"AnySurface\") from the modelProvider. Aborting the render phase.")
                let newError = AKError.warning(.modelError(.modelNotFound(ModelErrorInfo(type:  "AnySurface"))))
                recordNewError(newError)
                completion()
                return
            }
            
            self?.generalModelAsset = asset
            
            if numModels == 0 {
                completion()
            }
            
        }
        
        // Load the per-geometry models
        for geometricEntity in geometricEntities {
            
            if let identifier = geometricEntity.identifier {
                modelProvider.loadAsset(forObjectType:  "AnySurface", identifier: identifier) { [weak self] asset in
                    
                    guard let asset = asset else {
                        print("Warning (SurfacesRenderModule) - Failed to get a MDLAsset for type \"AnySurface\") with identifier \(identifier) from the modelProvider. Aborting the render phase.")
                        let newError = AKError.warning(.modelError(.modelNotFound(ModelErrorInfo(type:  "AnySurface", identifier: identifier))))
                        recordNewError(newError)
                        completion()
                        return
                    }
                    
                    self?.modelAssetsForAnchorsByUUID[identifier] = asset
                    self?.shaderPreferenceForAnchorsByUUID[identifier] = geometricEntity.shaderPreference
                    
                }
            } else if let generalModelAsset = generalModelAsset {
                // One of the entities does not have an identifier so register the general asset
                modelAssetsForAnchorsByUUID[generalUUID] = generalModelAsset
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
        guard generalModelAsset != nil else {
            print("Warning (AnchorsRenderModule) - Anchor Model was not found. Aborting the render phase.")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeModelNotFound, userInfo: nil)
            let newError = AKError.warning(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            return []
        }
        
        var drawCallGroups = [DrawCallGroup]()
        
        for item in modelAssetsForAnchorsByUUID {
            
            guard let geometricEntity = geometricEntities.first(where: {$0.identifier == item.key}) else {
                continue
            }
            
            let uuid = item.key
            let mdlAsset = item.value
            let shaderPreference: ShaderPreference = {
                if let prefernece = shaderPreferenceForAnchorsByUUID[uuid] {
                    return prefernece
                } else {
                    return .pbr
                }
            }()
            
            let meshGPUData = ModelIOTools.meshGPUData(from: mdlAsset, device: device, textureBundle: textureBundle, vertexDescriptor: RenderUtilities.createStandardVertexDescriptor(), frameRate: 60, shaderPreference: shaderPreference)
            
            let drawCallGroup = createDrawCallGroup(forUUID: uuid, withMetalLibrary: metalLibrary, renderDestination: renderDestination, renderPass: renderPass, meshGPUData: meshGPUData, geometricEntity: geometricEntity)
            drawCallGroup.moduleIdentifier = moduleIdentifier
            
            drawCallGroups.append(drawCallGroup)
            
        }
        
        // In the buffer, the anchors are layed out by UUID in sorted order. So if there are
        // 5 anchors with UUID = "A..." and 3 UUIDs = "B..." and 1 UUID = "C..." then that's
        // how they will layed out in memory. Therefore updating the buffers is a 2 step process.
        // First, loop through all of the ARAnchors and gather the UUIDs as well as the counts for each.
        // Second, layout and update the buffers in the desired order.
        drawCallGroups.sort { $0.uuid.uuidString < $1.uuid.uuidString }
        isInitialized = true
        
        return drawCallGroups
        
    }
    
    //
    // Per Frame Updates
    //
    
    func updateBufferState(withBufferIndex theBufferIndex: Int) {
        
        bufferIndex = theBufferIndex
        
        materialUniformBufferOffset = RenderModuleConstants.alignedMaterialSize * bufferIndex
        effectsUniformBufferOffset = Constants.alignedEffectsUniformSize * bufferIndex
        environmentUniformBufferOffset = Constants.alignedEnvironmentUniformSize * bufferIndex
        
        materialUniformBufferAddress = materialUniformBuffer?.contents().advanced(by: materialUniformBufferOffset)
        effectsUniformBufferAddress = effectsUniformBuffer?.contents().advanced(by: effectsUniformBufferOffset)
        environmentUniformBufferAddress = environmentUniformBuffer?.contents().advanced(by: environmentUniformBufferOffset)
        
    }
    
    func updateBuffers(withModuleEntities moduleEntities: [AKEntity], cameraProperties: CameraProperties, environmentProperties: EnvironmentProperties, shadowProperties: ShadowProperties, argumentBufferProperties theArgumentBufferProperties: ArgumentBufferProperties, forRenderPass renderPass: RenderPass) {
        
        argumentBufferProperties = theArgumentBufferProperties
        
        let anchors: [AKRealAnchor] = moduleEntities.compactMap({
            if let anAnchor = $0 as? AKRealAnchor {
                return anAnchor
            } else {
                return nil
            }
        })
        
        // Update the anchor uniform buffer with transforms of the current frame's anchors
        instanceCount = 0
        anchorsByUUID = [:]
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
            
            instanceCount += 1
            
            if instanceCount > Constants.maxSurfaceInstanceCount {
                instanceCount = Constants.maxSurfaceInstanceCount
                break
            }
            
            let uuid: UUID = {
                if modelAssetsForAnchorsByUUID[anchor.identifier] != nil {
                    return anchor.identifier
                } else {
                    return generalUUID
                }
            }()
            
            if let currentAnchors = anchorsByUUID[uuid] {
                var mutableCurrentAnchors = currentAnchors
                mutableCurrentAnchors.append(akAnchor)
                anchorsByUUID[uuid] = mutableCurrentAnchors
            } else {
                anchorsByUUID[uuid] = [akAnchor]
            }
            
            // See if this anchor is associated with an environment anchor. An environment anchor applies to a region of space which may contain several anchors. The environment anchor that has the smallest volume is assumed to be more localized and therefore be the best for for this anchor
            let environmentProbes: [AREnvironmentProbeAnchor] = environmentProperties.environmentAnchorsWithReatedAnchors.compactMap{
                if $0.value.contains(anchor.identifier) {
                    return $0.key
                } else {
                    return nil
                }
            }
            if environmentProbes.count > 1 {
                var bestEnvironmentProbe: AREnvironmentProbeAnchor?
                environmentProbes.forEach {
                    if let theBestEnvironmentProbe = bestEnvironmentProbe {
                        let existingVolume = AKCube(position: AKVector(x: theBestEnvironmentProbe.transform.columns.3.x, y: theBestEnvironmentProbe.transform.columns.3.y, z: theBestEnvironmentProbe.transform.columns.3.z), extent: AKVector(theBestEnvironmentProbe.extent)).volume()
                        let newVolume = AKCube(position: AKVector(x: $0.transform.columns.3.x, y: $0.transform.columns.3.y, z: $0.transform.columns.3.z), extent: AKVector($0.extent)).volume()
                        if newVolume < existingVolume {
                            bestEnvironmentProbe = $0
                        }
                    } else {
                        bestEnvironmentProbe = $0
                    }
                }
                if let environmentProbeAnchor = bestEnvironmentProbe, let texture = environmentProbeAnchor.environmentTexture {
                    environmentTextureByUUID[uuid] = texture
                }
            } else {
                if let environmentProbeAnchor = environmentProbes.first, let texture = environmentProbeAnchor.environmentTexture {
                    environmentTextureByUUID[uuid] = texture
                }
            }
            
        }
        
        //
        // Update the Anchor uniform
        //
        
        var anchorMeshIndex = 0
        
        for drawCallGroup in renderPass.drawCallGroups {
            
            let uuid = drawCallGroup.uuid
            
            drawCallGroup.drawCalls.forEach { _ in
                
                let akAnchors = anchorsByUUID[uuid] ?? []
                
                for akAnchor in akAnchors {
                    
                    guard let arAnchor = akAnchor.arAnchor else {
                        continue
                    }
                    
                    let uuid: UUID = {
                        if modelAssetsForAnchorsByUUID[uuid] != nil {
                            return arAnchor.identifier
                        } else {
                            return generalUUID
                        }
                    }()
                    
                    //
                    // Update Geometry
                    //
                    
                    
                    
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
        
        guard instanceCount > 0 else {
            return
        }
        
        guard let renderEncoder = renderPass.renderCommandEncoder else {
            return
        }
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("Draw Surfaces")
        
        if let argumentBufferProperties = argumentBufferProperties, let vertexArgumentBuffer = argumentBufferProperties.vertexArgumentBuffer {
            renderEncoder.pushDebugGroup("Argument Buffer")
            renderEncoder.setVertexBuffer(vertexArgumentBuffer, offset: argumentBufferProperties.vertexArgumentBufferOffset(forFrame: bufferIndex), index: Int(kBufferIndexPrecalculationOutputBuffer.rawValue))
            renderEncoder.popDebugGroup()
        }
        
        if let environmentUniformBuffer = environmentUniformBuffer, renderPass.usesEnvironment {
            
            renderEncoder.pushDebugGroup("Draw Environment Uniforms")
            if let environmentTexture = environmentData?.environmentTexture, environmentData?.hasEnvironmentMap == true {
                renderEncoder.setFragmentTexture(environmentTexture, index: Int(kTextureIndexEnvironmentMap.rawValue))
            }
            renderEncoder.setFragmentBuffer(environmentUniformBuffer, offset: environmentUniformBufferOffset, index: Int(kBufferIndexEnvironmentUniforms.rawValue))
            renderEncoder.popDebugGroup()
            
        }
        
        if let effectsBuffer = effectsUniformBuffer, renderPass.usesEffects {
            
            renderEncoder.pushDebugGroup("Draw Effects Uniforms")
            renderEncoder.setFragmentBuffer(effectsBuffer, offset: effectsUniformBufferOffset, index: Int(kBufferIndexAnchorEffectsUniforms.rawValue))
            renderEncoder.popDebugGroup()
            
        }
        
        if let shadowMap = shadowMap, renderPass.usesShadows {
            
            renderEncoder.pushDebugGroup("Attach Shadow Buffer")
            renderEncoder.setFragmentTexture(shadowMap, index: Int(kTextureIndexShadowMap.rawValue))
            renderEncoder.popDebugGroup()
            
        }
        
        var drawCallGroupIndex: Int32 = 0
        var drawCallIndex: Int32 = 0
        var baseIndex = 0
        
        for drawCallGroup in renderPass.drawCallGroups {
            
            guard drawCallGroup.moduleIdentifier == moduleIdentifier else {
                drawCallIndex += Int32(drawCallGroup.drawCalls.count)
                drawCallGroupIndex += 1
                continue
            }
            
            // Use the render pass filter function to skip draw call groups on an individual basis
            if let filterFunction = renderPass.drawCallGroupFilterFunction {
                guard filterFunction(drawCallGroup) else {
                    drawCallIndex += Int32(drawCallGroup.drawCalls.count)
                    drawCallGroupIndex += 1
                    continue
                }
            }
            
            let uuid = drawCallGroup.uuid
            
            // TODO: remove. I think this should always be 1. Even if draw call groups share geometries, we should only be incrementing the base index once per draw call. The whole idea of sharing geometries is probably misguided anyway
            let anchorcount = (anchorsByUUID[uuid] ?? []).count
//            if anchorcount > 1 {
//                print("There are \(anchorcount) geometries sharing this one UUID. This is something to refactor.")
//            }
            
            // Geometry Draw Calls
            for drawCall in drawCallGroup.drawCalls {
                
                guard let drawData = drawCall.drawData else {
                    drawCallIndex += 1
                    continue
                }
                
                drawCall.prepareDrawCall(withRenderPass: renderPass)
                
                // Set the offset index of the draw call into the argument buffer
                renderEncoder.setVertexBytes(&drawCallIndex, length: MemoryLayout<Int32>.size, index: Int(kBufferIndexDrawCallIndex.rawValue))
                // Set the offset index of the draw call group into the argument buffer
                renderEncoder.setVertexBytes(&drawCallGroupIndex, length: MemoryLayout<Int32>.size, index: Int(kBufferIndexDrawCallGroupIndex.rawValue))
                
                var mutableDrawData = drawData
                mutableDrawData.instanceCount = anchorcount
                
                // Set the mesh's vertex data buffers and draw
                draw(withDrawData: mutableDrawData, with: renderEncoder, baseIndex: baseIndex)
                
                baseIndex += anchorcount
                drawCallIndex += 1
                
            }
            
            drawCallGroupIndex += 1
            
        }
        
        renderEncoder.popDebugGroup()
        
    }
    
    func frameEncodingComplete(renderPasses: [RenderPass]) {
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
        static let maxSurfaceInstanceCount = 64
        static let alignedEffectsUniformSize = ((MemoryLayout<AnchorEffectsUniforms>.stride * Constants.maxSurfaceInstanceCount) & ~0xFF) + 0x100
        static let alignedEnvironmentUniformSize = ((MemoryLayout<EnvironmentUniforms>.stride * Constants.maxSurfaceInstanceCount) & ~0xFF) + 0x100
    }
    
    private var bufferIndex: Int = 0
    private var device: MTLDevice?
    private var textureLoader: MTKTextureLoader?
    private var geometricEntities = [AKGeometricEntity]()
    private var generalUUID = UUID()
    private var modelAssetsForAnchorsByUUID = [UUID: MDLAsset]()
    private var generalModelAsset: MDLAsset?
    private var shaderPreferenceForAnchorsByUUID = [UUID: ShaderPreference]()
    private var materialUniformBuffer: MTLBuffer?
    private var effectsUniformBuffer: MTLBuffer?
    private var environmentUniformBuffer: MTLBuffer?
    private var environmentData: EnvironmentData?
    private var shadowMap: MTLTexture?
    private var argumentBufferProperties: ArgumentBufferProperties?
    
    // Offset within materialUniformBuffer to set for the current frame
    private var materialUniformBufferOffset: Int = 0
    
    // Offset within effectsUniformBuffer to set for the current frame
    private var effectsUniformBufferOffset: Int = 0
    
    // Offset within environmentUniformBuffer to set for the current frame
    private var environmentUniformBufferOffset: Int = 0
    
    // Addresses to write surface uniforms to each frame
    private var materialUniformBufferAddress: UnsafeMutableRawPointer?
    
    // Addresses to write effects uniforms to each frame
    private var effectsUniformBufferAddress: UnsafeMutableRawPointer?
    
    // Addresses to write environment uniforms to each frame
    private var environmentUniformBufferAddress: UnsafeMutableRawPointer?
    
    private var anchorsByUUID = [UUID: [AKRealAnchor]]()
    private var environmentTextureByUUID = [UUID: MTLTexture]()
    
    private func createDrawCallGroup(forUUID uuid: UUID, withMetalLibrary metalLibrary: MTLLibrary, renderDestination: RenderDestinationProvider, renderPass: RenderPass?, meshGPUData: MeshGPUData, geometricEntity: AKGeometricEntity) -> DrawCallGroup {
        
        guard let renderPass = renderPass else {
            print("Warning - Skipping all draw calls because the render pass is nil.")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeRenderPassNotFound, userInfo: nil)
            let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            return DrawCallGroup(drawCalls: [], uuid: uuid)
        }
        
        let myVertexDescriptor: MTLVertexDescriptor? = meshGPUData.vertexDescriptor
        
        guard let aVertexDescriptor = myVertexDescriptor else {
            print("Serious Error - Failed to create a MetalKit vertex descriptor from ModelIO.")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeInvalidMeshData, userInfo: nil)
            let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            return DrawCallGroup(drawCalls: [], uuid: uuid)
        }
        
        let shaderPreference = meshGPUData.shaderPreference
        
        // Saving all of the states for each mesh in the myPipelineStates array.
        var drawCalls = [DrawCall]()
        for drawData in meshGPUData.drawData {
            
            let fragmentShaderName: String = {
                if shaderPreference == .simple {
                    return "surfaceFragmentLightingSimple"
                } else {
                    // TODO: Support more complex lighting
                    return "surfaceFragmentLightingSimple"
                }
            }()
            
            let vertexShaderName = "surfaceGeometryVertexTransform"
            
            let drawCall = DrawCall(metalLibrary: metalLibrary, renderPass: renderPass, vertexFunctionName: vertexShaderName, fragmentFunctionName: fragmentShaderName, vertexDescriptor: aVertexDescriptor, drawData: drawData)
            drawCalls.append(drawCall)
            
        }
        
        let drawCallGroup = DrawCallGroup(drawCalls: drawCalls, uuid: uuid, generatesShadows: geometricEntity.generatesShadows)
        return drawCallGroup
        
    }
    
}
