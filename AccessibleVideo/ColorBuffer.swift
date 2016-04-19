//
//  ColorBuffer.swift
//  AccessibleVideo
//
//  Created by Luke Groeninger on 12/27/14.
//  Copyright (c) 2014 Luke Groeninger. All rights reserved.
//

import Metal

class ColorBuffer:MetalBuffer {
    var yuvToRGB:Matrix3x3? = nil
    
    override func setContents(arguments: MTLArgument) {
        if arguments.name == "colorParameters" {
            yuvToRGB = nil
            
            let parameters = arguments.bufferStructType.members as [MTLStructMember]
            for parameter in parameters {
                print("Found parameter \(parameter.name) at offset \(parameter.offset)")
                
                switch(parameter.name) {
                case "yuvToRGB":
                    let pointer = UnsafeMutablePointer<Float32>(_filterBufferData + parameter.offset)
                    yuvToRGB = Matrix3x3(buffer: pointer)
                    break;
                default:
                    print("Error: unknown parameter")
                    break;
                }
            }
        }
    }
}