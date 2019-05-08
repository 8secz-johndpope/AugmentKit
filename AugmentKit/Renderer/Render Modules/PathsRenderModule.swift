//
//  PathsRenderModule.swift
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

// TODO: Use a custom shader. The Anchor shader is best suited for rendering
// existing models, not dynamicly drawn content. Instead, create a new shader
// that lets us dynamicaly manipulate properties such as color at runtime.

import Foundation
import ARKit
import AugmentKitShader
import MetalKit

class PathsRenderModule: RenderModule {
    
    static var identifier = "PathsRenderModule"
    
    //
    // Setup
    //
    
    var moduleIdentifier: String {
        return PathsRenderModule.identifier
    }
    var renderLayer: Int {
        return 10
    }
    var isInitialized: Bool = false
    var sharedModuleIdentifiers: [String]? = [SharedBuffersRenderModule.identifier]
    var renderDistance: Double = 500
    var errors = [AKError]()
    
    // The number of path instances to render
    private(set) var pathSegmentInstanceCount: Int = 0
    
    // The UUID's of the anchors in the ARFrame.anchors array which mark the path.
    // Indexed by path
    private(set) var anchorIdentifiers = [Int: [UUID]]()
    
    func initializeBuffers(withDevice aDevice: MTLDevice, maxInFlightFrames: Int, maxInstances: Int) {
        
        device = aDevice
        
        // Calculate our uniform buffer sizes. We allocate `maxInFlightFrames` instances for uniform
        // storage in a single buffer. This allows us to update uniforms in a ring (i.e. triple
        // buffer the uniforms) so that the GPU reads from one slot in the ring wil the CPU writes
        // to another. Path uniforms should be specified with a max instance count for instancing.
        // Also uniform storage must be aligned (to 256 bytes) to meet the requirements to be an
        // argument in the constant address space of our shading functions.
        let pathUniformBufferSize = Constants.alignedPathSegmentInstanceUniformsSize * maxInFlightFrames
        let materialUniformBufferSize = RenderModuleConstants.alignedMaterialSize * maxInFlightFrames
        let effectsUniformBufferSize = Constants.alignedEffectsUniformSize * maxInFlightFrames
        
        // Create and allocate our uniform buffer objects. Indicate shared storage so that both the
        // CPU can access the buffer
        pathUniformBuffer = device?.makeBuffer(length: pathUniformBufferSize, options: .storageModeShared)
        pathUniformBuffer?.label = "PathUniformBuffer"
        
        materialUniformBuffer = device?.makeBuffer(length: materialUniformBufferSize, options: .storageModeShared)
        materialUniformBuffer?.label = "MaterialUniformBuffer"
        
        effectsUniformBuffer = device?.makeBuffer(length: effectsUniformBufferSize, options: .storageModeShared)
        effectsUniformBuffer?.label = "EffectsUniformBuffer"
        
        geometricEntities = []
        
    }
    
    func loadAssets(forGeometricEntities theGeometricEntities: [AKGeometricEntity], fromModelProvider: ModelProvider?, textureLoader: MTKTextureLoader, completion: (() -> Void)) {
        
        guard let device = device else {
            print("Serious Error - device not found")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeDeviceNotFound, userInfo: nil)
            let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            completion()
            return
        }
        
        // Create a MetalKit mesh buffer allocator so that ModelIO will load mesh data directly into
        // Metal buffers accessible by the GPU
        let metalAllocator = MTKMeshBufferAllocator(device: device)
        // Create a cylinder that is 10cm in diameter
        let mesh = MDLMesh.newCylinder(withHeight: 1, radii: vector2(0.05, 0.05), radialSegments: 6, verticalSegments: 1, geometryType: .triangles, inwardNormals: false, allocator: metalAllocator)
        let scatteringFunction = MDLScatteringFunction()
        let material = MDLMaterial(name: "baseMaterial", scatteringFunction: scatteringFunction)
        // TODO: Get color from the renderer as passed from the users setup
        let colorProperty = MDLMaterialProperty(name: "pathColor", semantic: .baseColor, float3: float3(255/255, 255/255, 255/255))
        material.setProperty(colorProperty)
        
        for submesh in mesh.submeshes!  {
            if let submesh = submesh as? MDLSubmesh {
                submesh.material = material
            }
        }
       
        let asset = MDLAsset(bufferAllocator: metalAllocator)
        asset.add(mesh)
        
        pathSegmentAsset = asset
        
        geometricEntities.append(contentsOf: theGeometricEntities)
    
        completion()
        
    }
    
    func loadPipeline(withMetalLibrary metalLibrary: MTLLibrary, renderDestination: RenderDestinationProvider, textureBundle: Bundle, forRenderPass renderPass: RenderPass? = nil) -> [DrawCallGroup] {
        
        guard let renderPass = renderPass else {
            print("Warning - Skipping all draw calls because the render pass is nil.")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeRenderPassNotFound, userInfo: nil)
            let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            return []
        }
        
        guard let device = device else {
            print("Serious Error - device not found")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeDeviceNotFound, userInfo: nil)
            let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            return []
        }
        
        guard let pathSegmentAsset = pathSegmentAsset else {
            print("Serious Error - pathSegmentAsset not found")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeModelNotFound, userInfo: nil)
            let newError = AKError.warning(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            return []
        }
        
        let meshGPUData = ModelIOTools.meshGPUData(from: pathSegmentAsset, device: device, textureBundle: textureBundle, vertexDescriptor: RenderUtilities.createStandardVertexDescriptor())
        
        if meshGPUData.drawData.count > 1 {
            print("WARNING: More than one mesh was found. Currently only one mesh per anchor is supported.")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeModelNotSupported, userInfo: nil)
            let newError = AKError.warning(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
        }
        
        let myVertexDescriptor = meshGPUData.vertexDescriptor
        
        guard let pathVertexDescriptor = myVertexDescriptor else {
            print("Serious Error - Failed to create a MetalKit vertex descriptor from ModelIO.")
            let underlyingError = NSError(domain: AKErrorDomain, code: AKErrorCodeInvalidMeshData, userInfo: nil)
            let newError = AKError.seriousError(.renderPipelineError(.failedToInitialize(PipelineErrorInfo(moduleIdentifier: moduleIdentifier, underlyingError: underlyingError))))
            recordNewError(newError)
            return []
        }
        
        var drawCalls = [DrawCall]()
        
        // Check to make sure this geometry should be rendered in this render pass
//        if let geometricEntity = geometricEntities.first(where: {$0.identifier == item.key}), let geometryFilterFunction = renderPass?.geometryFilterFunction {
//            guard geometryFilterFunction(geometricEntity) else {
//                continue
//            }
//        }
        
        for drawData in meshGPUData.drawData {
            let drawCall = DrawCall(metalLibrary: metalLibrary, renderPass: renderPass, vertexFunctionName: "pathVertexShader", fragmentFunctionName: "pathFragmentShader", vertexDescriptor: pathVertexDescriptor, drawData: drawData)
            drawCalls.append(drawCall)
        }
        
        let drawCallGroup = DrawCallGroup(drawCalls: drawCalls, generatesShadows: false)
        drawCallGroup.moduleIdentifier = moduleIdentifier
        
        isInitialized = true
        
        return [drawCallGroup]
        
    }
    
    //
    // Per Frame Updates
    //
    
    func updateBufferState(withBufferIndex theBufferIndex: Int) {
        
        bufferIndex = theBufferIndex
        
        pathUniformBufferOffset = Constants.alignedPathSegmentInstanceUniformsSize * bufferIndex
        materialUniformBufferOffset = RenderModuleConstants.alignedMaterialSize * bufferIndex
        effectsUniformBufferOffset = Constants.alignedEffectsUniformSize * bufferIndex
        
        pathUniformBufferAddress = pathUniformBuffer?.contents().advanced(by: pathUniformBufferOffset)
        materialUniformBufferAddress = materialUniformBuffer?.contents().advanced(by: materialUniformBufferOffset)
        effectsUniformBufferAddress = effectsUniformBuffer?.contents().advanced(by: effectsUniformBufferOffset)
        
    }
    
    func updateBuffers(withAllGeometricEntities: [AKGeometricEntity], moduleGeometricEntities: [AKGeometricEntity], cameraProperties: CameraProperties, environmentProperties: EnvironmentProperties, shadowProperties: ShadowProperties, argumentBufferProperties theArgumentBufferProperties: ArgumentBufferProperties, forRenderPass renderPass: RenderPass) {
        
        argumentBufferProperties = theArgumentBufferProperties
        
        let paths: [AKPath] = moduleGeometricEntities.compactMap({
            if let anPath = $0 as? AKPath {
                return anPath
            } else {
                return nil
            }
        })
        
        // Update the anchor uniform buffer with transforms of the current frame's anchors
        pathSegmentInstanceCount = 0
        anchorIdentifiers = [:]
        let renderSphere = AKSphere(center: AKVector(cameraProperties.position), radius: renderDistance)
        
        for path in paths {
            
//            var lastAnchor: AKAugmentedAnchor?
            var uuids = [UUID]()
            path.updateSegmentTransforms(withRenderSphere: renderSphere)
            
            for anchor in path.segmentPoints {
                
                // FIME: Remove most of this. The worldTransform is pre-caculated by updateSegmentTransforms
                
//                guard let myLastAnchor = lastAnchor else {
//                    lastAnchor = anchor
//                    continue
//                }
//
//                //
//                // Update the Instance uniform
//                //
//
//                // Clip the paths to the render sphere
//                let p0 = float3(myLastAnchor.worldLocation.transform.columns.3.x, myLastAnchor.worldLocation.transform.columns.3.y, myLastAnchor.worldLocation.transform.columns.3.z)
//                let p1 = float3(anchor.worldLocation.transform.columns.3.x, anchor.worldLocation.transform.columns.3.y, anchor.worldLocation.transform.columns.3.z)
//                let sphereIntersection = renderShpereIntersectionOfPath(withPoint0: p0, point1: p1, cameraProperties: cameraProperties)
//                guard sphereIntersection.isInside else {
//                    lastAnchor = anchor
//                    continue
//                }
                
                pathSegmentInstanceCount += 1
                
                if pathSegmentInstanceCount > Constants.maxPathSegmentInstanceCount {
                    pathSegmentInstanceCount = Constants.maxPathSegmentInstanceCount
                    break
                }
                
                if let identifier = anchor.identifier {
                    uuids.append(identifier)
                }
                
//                let lastAnchorPosition = sphereIntersection.point0
//                let anchorPosition = sphereIntersection.point1
//
//
//                // Ignore all rotation within anchor.worldLocation.transform.
//                // When dealing with paths, the anchors are considered points in space so rotation has no meaning.
//                let locationMatrix = matrix_identity_float4x4.translate(x: anchorPosition.x, y: anchorPosition.y, z: anchorPosition.z)
                
                //
                // Calculate world transform
                //
                
                let locationMatrix = anchor.worldLocation.transform
                let worldTransform = anchor.segmentTransform
                
//                var worldTransform = matrix_identity_float4x4
//
//                // Rotate and scale worldTransform so that it is oriented from
//                // myLastAnchor to anchor
//
//                // Do all calculations with doubles and convert them to floats a the end.
//                // This reduces floating point rounding errors especially when calculating
//                // andgles of rotation
//
//                let finalPosition = double3(0, 0, 0)
//                let initialPosition = double3(Double(lastAnchorPosition.x - anchorPosition.x), Double(lastAnchorPosition.y - anchorPosition.y), Double(lastAnchorPosition.z - anchorPosition.z))
//
//                // The following was taken from: http://www.thjsmith.com/40/cylinder-between-two-points-opengl-c
//                // Default cylinder direction (up)
//                let defaultLineDirection = double3(0,1,0)
//                // Get diff between two points you want cylinder along
//                let delta = (finalPosition - initialPosition)
//                // Get CROSS product (the axis of rotation)
//                let t = cross(defaultLineDirection , normalize(delta))
//
//                // Get the magnitude of the vector
//                let magDelta = length(delta)
//                // Get angle (radians)
//                let angle = acos(dot(defaultLineDirection, delta) / magDelta)
//
//                // The cylinder created by MDLMesh extends from (0, -0.5, 0) to (0, 0.5, 0). Translate it so that it is
//                // midway between the two points
//                let middle = -delta / 2
//                worldTransform = worldTransform.translate(x: Float(middle.x), y: Float(middle.y), z: Float(-middle.z))
//                if angle == Double.pi {
//                    worldTransform = worldTransform.rotate(radians: Float(angle), x: 0, y: 0, z: 1)
//                } else if Float(angle) > 0 {
//                    worldTransform = worldTransform.rotate(radians: Float(-angle), x: Float(t.x), y: Float(t.y), z: Float(-t.z))
//                }
//                worldTransform = worldTransform.scale(x: 1, y: Float(magDelta), z: 1)
                
                // Flip Z axis to convert geometry from right handed to left handed
                var coordinateSpaceTransform = matrix_identity_float4x4
                coordinateSpaceTransform.columns.2.z = -1.0
                coordinateSpaceTransform = coordinateSpaceTransform * worldTransform
                
                // Create the final transform matrix
                let modelMatrix = locationMatrix * coordinateSpaceTransform
                
                // Paths use the same uniform struct as anchors
                let pathSegmentIndex = pathSegmentInstanceCount - 1
                let pathUniforms = pathUniformBufferAddress?.assumingMemoryBound(to: AnchorInstanceUniforms.self).advanced(by: pathSegmentIndex)
                pathUniforms?.pointee.hasGeometry = 1
                pathUniforms?.pointee.hasHeading = 0
                pathUniforms?.pointee.headingType = 0
                pathUniforms?.pointee.headingTransform = matrix_identity_float4x4
                pathUniforms?.pointee.locationTransform = locationMatrix
                pathUniforms?.pointee.worldTransform =  worldTransform
                pathUniforms?.pointee.modelMatrix = modelMatrix
                pathUniforms?.pointee.normalMatrix = modelMatrix.normalMatrix
                
                //
                // Update Effects uniform
                //
                
                let effectsUniforms = effectsUniformBufferAddress?.assumingMemoryBound(to: AnchorEffectsUniforms.self).advanced(by: pathSegmentIndex)
                var hasSetAlpha = false
                var hasSetGlow = false
                var hasSetTint = false
                var hasSetScale = false
                if let effects = anchor.effects {
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
                
//                lastAnchor = anchor
                
            }
            
            if pathSegmentInstanceCount > 0 && pathSegmentInstanceCount < Constants.maxPathSegmentInstanceCount {
                anchorIdentifiers[pathSegmentInstanceCount - 1] = uuids
            }
            
        }
        
        //
        // Update the shadow map
        //
        shadowMap = shadowProperties.shadowMap
        
    }
    
    func draw(withRenderPass renderPass: RenderPass, sharedModules: [SharedRenderModule]?) {
        
        guard let renderEncoder = renderPass.renderCommandEncoder else {
            return
        }
        
        guard pathSegmentInstanceCount > 0 else {
            return
        }
        
        // Push a debug group allowing us to identify render commands in the GPU Frame Capture tool
        renderEncoder.pushDebugGroup("Draw Paths")
        
        // Set render command encoder state
        renderEncoder.setCullMode(.back)
        
        if let argumentBufferProperties = argumentBufferProperties, let vertexArgumentBuffer = argumentBufferProperties.vertexArgumentBuffer {
            renderEncoder.pushDebugGroup("Argument Buffer")
            renderEncoder.setVertexBuffer(vertexArgumentBuffer, offset: argumentBufferProperties.vertexArgumentBufferOffset(forFrame: bufferIndex), index: Int(kBufferIndexPrecalculationOutputBuffer.rawValue))
            renderEncoder.popDebugGroup()
        }
        
        if let effectsBuffer = effectsUniformBuffer {
            
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
        
        var drawCallGroupIndex: Int32 = 0
        var drawCallIndex: Int32 = 0
        
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
                
                // Set any buffers fed into our render pipeline
                renderEncoder.setVertexBuffer(pathUniformBuffer, offset: pathUniformBufferOffset, index: Int(kBufferIndexAnchorInstanceUniforms.rawValue))
                
                var mutableDrawData = drawData
                mutableDrawData.instanceCount = pathSegmentInstanceCount
                
                // Set the mesh's vertex data buffers and draw
                draw(withDrawData: mutableDrawData, with: renderEncoder)
                
            }
            
            drawCallGroupIndex += 1
            
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
    
    private var bufferIndex: Int = 0
    private var device: MTLDevice?
    private var textureLoader: MTKTextureLoader?
    private var geometricEntities = [AKGeometricEntity]()
    private var pathSegmentAsset: MDLAsset?
    private var pathUniformBuffer: MTLBuffer?
    private var materialUniformBuffer: MTLBuffer?
    private var effectsUniformBuffer: MTLBuffer?
    private var shadowMap: MTLTexture?
    private var argumentBufferProperties: ArgumentBufferProperties?
    
    // Offset within pathUniformBuffer to set for the current frame
    private var pathUniformBufferOffset: Int = 0
    
    // Offset within materialUniformBuffer to set for the current frame
    private var materialUniformBufferOffset: Int = 0
    
    // Offset within effectsUniformBuffer to set for the current frame
    private var effectsUniformBufferOffset: Int = 0
    
    // Addresses to write path uniforms to each frame
    private var pathUniformBufferAddress: UnsafeMutableRawPointer?
    
    // Addresses to write material uniforms to each frame
    private var materialUniformBufferAddress: UnsafeMutableRawPointer?
    
    // Addresses to write material uniforms to each frame
    private var effectsUniformBufferAddress: UnsafeMutableRawPointer?
    
    private enum Constants {
        static let maxPathSegmentInstanceCount = 2048
        // Paths use the same uniform struct as anchors
        static let alignedPathSegmentInstanceUniformsSize = ((MemoryLayout<AnchorInstanceUniforms>.stride * Constants.maxPathSegmentInstanceCount) & ~0xFF) + 0x100
        static let alignedEffectsUniformSize = ((MemoryLayout<AnchorEffectsUniforms>.stride * Constants.maxPathSegmentInstanceCount) & ~0xFF) + 0x100
    }
    
    // number of frames in the path animation by path index
    private var pathAnimationFrameCount = [Int]()
    
    private func createVertexDescriptor() -> MDLVertexDescriptor {
        
        // Create a vertex descriptor for our image plane vertex buffer
        let pathsVertexDescriptor = MTLVertexDescriptor()
        
        //
        // Attributes
        //
        
        // -------- Buffer 0 --------
        
        // Positions
        pathsVertexDescriptor.attributes[Int(kVertexAttributePosition.rawValue)].format = .float3 // 12 bytes
        pathsVertexDescriptor.attributes[Int(kVertexAttributePosition.rawValue)].offset = 0
        pathsVertexDescriptor.attributes[Int(kVertexAttributePosition.rawValue)].bufferIndex = Int(kBufferIndexMeshPositions.rawValue)
        
        // -------- Buffer 1 --------
        
        // Texture coordinates
        pathsVertexDescriptor.attributes[Int(kVertexAttributeTexcoord.rawValue)].format = .float2 // 8 bytes
        pathsVertexDescriptor.attributes[Int(kVertexAttributeTexcoord.rawValue)].offset = 0
        pathsVertexDescriptor.attributes[Int(kVertexAttributeTexcoord.rawValue)].bufferIndex = Int(kBufferIndexMeshGenerics.rawValue)
        
        // Normals
        pathsVertexDescriptor.attributes[Int(kVertexAttributeNormal.rawValue)].format = .float3 // 12 bytes
        pathsVertexDescriptor.attributes[Int(kVertexAttributeNormal.rawValue)].offset = 8
        pathsVertexDescriptor.attributes[Int(kVertexAttributeNormal.rawValue)].bufferIndex = Int(kBufferIndexMeshGenerics.rawValue)
        
        // Color
        pathsVertexDescriptor.attributes[Int(kVertexAttributeColor.rawValue)].format = .float3 // 12 bytes
        pathsVertexDescriptor.attributes[Int(kVertexAttributeColor.rawValue)].offset = 20
        pathsVertexDescriptor.attributes[Int(kVertexAttributeColor.rawValue)].bufferIndex = Int(kBufferIndexMeshGenerics.rawValue)
        
        //
        // Layouts
        //
        
        // Position Buffer Layout
        pathsVertexDescriptor.layouts[0].stride = 12
        pathsVertexDescriptor.layouts[0].stepRate = 1
        pathsVertexDescriptor.layouts[0].stepFunction = .perVertex
        
        // Generic Attribute Buffer Layout
        pathsVertexDescriptor.layouts[1].stride = 32
        pathsVertexDescriptor.layouts[1].stepRate = 1
        pathsVertexDescriptor.layouts[1].stepFunction = .perVertex
        
        //
        // Creata a Model IO vertexDescriptor so that we format/layout our model IO mesh vertices to
        // fit our Metal render pipeline's vertex descriptor layout
        //
        
        let vertexDescriptor = MTKModelIOVertexDescriptorFromMetal(pathsVertexDescriptor)
        
        // Indicate how each Metal vertex descriptor attribute maps to each ModelIO attribute
        (vertexDescriptor.attributes[Int(kVertexAttributePosition.rawValue)] as! MDLVertexAttribute).name = MDLVertexAttributePosition
        (vertexDescriptor.attributes[Int(kVertexAttributeTexcoord.rawValue)] as! MDLVertexAttribute).name = MDLVertexAttributeTextureCoordinate
        (vertexDescriptor.attributes[Int(kVertexAttributeNormal.rawValue)] as! MDLVertexAttribute).name = MDLVertexAttributeNormal
        (vertexDescriptor.attributes[Int(kVertexAttributeColor.rawValue)] as! MDLVertexAttribute).name = MDLVertexAttributeColor
        
        return vertexDescriptor
        
    }
    
}
