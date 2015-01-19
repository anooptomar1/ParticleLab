//
//  ViewController.swift
//  MetalParticles
//
//  Created by Simon Gladman on 17/01/2015.
//  Copyright (c) 2015 Simon Gladman. All rights reserved.
//
//  Reengineered based on technique from http://memkite.com/blog/2014/12/30/example-of-sharing-memory-between-gpu-and-cpu-with-swift-and-metal-for-ios8/

import UIKit
import Metal
import QuartzCore
import CoreData

class ViewController: UIViewController
{
    
    let bitmapInfo = CGBitmapInfo(CGBitmapInfo.ByteOrder32Big.rawValue | CGImageAlphaInfo.PremultipliedLast.rawValue)
    let renderingIntent = kCGRenderingIntentDefault
    
    let imageSide: UInt = 1280
    let imageSize = CGSize(width: Int(1280), height: Int(1280))
    let imageByteCount = Int(1280 * 1280 * 4)
    
    let bytesPerPixel = UInt(4)
    let bitsPerComponent = UInt(8)
    let bitsPerPixel:UInt = 32
    let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    
    let bytesPerRow = UInt(4 * 1280)
    let providerLength = Int(1280 * 1280 * 4) * sizeof(UInt8)
    var imageBytes = [UInt8](count: Int(1280 * 1280 * 4), repeatedValue: 0)
    
    var kernelFunction: MTLFunction!
    var pipelineState: MTLComputePipelineState!
    var defaultLibrary: MTLLibrary! = nil
    var device: MTLDevice! = nil
    var commandQueue: MTLCommandQueue! = nil
    
    let imageView =  UIImageView(frame: CGRectZero)
    let markerWidget = MarkerWidget(frame: CGRectZero)
    
    var region: MTLRegion!
    var textureA: MTLTexture!
    var textureB: MTLTexture! //
    let blankBitmapRawData = [UInt8](count: Int(1280 * 1280 * 4), repeatedValue: 0)
    
    var image:UIImage!
    var errorFlag:Bool = false
    
    var glow_threadGroupCount:MTLSize!
    var glow_threadGroups: MTLSize!
    
    var particle_threadGroupCount:MTLSize!
    var particle_threadGroups:MTLSize!
    
    let particleCount: Int = 1048576
    
    var particlesMemory:UnsafeMutablePointer<Void> = nil
    let alignment:UInt = 0x4000
    let xvectorByteSize:UInt = UInt(1048576) * UInt(sizeof(Particle))
    var particlesVoidPtr: COpaquePointer!
    var particlesParticlePtr: UnsafeMutablePointer<Particle>!
    var particlesParticleBufferPtr: UnsafeMutableBufferPointer<Particle>!
    
    var gravityWell = CGPoint(x: 640, y: 640)
    
    var frameStartTime = CFAbsoluteTimeGetCurrent()

    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        view.backgroundColor = UIColor.blackColor()

        imageView.contentMode = UIViewContentMode.ScaleAspectFit

        markerWidget.alpha = 0
    
        view.addSubview(imageView)
        view.addSubview(markerWidget)
        
        setUpParticles()
        
        setUpMetal()
    }
    
    override func touchesBegan(touches: NSSet, withEvent event: UIEvent)
    {
        let location = event.allTouches()?.anyObject()?.locationInView(imageView)
        
        if let _location = location
        {
            positionGravityWell(_location)
        }
    }
    
    override func touchesMoved(touches: NSSet, withEvent event: UIEvent)
    {
        let location = event.allTouches()?.anyObject()?.locationInView(imageView)
        
        if let _location = location
        {
            positionGravityWell(_location)
        }
    }
    
    func positionGravityWell(location: CGPoint)
    {
        if markerWidget.alpha == 0
        {
            UIView.animateWithDuration(0.25, animations: {self.markerWidget.alpha = 1})
        }
        
        let imageScale = imageView.frame.width / CGFloat(imageSide)
        
        gravityWell.x = location.x / imageScale
        gravityWell.y = location.y / imageScale
        
        markerWidget.frame = CGRect(x: imageView.frame.origin.x + location.x, y: imageView.frame.origin.y + location.y, width: 0, height: 0)
    }
    
    override func touchesEnded(touches: NSSet, withEvent event: UIEvent)
    {
        UIView.animateWithDuration(1.0, delay: 2.0, options: nil, animations: {self.markerWidget.alpha = 0}, completion: nil)
    }
    

    
    func setUpParticles()
    {
        posix_memalign(&particlesMemory, alignment, xvectorByteSize)
        
        particlesVoidPtr = COpaquePointer(particlesMemory)
        particlesParticlePtr = UnsafeMutablePointer<Particle>(particlesVoidPtr)
        particlesParticleBufferPtr = UnsafeMutableBufferPointer(start: particlesParticlePtr, count: particleCount)
 
        for index in particlesParticleBufferPtr.startIndex ..< particlesParticleBufferPtr.endIndex
        {
            var positionX = Float(arc4random() % UInt32(imageSide))
            var positionY = Float(arc4random() % UInt32(imageSide))
            let velocityX = (Float(arc4random() % 10) - 5) / 10.0
            let velocityY = (Float(arc4random() % 10) - 5) / 10.0
      
            let positionRule = Int(arc4random() % 4)
            
            if positionRule == 0
            {
                positionX = 0
            }
            else if positionRule == 1
            {
                positionX = Float(imageSide)
            }
            else if positionRule == 2
            {
                positionY = 0
            }
            else
            {
                positionY = Float(imageSide)
            }
            
            let particle = Particle(positionX: positionX, positionY: positionY, velocityX: velocityX, velocityY: velocityY)
    
            particlesParticleBufferPtr[index] = particle
        }
    }
    
    func setUpMetal()
    {
        device = MTLCreateSystemDefaultDevice()
 
        if device == nil
        {
            errorFlag = true
        }
        else
        {
            defaultLibrary = device.newDefaultLibrary()
            commandQueue = device.newCommandQueue()
   
            particle_threadGroupCount = MTLSize(width:32,height:1,depth:1)
            particle_threadGroups = MTLSize(width:(particleCount + 31) / 32, height:1, depth:1)
            
            glow_threadGroupCount = MTLSizeMake(16, 16, 1)
            glow_threadGroups = MTLSizeMake(Int(imageSide) / glow_threadGroupCount.width, Int(imageSide) / glow_threadGroupCount.height, 1)
            
            setUpTexture()
            
            run()
        }
    }

    final func run()
    {
        println("frametime:" + NSString(format: "%.6f", CFAbsoluteTimeGetCurrent() - frameStartTime))
        frameStartTime = CFAbsoluteTimeGetCurrent()
        
        Async.background()
        {
            self.applyShader()
        }
        .main
        {
            self.imageView.image = self.image

            self.run();
        }
    }
    
    final func glowTexture()
    {
        commandQueue = device.newCommandQueue()
        
        kernelFunction = defaultLibrary.newFunctionWithName("glowShader")
        pipelineState = device.newComputePipelineStateWithFunction(kernelFunction!, error: nil)
        
        let commandBuffer = commandQueue.commandBuffer()
        let commandEncoder = commandBuffer.computeCommandEncoder()
        
        commandEncoder.setComputePipelineState(pipelineState)
        
        commandEncoder.setTexture(textureA, atIndex: 0)
        commandEncoder.setTexture(textureA, atIndex: 1)
        commandEncoder.setTexture(textureB, atIndex: 2)
        
        commandEncoder.dispatchThreadgroups(glow_threadGroups, threadsPerThreadgroup: glow_threadGroupCount)
        
        commandEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

    }
    
    final func applyShader()
    {
        textureB.replaceRegion(self.region, mipmapLevel: 0, withBytes: blankBitmapRawData, bytesPerRow: Int(bytesPerRow))

        kernelFunction = defaultLibrary.newFunctionWithName("particleRendererShader")
        pipelineState = device.newComputePipelineStateWithFunction(kernelFunction!, error: nil)

        let commandBuffer = commandQueue.commandBuffer()
        let commandEncoder = commandBuffer.computeCommandEncoder()
        
        commandEncoder.setComputePipelineState(pipelineState)

        let particlesBufferNoCopy = device.newBufferWithBytesNoCopy(particlesMemory, length: Int(xvectorByteSize),
            options: nil, deallocator: nil)
        
        commandEncoder.setBuffer(particlesBufferNoCopy, offset: 0, atIndex: 0)
        commandEncoder.setBuffer(particlesBufferNoCopy, offset: 0, atIndex: 1)

        var gravityWellParticle = Particle(positionX: Float(gravityWell.x), positionY: Float(gravityWell.y), velocityX: 0, velocityY: 0)
        
        var inGravityWell = device.newBufferWithBytes(&gravityWellParticle, length: sizeofValue(gravityWellParticle), options: nil)
        commandEncoder.setBuffer(inGravityWell, offset: 0, atIndex: 2)
  
        commandEncoder.setTexture(textureB, atIndex: 0)
        
        commandEncoder.dispatchThreadgroups(particle_threadGroups, threadsPerThreadgroup: particle_threadGroupCount)
        
        commandEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        glowTexture()
        
        particlesVoidPtr = COpaquePointer(particlesMemory)
        particlesParticlePtr = UnsafeMutablePointer(particlesVoidPtr)
        particlesParticleBufferPtr = UnsafeMutableBufferPointer(start: particlesParticlePtr, count: particleCount)
   
        textureA.getBytes(&imageBytes, bytesPerRow: Int(bytesPerRow), fromRegion: region, mipmapLevel: 0)
        
        let providerRef = CGDataProviderCreateWithCFData(NSData(bytes: &imageBytes, length: providerLength))
        
        let imageRef = CGImageCreate(UInt(imageSize.width), UInt(imageSize.height), bitsPerComponent, bitsPerPixel, bytesPerRow, rgbColorSpace, bitmapInfo, providerRef, nil, false, renderingIntent)
        
        image =  UIImage(CGImage: imageRef)!
    }

    func setUpTexture()
    {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(MTLPixelFormat.RGBA8Unorm, width: Int(imageSide), height: Int(imageSide), mipmapped: false)
        
        textureA = device.newTextureWithDescriptor(textureDescriptor)
        textureB = device.newTextureWithDescriptor(textureDescriptor)
        
       region = MTLRegionMake2D(0, 0, Int(imageSide), Int(imageSide))
    }


    override func viewDidLayoutSubviews()
    {
        if view.frame.height > view.frame.width
        {
           let imageSide = view.frame.width
            
           imageView.frame = CGRect(x: 0, y: view.frame.height / 2.0 - imageSide / 2, width: imageSide, height: imageSide).rectByInsetting(dx: -1, dy: 01)
        }
        else
        {
            let imageSide = view.frame.height
            
            imageView.frame = CGRect(x: view.frame.width / 2.0 - imageSide / 2 , y: 0, width: imageSide, height: imageSide).rectByInsetting(dx: -1, dy: -1)
        }
        
        
    }
    
    override func didReceiveMemoryWarning()
    {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

}

struct Particle
{
    var positionX: Float = 0
    var positionY: Float = 0
    var velocityX: Float = 0
    var velocityY: Float = 0
}

