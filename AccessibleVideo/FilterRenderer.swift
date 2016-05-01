//
//  FilterRenderer.swift
//  AccessibleVideo
//
//  Created by Luke Groeninger on 10/4/14.
//  Copyright (c) 2014 Luke Groeninger. All rights reserved.
//

import Foundation
import CoreVideo
import Metal
import MetalKit
import MetalPerformanceShaders
import AVFoundation
import UIKit

protocol RendererControlDelegate {
    var primaryColor:UIColor { get set }
    var secondaryColor:UIColor { get set }
    var invertScreen:Bool { get set }
    var highQuality:Bool { get }
}

enum RendererSetupError: ErrorType {
    case MissingDevice
    case ShaderListNotFound
    case FailedBufferCreation
    case FailedLibraryCreation
}

class FilterRenderer: NSObject, RendererControlDelegate {
    
    enum MPSFilerType {
        case AreaMax
        case AreaMin
        case Box
        case Tent
        case Convolution
        case Dialate
        case Erode
        case GaussianBlur
        case HistogramEqualization
        case HistogramSpecification
        case Integral
        case IntegralOfSquares
        case LanczosScale
        case Median
        case Sobel
        case ThresholdBinary
        case ThresholdBinaryInverse
        case ThresholdToZero
        case ThresholdToZeroInverse
        case ThresholdTruncate
        case Transpose
    }
    
    var device:MTLDevice? {
        return _device
    }
    
    var highQuality:Bool = false
    
    var primaryColor:UIColor = UIColor(red: 0.0, green: 1.0, blue: 1.0, alpha: 0.75) {
        didSet {
            setFilterBuffer()
        }
    }
    
    var secondaryColor:UIColor = UIColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 0.75){
        didSet {
            setFilterBuffer()
        }
    }
    
    var invertScreen:Bool = false {
        didSet {
            setFilterBuffer()
        }
    }
    
    private var _controller:UIViewController
    
    lazy private var _device = MTLCreateSystemDefaultDevice()
    lazy private var _vertexStart = [UIInterfaceOrientation : Int]()

    private var _vertexBuffer:MTLBuffer? = nil
    private var _filterArgs:MetalBufferArray<FilterBuffer>? = nil
    private var _colorArgs:MetalBufferArray<ColorBuffer>? = nil
    
    private var _currentFilterBuffer:Int = 0 {
        didSet {
            _currentFilterBuffer = _currentFilterBuffer % _numberShaderBuffers
        }
    }
    
    private var _currentColorBuffer:Int = 0 {
        didSet {
            _currentColorBuffer = _currentColorBuffer % _numberShaderBuffers
        }
    }
    /*
    private var _currentBlurBuffer:Int = 0 {
        didSet {
            _currentBlurBuffer = _currentBlurBuffer % _numberShaderBuffers
        }
    }
    */
    //private var _blurPipelineStates = [MTLRenderPipelineState]()
    private var _screenBlitState:MTLRenderPipelineState? = nil
    private var _screenInvertState:MTLRenderPipelineState? = nil
    
    private var _commandQueue: MTLCommandQueue? = nil
    
    private var _intermediateTextures = [MTLTexture]()
    private var _intermediateRenderPassDescriptor = [MTLRenderPassDescriptor]()

    
    private var _rgbTexture:MTLTexture? = nil
    private var _rgbDescriptor:MTLRenderPassDescriptor? = nil
    //private var _blurTexture:MTLTexture? = nil
    //private var _blurDescriptor:MTLRenderPassDescriptor? = nil
    
    
    // ping/pong index variable
    private var _currentSourceTexture:Int = 0 {
        didSet {
            _currentSourceTexture = _currentSourceTexture % 2
        }
    }
    
    private var _currentDestTexture:Int {
        return (_currentSourceTexture + 1) % 2
    }
    
    private var _numberBufferedFrames:Int = 2
    private var _numberShaderBuffers:Int {
        return _numberBufferedFrames + 1
    }
    
    private var _renderSemaphore: dispatch_semaphore_t? = nil
    
    private var _unmanagedTextureCache: Unmanaged<CVMetalTextureCache>?
    private var _textureCache: CVMetalTextureCache? = nil
    
    private var _vertexDesc: MTLVertexDescriptor? = nil
    
    private var _shaderLibrary: MTLLibrary? = nil
    private var _shaderDictionary: NSDictionary? = nil
    private var _renderPipelineStates = [String : MTLRenderPipelineState]()
    private var _computePipelineStates = [String : MTLComputePipelineState]()

    private var _shaderArguments = [String : NSObject]() // MTLRenderPipelineReflection
    
    private var _samplerStates = [MTLSamplerState]()
    
    private var _currentVideoFilter = [MTLRenderPipelineState]()
    private var _currentColorFilter:MTLRenderPipelineState? = nil
    private var _currentColorConvolution:[Float32] = [] {
        didSet {
            setColorBuffer()
        }
    }
    
    lazy private var _isiPad:Bool = (UIDevice.currentDevice().userInterfaceIdiom == .Pad)
    
    private var _viewport:MTLViewport? = nil
    
    private var threadsPerGroup:MTLSize!
    private var numThreadgroups: MTLSize!
    
    init(viewController:UIViewController) throws {
        _controller = viewController
        super.init()
        try setupRenderer()
    }
    
    // MARK: Setup
    
    func setupRenderer() throws
    {
        
        guard let device = device else {
            throw RendererSetupError.MissingDevice
        }
        
        // load the shader dictionary
        guard let path = NSBundle.mainBundle().pathForResource("Shaders", ofType: "plist") else {
            throw RendererSetupError.ShaderListNotFound
        }
        
        _shaderDictionary = NSDictionary(contentsOfFile: path)
        
        // create the render buffering semaphore
        _renderSemaphore = dispatch_semaphore_create(_numberBufferedFrames)
        
        // create texture caches for CoreVideo
        CVMetalTextureCacheCreate(nil, nil, device, nil, &_unmanagedTextureCache)
        
        guard let unmanagedTextureCache = _unmanagedTextureCache else {
            throw RendererSetupError.FailedBufferCreation
        }
        
        _textureCache = unmanagedTextureCache.takeUnretainedValue()
        
        // set up the full screen quads
        let data:[Float] = [
            // landscape right & passthrough
            -1.0,  -1.0,  0.0, 1.0,
            1.0,  -1.0,  1.0, 1.0,
            -1.0,   1.0,  0.0, 0.0,
            1.0,  -1.0,  1.0, 1.0,
            -1.0,   1.0,  0.0, 0.0,
            1.0,   1.0,  1.0, 0.0,
            // landscape left
            -1.0,  -1.0,  1.0, 0.0,
            1.0,  -1.0,  0.0, 0.0,
            -1.0,   1.0,  1.0, 1.0,
            1.0,  -1.0,  0.0, 0.0,
            -1.0,   1.0,  1.0, 1.0,
            1.0,   1.0,  0.0, 1.0,
            // portrait
            -1.0,  -1.0,  1.0, 1.0,
            1.0,  -1.0,  1.0, 0.0,
            -1.0,   1.0,  0.0, 1.0,
            1.0,  -1.0,  1.0, 0.0,
            -1.0,   1.0,  0.0, 1.0,
            1.0,   1.0,  0.0, 0.0,
            // portrait upside down
            -1.0,  -1.0,  0.0, 0.0,
            1.0,  -1.0,  0.0, 1.0,
            -1.0,   1.0,  1.0, 0.0,
            1.0,  -1.0,  0.0, 1.0,
            -1.0,   1.0,  1.0, 0.0,
            1.0,   1.0,  1.0, 1.0
        ]
        
        // set up vertex buffer
        let dataSize = data.count * sizeofValue(data[0]) // 1
        let options = MTLResourceOptions.StorageModeShared.union(MTLResourceOptions.CPUCacheModeDefaultCache)
        _vertexBuffer = device.newBufferWithBytes(data, length: dataSize, options: options)

        // set vertex indicies start for each rotation
        _vertexStart[.LandscapeRight] = 0
        _vertexStart[.LandscapeLeft] = 6
        _vertexStart[.Portrait] = 12
        _vertexStart[.PortraitUpsideDown] = 18
        
        // create default shader library
        guard let library = device.newDefaultLibrary() else {
            throw RendererSetupError.FailedLibraryCreation
        }
        _shaderLibrary = library
        print("Loading shader library...")
        for str in library.functionNames {
            print("Found shader: \(str)")
        }
        
        // create the full screen quad vertex attribute descriptor
        let vert = MTLVertexAttributeDescriptor()
        vert.format = .Float2
        vert.bufferIndex = 0
        vert.offset = 0
        
        let tex = MTLVertexAttributeDescriptor()
        tex.format = .Float2
        tex.bufferIndex = 0
        tex.offset = 2 * sizeof(Float)
        
        let layout = MTLVertexBufferLayoutDescriptor()
        layout.stride = 4 * sizeof(Float)
        layout.stepFunction = MTLVertexStepFunction.PerVertex
        
        
        let vertexDesc = MTLVertexDescriptor()
        
        vertexDesc.layouts[0] = layout
        vertexDesc.attributes[0] = vert
        vertexDesc.attributes[1] = tex
        
        _vertexDesc = vertexDesc
        
        
        // create filter parameter buffer
        // create common pipeline states

        _currentColorFilter = cachedRenderPipelineStateFor("yuv_rgb")

        _screenBlitState = cachedRenderPipelineStateFor("blit")
        _screenInvertState = cachedRenderPipelineStateFor("invert")

        if let blitArgs = _shaderArguments["blit"] as? MTLRenderPipelineReflection,
           let fragmentArguments = blitArgs.fragmentArguments {
            
            let myFragmentArgs = fragmentArguments.filter({$0.name == "filterParameters"})
            if myFragmentArgs.count == 1 {
                _filterArgs = MetalBufferArray<FilterBuffer>(arguments: myFragmentArgs[0], count: _numberShaderBuffers)
            }
            
        }
        
        if let yuvrgbArgs = _shaderArguments["yuv_rgb"] as? MTLRenderPipelineReflection,
           let fragmentArguments = yuvrgbArgs.fragmentArguments {
            
            let myFragmentArgs = fragmentArguments.filter({$0.name == "colorParameters"})
            if myFragmentArgs.count == 1 {
                _colorArgs = MetalBufferArray<ColorBuffer>(arguments: myFragmentArgs[0], count: _numberShaderBuffers)
            }
            
        }
        
        //_blurPipelineStates = []
        
        if device.supportsFeatureSet(.iOS_GPUFamily2_v1) {
            
            print("Using high quality")
            highQuality = true
            /*
            _blurPipelineStates = ["BlurX_HQ", "BlurY_HQ"].map {self.cachedRenderPipelineStateFor($0)}.flatMap{$0}
            if _blurPipelineStates.count < 2 {
                _blurPipelineStates = []
            }
            
            if let BlurXHQArgs = _shaderArguments["BlurX_HQ"] as? MTLRenderPipelineReflection,
               let fragmentArguments = BlurXHQArgs.fragmentArguments {
               
                let myFragmentArgs = fragmentArguments.filter({$0.name == "blurParameters"})
                if myFragmentArgs.count == 1 {
                    _blurArgs = MetalBufferArray<BlurBuffer>(arguments: myFragmentArgs[0], count: _numberShaderBuffers)
                }
                
            }
            */
        } else {
           highQuality = false
        }
        
         /*
        if _blurPipelineStates.count == 0 {
            
           
            _blurPipelineStates = ["BlurX", "BlurY"].map {self.cachedRenderPipelineStateFor($0)}.flatMap{$0}
            if _blurPipelineStates.count < 2 {
                _blurPipelineStates = []
            }
            if let BlurXHQArgs = _shaderArguments["BlurX"] as? MTLRenderPipelineReflection,
               let fragmentArguments = BlurXHQArgs.fragmentArguments {
                
                let myFragmentArgs = fragmentArguments.filter({$0.name == "blurParameters"})
                if myFragmentArgs.count == 1 {
                    _blurArgs = MetalBufferArray<BlurBuffer>(arguments: myFragmentArgs[0], count: _numberShaderBuffers)
                }
                
            }
 
        }
        */
        setFilterBuffer()
 
        let nearest = MTLSamplerDescriptor()
        nearest.label = "nearest"
        
        let bilinear = MTLSamplerDescriptor()
        bilinear.label = "bilinear"
        bilinear.minFilter = .Linear
        bilinear.magFilter = .Linear
        _samplerStates = [nearest, bilinear].map {device.newSamplerStateWithDescriptor($0)}
        
        // create the command queue
        _commandQueue = device.newCommandQueue()
        
    }
    
    // MARK: Render
    
    // create a pipeline state descriptor for a vertex/fragment shader combo
    func renderPipelineStateFor(label label:String, fragmentShader:String, vertexShader: String?) -> (MTLRenderPipelineState?, MTLRenderPipelineReflection?) {
        
        if  let device = device,
            let shaderLibrary = _shaderLibrary,
            let fragmentProgram = shaderLibrary.newFunctionWithName(fragmentShader),
            let vertexProgram = shaderLibrary.newFunctionWithName(vertexShader ?? "defaultVertex") {
            
            let pipelineStateDescriptor = MTLRenderPipelineDescriptor()
            pipelineStateDescriptor.label = label
            pipelineStateDescriptor.vertexFunction = vertexProgram
            pipelineStateDescriptor.fragmentFunction = fragmentProgram
            
            pipelineStateDescriptor.colorAttachments[0].pixelFormat = .BGRA8Unorm
            
            pipelineStateDescriptor.vertexDescriptor = _vertexDesc
            
            // create the actual pipeline state
            var info:MTLRenderPipelineReflection? = nil
            
            do {
                let pipelineState = try device.newRenderPipelineStateWithDescriptor(pipelineStateDescriptor, options: MTLPipelineOption.BufferTypeInfo, reflection: &info)
                return (pipelineState, info)
            } catch let pipelineError as NSError {
                print("Failed to create pipeline state for shaders \(vertexShader):\(fragmentShader) error \(pipelineError)")
            }
        }
        return (nil, nil)
    }
    
    func cachedRenderPipelineStateFor(shaderName:String) -> MTLRenderPipelineState? {
        guard let pipeline = _renderPipelineStates[shaderName] else {
            
            var fragment = shaderName
            var vertex:String? = nil
            
            if  let shaderDictionary = _shaderDictionary,
                let s = shaderDictionary.objectForKey(shaderName) as? NSDictionary {
                
                vertex = s.objectForKey("vertex") as? String
                if let frag:String = s.objectForKey("fragment") as? String {
                    fragment = frag
                }
                
            }
            
            let (state, reflector) = renderPipelineStateFor(label:shaderName, fragmentShader: fragment, vertexShader: vertex)
            _renderPipelineStates[shaderName] = state
            _shaderArguments[shaderName] = reflector
            return state
        }
        return pipeline
        
        
    }
    
    // MARK: Compute
    
    // create a pipeline state descriptor for a vertex/fragment shader combo
    func computePipelineStateFor(shaderName shaderName:String) throws -> (MTLComputePipelineState?, MTLComputePipelineReflection?) {
        
        if  let shaderLibrary = _shaderLibrary,
            let computeProgram = shaderLibrary.newFunctionWithName(shaderName) {
            
            guard let device = device else {
                throw RendererSetupError.MissingDevice
            }
            
            let pipelineStateDescriptor = MTLComputePipelineDescriptor()
            pipelineStateDescriptor.label = shaderName
            pipelineStateDescriptor.computeFunction = computeProgram
            
            // create the actual pipeline state
            var info:MTLComputePipelineReflection? = nil
            
            let pipelineState = try device.newComputePipelineStateWithDescriptor(pipelineStateDescriptor, options: MTLPipelineOption.BufferTypeInfo, reflection: &info)
            
            return (pipelineState, info)
            
        }
        
        return (nil, nil)
        
    }
    
    func cachedComputePipelineStateFor(shaderName:String) throws -> MTLComputePipelineState? {
        
        guard let pipeline = _computePipelineStates[shaderName] else {
            
            let (state, reflector) = try computePipelineStateFor(shaderName:shaderName)
            _computePipelineStates[shaderName] = state
            _shaderArguments[shaderName] = reflector
            return state
            
        }
        
        return pipeline
        
    }
    
    // MARK: Video
    
    func setVideoFilter(filterPasses:[String]) {
        print("Setting filter...")
        _currentVideoFilter = filterPasses.map {self.cachedRenderPipelineStateFor($0)}.flatMap{$0}
    }
    
    func setColorFilter(shaderName:String, convolution:[Float32]) {
        
        guard let shader = cachedRenderPipelineStateFor(shaderName) else {
            return
        }
        
        _currentColorFilter = shader
        _currentColorConvolution = convolution
    }
    /*
    func setBlurBuffer() {
        
        //
        // Texel offset generation for linear sampled gaussian blur
        // Source: http://rastergrid.com/blog/2010/09/efficient-gaussian-blur-with-linear-sampling/
        //
        
        let nextBuffer = (_currentBlurBuffer + 1) % _numberShaderBuffers
        
        guard let currentBuffer = _blurArgs?[nextBuffer] else {
            return
        }
        
        guard let rgbTexture = _rgbTexture else {
            return
        }
        
        let offsets:[Float32] = [ 0.0, 1.3846153846, 3.2307692308 ]
        
        let texelWidth = 1.0 / Float32(rgbTexture.width)
        let texelHeight = 1.0 / Float32(rgbTexture.height)
        
        currentBuffer.xOffsets = (
            (offsets[0] * texelWidth, 0),
            (offsets[1] * texelWidth, 0),
            (offsets[2] * texelWidth, 0)
        )
        
        currentBuffer.yOffsets = (
            (0, offsets[0] * texelHeight),
            (0, offsets[1] * texelHeight),
            (0, offsets[2] * texelHeight)
        )
        _currentBlurBuffer += 1
        
    }
    */
    func setColorBuffer() {
        
        guard let colorArgs = _colorArgs else {
            print("Warning: The colorArgs buffer was nil. Abouting")
            return
        }
        
        let nextBuffer = (_currentColorBuffer + 1) % _numberShaderBuffers
        _currentColorBuffer += 1

        if _currentColorConvolution.count == 9 {
            colorArgs[nextBuffer].yuvToRGB?.set(
                (
                    (_currentColorConvolution[0], _currentColorConvolution[1], _currentColorConvolution[2]),
                    (_currentColorConvolution[3], _currentColorConvolution[4], _currentColorConvolution[5]),
                    (_currentColorConvolution[6], _currentColorConvolution[7], _currentColorConvolution[8])
                )
            )
        } else {
            colorArgs[nextBuffer].yuvToRGB?.clearIdentity()
        }

    }
    
    func setFilterBuffer() {
        
        guard let filterArgs = _filterArgs else {
            print("Warning: The filterArgs buffer was nil. Abouting")
            return
        }
        
        let nextBuffer = (_currentFilterBuffer + 1) % _numberShaderBuffers
        _currentFilterBuffer += 1

        let currentBuffer = filterArgs[nextBuffer]
        if invertScreen {
            currentBuffer.primaryColor?.inverseColor = primaryColor
            currentBuffer.secondaryColor?.inverseColor = secondaryColor
        } else {
            currentBuffer.primaryColor?.color = primaryColor
            currentBuffer.secondaryColor?.color = secondaryColor
        }
        
        if highQuality {
            currentBuffer.lowThreshold = 0.05
            currentBuffer.highThreshold = 0.10
        } else {
            currentBuffer.lowThreshold = 0.15
            currentBuffer.highThreshold = 0.25
        }
        
    }
    
    // MARK: - Methods
    
    // MARK: Create Shaders
    
    // create generic render pass
    func createRenderPass(commandBuffer: MTLCommandBuffer,
                          pipeline:MTLRenderPipelineState,
                          vertexIndex:Int,
                          fragmentBuffers:[(MTLBuffer,Int)],
                          sourceTextures:[MTLTexture],
                          descriptor: MTLRenderPassDescriptor,
                          viewport:MTLViewport?) {
        let renderEncoder = commandBuffer.renderCommandEncoderWithDescriptor(descriptor)
        
        let name:String = pipeline.label ?? "Unnamed Render Pass"
        renderEncoder.pushDebugGroup(name)
        renderEncoder.label = name
        if let view = viewport {
            renderEncoder.setViewport(view)
        }
        renderEncoder.setRenderPipelineState(pipeline)
        
        renderEncoder.setVertexBuffer(_vertexBuffer, offset: 0, atIndex: 0)
        
        for (index,(buffer, offset)) in fragmentBuffers.enumerate() {
            renderEncoder.setFragmentBuffer(buffer, offset: offset, atIndex: index)
        }
        for (index,texture) in sourceTextures.enumerate() {
            renderEncoder.setFragmentTexture(texture, atIndex: index)
        }
        for (index,samplerState) in _samplerStates.enumerate() {
            renderEncoder.setFragmentSamplerState(samplerState, atIndex: index)
        }
        
        renderEncoder.drawPrimitives(.Triangle, vertexStart: vertexIndex, vertexCount: 6, instanceCount: 1)
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    func createComputePass(commandBuffer: MTLCommandBuffer,
                           pipeline:MTLComputePipelineState,
                           textures:[MTLTexture],
                           descriptor: MTLRenderPassDescriptor,
                           viewport:MTLViewport?,
                           aName: String?) {
        
        let computeEncoder = commandBuffer.computeCommandEncoder()
        let name:String = aName ?? "Unnamed Compute Pass"
        
        computeEncoder.pushDebugGroup(name)
        computeEncoder.label = name
        computeEncoder.setComputePipelineState(pipeline)
        
        for (index,texture) in textures.enumerate() {
            computeEncoder.setTexture(texture, atIndex: index)
        }
        
        computeEncoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadsPerGroup)
        
        computeEncoder.popDebugGroup()
        computeEncoder.endEncoding()
        
    }
    
    func createMPSPass(type: MPSFilerType,
                       device: MTLDevice,
                       commandBuffer: MTLCommandBuffer,
                       texture:MTLTexture,
                       kernelWidth: Int?,
                       kernelHeight: Int?,
                       sigma: Float?,
                       diameter: Int?) {
        
        var kernel: MPSUnaryImageKernel? = nil
        
        switch type {
        case .AreaMax:
            if let kernelWidth = kernelWidth, kernelHeight = kernelHeight {
                kernel = MPSImageAreaMax(device: device, kernelWidth: kernelWidth, kernelHeight: kernelHeight)
            }
        case .AreaMin:
            if let kernelWidth = kernelWidth, kernelHeight = kernelHeight {
                kernel = MPSImageAreaMin(device: device, kernelWidth: kernelWidth, kernelHeight: kernelHeight)
            }
        case .Box:
            if let kernelWidth = kernelWidth, kernelHeight = kernelHeight {
                kernel = MPSImageBox(device: device, kernelWidth: kernelWidth, kernelHeight: kernelHeight)
            }
        case .Convolution:
            if let kernelWidth = kernelWidth, kernelHeight = kernelHeight {
                kernel = MPSImageConvolution(device: device, kernelWidth: kernelWidth, kernelHeight: kernelHeight, weights: nil)
            }
        case .Dialate:
            if let kernelWidth = kernelWidth, kernelHeight = kernelHeight {
                kernel = MPSImageDilate(device: device, kernelWidth: kernelWidth, kernelHeight: kernelHeight, values: nil)
            }
        case .Erode:
            if let kernelWidth = kernelWidth, kernelHeight = kernelHeight {
                kernel = MPSImageErode(device: device, kernelWidth: kernelWidth, kernelHeight: kernelHeight, values: nil)
            }
        case .GaussianBlur:
            if let sigma = sigma {
                kernel = MPSImageGaussianBlur(device: device, sigma: sigma)
            }
        case .HistogramEqualization:
            kernel = MPSImageHistogramEqualization(device: device, histogramInfo: nil)
        case .HistogramSpecification:
            kernel = MPSImageHistogramSpecification(device: device, histogramInfo: nil)
        case .Integral:
            kernel = MPSImageIntegral(device: device)
        case .IntegralOfSquares:
            kernel = MPSImageIntegralOfSquares(device: device)
        case .LanczosScale:
            kernel = MPSImageLanczosScale(device: device)
        case .Median:
            if let diameter = diameter {
                kernel = MPSImageMedian(device: device, kernelDiameter:diameter )
            }
        case .Sobel:
            kernel = MPSImageSobel(device: device)
        case .ThresholdBinary:
            //kernel = MPSImageThresholdBinary(device: device)
            break
        case .ThresholdBinaryInverse:
            //kernel = MPSImageThresholdBinaryInverse(device: device)
            break
        case .ThresholdToZero:
            //kernel = MPSImageThresholdToZero(device: device)
            break
        case .ThresholdToZeroInverse:
            //kernel = MPSImageThresholdToZeroInverse(device: device)
            break
        case .ThresholdTruncate:
            //kernel = MPSImageThresholdTruncate(device: device)
            break
        case .Transpose:
            kernel = MPSImageTranspose(device: device)
        default: break
        }
     
        if let unwrappedKernel = kernel {
            
            let inPlaceTexture = UnsafeMutablePointer<MTLTexture?>.alloc(1)
            inPlaceTexture.initialize(texture)
            let myFallbackAllocator = { ( filter: MPSKernel, commandBuffer: MTLCommandBuffer, sourceTexture: MTLTexture) -> MTLTexture in
                let descriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(sourceTexture.pixelFormat, width: sourceTexture.width, height: sourceTexture.height, mipmapped: false)
                let result = commandBuffer.device.newTextureWithDescriptor(descriptor)
                return result
            }
            
            unwrappedKernel.encodeToCommandBuffer(commandBuffer, inPlaceTexture: inPlaceTexture, fallbackCopyAllocator: myFallbackAllocator)
        }
    }

}

// MARK: - CameraCaptureDelegate

extension FilterRenderer: CameraCaptureDelegate {
    
    func setResolution(width width: Int, height: Int) {
        
        guard let device = device else {
            return
        }
        
        objc_sync_enter(self)
        defer {
            objc_sync_exit(self)
        }
        
        threadsPerGroup = MTLSizeMake(16, 16, 1)
        numThreadgroups = MTLSizeMake(width / threadsPerGroup.width, height / threadsPerGroup.height, 1)
        
        let scale = UIScreen.mainScreen().nativeScale
        
        var textureWidth = Int(_controller.view.bounds.width * scale)
        var textureHeight = Int(_controller.view.bounds.height * scale)
        
        if (textureHeight > textureWidth) {
            let temp = textureHeight
            textureHeight = textureWidth
            textureWidth = temp
        }
        
        if ((textureHeight > height) || (textureWidth > width)) {
            textureHeight = height
            textureWidth = width
        }
        
        print("Setting offscreen texure resolution to \(textureWidth)x\(textureHeight)")
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(.BGRA8Unorm, width: textureWidth, height: textureHeight, mipmapped: false)
        descriptor.resourceOptions = MTLResourceOptions.StorageModePrivate
        descriptor.storageMode = MTLStorageMode.Private
        
        _intermediateTextures = [descriptor,descriptor].map { device.newTextureWithDescriptor($0) }
        _intermediateRenderPassDescriptor = _intermediateTextures.map {
            let renderDescriptor = MTLRenderPassDescriptor()
            renderDescriptor.colorAttachments[0].texture = $0
            renderDescriptor.colorAttachments[0].loadAction = .DontCare
            renderDescriptor.colorAttachments[0].storeAction = .DontCare
            return renderDescriptor
        }
        
        _rgbTexture = device.newTextureWithDescriptor(descriptor)
        let rgbDescriptor = MTLRenderPassDescriptor()
        rgbDescriptor.colorAttachments[0].texture = _rgbTexture
        rgbDescriptor.colorAttachments[0].loadAction = .DontCare
        rgbDescriptor.colorAttachments[0].storeAction = .Store
        _rgbDescriptor = rgbDescriptor
        /*
        _blurTexture = device.newTextureWithDescriptor(descriptor)
        let blurDescriptor = MTLRenderPassDescriptor()
        blurDescriptor.colorAttachments[0].texture = _blurTexture
        blurDescriptor.colorAttachments[0].loadAction = .DontCare
        blurDescriptor.colorAttachments[0].storeAction = .Store
        _blurDescriptor = blurDescriptor
        
        setBlurBuffer()
        */
    }
    
    
    func captureBuffer(sampleBuffer: CMSampleBuffer!) {
        
        if  _rgbTexture != nil,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let colorArgs = _colorArgs,
            let commandQueue = _commandQueue,
            let textureCache = _textureCache,
            let currentColorFilter = _currentColorFilter,
            let rgbDescriptor = _rgbDescriptor {
            
            let commandBuffer = commandQueue.commandBuffer()
            commandBuffer.enqueue()
            defer {
                commandBuffer.commit()
            }
            
            var y_texture: Unmanaged<CVMetalTexture>?
            let y_width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let y_height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, MTLPixelFormat.R8Unorm, y_width, y_height, 0, &y_texture)
            
            var uv_texture: Unmanaged<CVMetalTexture>?
            let uv_width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let uv_height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, MTLPixelFormat.RG8Unorm, uv_width, uv_height, 1, &uv_texture)
            
            guard let yTexture = y_texture, let uvTexture = uv_texture else {
                    return
            }
            
            let luma = CVMetalTextureGetTexture(yTexture.takeRetainedValue())!
            let chroma = CVMetalTextureGetTexture(uvTexture.takeRetainedValue())!
            
            let yuvTextures:[MTLTexture] = [ luma, chroma ]
            
            // create the YUV->RGB pass
            createRenderPass(commandBuffer,
                             pipeline: currentColorFilter,
                             vertexIndex: 0,
                             fragmentBuffers: [colorArgs.bufferAndOffsetForElement(_currentColorBuffer)],
                             sourceTextures: yuvTextures,
                             descriptor: rgbDescriptor,
                             viewport: nil)
            
            CVMetalTextureCacheFlush(textureCache, 0)
            
        }
    }
    
}

// MARK: - MTKViewDelegate

extension FilterRenderer: MTKViewDelegate {
    
    @objc func drawInMTKView(view: MTKView) {
        
        let currentOrientation:UIInterfaceOrientation = _isiPad ? UIApplication.sharedApplication().statusBarOrientation : .Portrait
        
        guard let commandQueue = _commandQueue,
              let renderSemaphore = _renderSemaphore,
              let currentDrawable = view.currentDrawable else {
            return
        }
        
        let commandBuffer = commandQueue.commandBuffer()
        
        dispatch_semaphore_wait(renderSemaphore, DISPATCH_TIME_FOREVER)
        // get the command buffer
        commandBuffer.enqueue()
        defer {
            // commit buffers to GPU
            commandBuffer.addCompletedHandler() {
                (cmdb:MTLCommandBuffer!) in
                dispatch_semaphore_signal(renderSemaphore)
                return
            }
            
            commandBuffer.presentDrawable(currentDrawable)
            commandBuffer.commit()
        }
        
        guard let rgbTexture = _rgbTexture,
              let currentOffset = _vertexStart[currentOrientation] where _rgbTexture != nil else {
            return
        }
        
        var sourceTexture:MTLTexture = rgbTexture
        var destDescriptor:MTLRenderPassDescriptor = _intermediateRenderPassDescriptor[_currentDestTexture]
        
        func swapTextures() {
            self._currentSourceTexture += 1
            sourceTexture = self._intermediateTextures[self._currentSourceTexture]
            destDescriptor = self._intermediateRenderPassDescriptor[self._currentDestTexture]
        }
        
        let secondaryTexture = rgbTexture
        
        /*
        
        if  applyBlur && _currentVideoFilterUsesBlur,
            let args = _blurArgs,
            let blurTexture = _blurTexture,
            let blurDescriptor = _blurDescriptor {
            
            let parameters = [args.bufferAndOffsetForElement(_currentBlurBuffer)]
            createRenderPass(commandBuffer,
                             pipeline:  _blurPipelineStates[0],
                             vertexIndex: 0,
                             fragmentBuffers: parameters,
                             sourceTextures: [rgbTexture],
                             descriptor: _intermediateRenderPassDescriptor[0],
                             viewport: nil)
            
            createRenderPass(commandBuffer,
                             pipeline:  _blurPipelineStates[1],
                             vertexIndex: 0,
                             fragmentBuffers: parameters,
                             sourceTextures: [_intermediateTextures[0]],
                             descriptor: blurDescriptor,
                             viewport: nil)
            secondaryTexture = blurTexture
            
        }
        */
        
        // apply all render passes in the current filter
        if  let filterArgs = _filterArgs,
            let screenDescriptor = view.currentRenderPassDescriptor {
            
            let filterParameters = [filterArgs.bufferAndOffsetForElement(_currentFilterBuffer)]
            for (_, filter) in _currentVideoFilter.enumerate() {
                createRenderPass(commandBuffer,
                                 pipeline: filter,
                                 vertexIndex: 0,
                                 fragmentBuffers: filterParameters,
                                 sourceTextures: [sourceTexture, secondaryTexture, rgbTexture],
                                 descriptor: destDescriptor,
                                 viewport: nil)
                
                swapTextures()
            }
            
            if let piplineState = invertScreen ? _screenInvertState : _screenBlitState {
            
                createRenderPass(commandBuffer,
                                 pipeline: piplineState,
                                 vertexIndex: currentOffset,
                                 fragmentBuffers: filterParameters,
                                 sourceTextures: [sourceTexture, secondaryTexture, rgbTexture],
                                 descriptor: screenDescriptor,
                                 viewport: _viewport)
                
                swapTextures()
                
            }
            
        }
        
    }
    
    @objc func mtkView(view: MTKView, drawableSizeWillChange size: CGSize) {
        
        if let rgbTexture = _rgbTexture {
            
            let iWidth = Double(rgbTexture.width)
            let iHeight = Double(rgbTexture.height)
            let aspect = iHeight / iWidth
            
            
            if size.width > size.height {
                let newHeight = Double(size.width) * aspect
                let diff = (Double(size.height) - newHeight) * 0.5
                _viewport = MTLViewport(originX: 0.0, originY: diff, width: Double(size.width), height: newHeight, znear: 0.0, zfar: 1.0)
            } else {
                let newHeight = Double(size.height) * aspect
                let diff = (Double(size.width) - newHeight) * 0.5
                _viewport = MTLViewport(originX: diff, originY: 0.0, width: newHeight, height: Double(size.height), znear: 0.0, zfar: 1.0)
            }
            
            if _viewport?.originX < 0.0 {
                _viewport?.originX = 0.0
            }
            if _viewport?.originY < 0.0 {
                _viewport?.originY = 0.0
            }
            
            if _viewport?.width > Double(size.width) {
                _viewport?.width = Double(size.width)
            }
            
            if _viewport?.height > Double(size.height) {
                _viewport?.height = Double(size.height)
            }
            
        }
        
    }
    
}