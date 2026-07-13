import Accelerate
import CoreVideo
import Foundation
import Metal
import MetalKit

/// Letterbox geometry produced by the resize step and consumed by the detection
/// decoder. Passed by value alongside the resized buffer so the two stages don't
/// have to communicate through global UserDefaults (which was both slow — disk-backed
/// writes every frame — and a cross-frame data race when two frames overlapped).
struct LetterboxInfo {
    let scale: Float
    let padX: Int
    let padY: Int
    let wasRotated: Bool
}

class MetalImageResizer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let letterboxPipelineState: MTLComputePipelineState
    private let rotatePipelineState: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache

    // Reused across frames to avoid per-frame allocations (~1.6MB output buffer +
    // ~8MB rotated texture every frame). Safe because frames are processed serially
    // and each frame fully overwrites these before the next one starts.
    private var outputBufferPool: CVPixelBufferPool?
    private var cachedRotatedTexture: MTLTexture?
    private var cachedRotatedDims: (w: Int, h: Int)?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        // Create texture cache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let textureCache = cache else {
            return nil
        }
        self.textureCache = textureCache

        // Simple letterbox kernel
        let letterboxKernel = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void letterboxResize(
            texture2d<float, access::read> inTexture [[texture(0)]],
            texture2d<float, access::write> outTexture [[texture(1)]],
            constant float2 &scale [[buffer(0)]],
            constant float2 &offset [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
                return;
            }

            // Calculate source position
            float2 srcPos = (float2(gid) - offset) / scale;

            // Check bounds
            if (srcPos.x < 0 || srcPos.y < 0 || 
                srcPos.x >= float(inTexture.get_width()) || 
                srcPos.y >= float(inTexture.get_height())) {
                // Black padding
                outTexture.write(float4(0.0, 0.0, 0.0, 1.0), gid);
                return;
            }

            // Read nearest pixel
            uint2 srcCoord = uint2(srcPos);
            float4 color = inTexture.read(srcCoord);

            // BGRA to RGB
            outTexture.write(float4(color.b, color.g, color.r, color.a), gid);
        }
        """

        // Rotation kernel for portrait mode
        let rotateKernel = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void rotate90(texture2d<float, access::read> inTexture [[texture(0)]],
                            texture2d<float, access::write> outTexture [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
                return;
            }

            // Rotate 90 degrees clockwise: new_x = old_y, new_y = width - old_x - 1
            uint2 inCoord = uint2(gid.y, inTexture.get_width() - gid.x - 1);

            float4 color = inTexture.read(inCoord);
            // Keep BGRA format for now
            outTexture.write(color, gid);
        }
        """

        do {
            let library = try device.makeLibrary(source: letterboxKernel + "\n" + rotateKernel, options: nil)
            guard let letterboxFunction = library.makeFunction(name: "letterboxResize"),
                  let rotateFunction = library.makeFunction(name: "rotate90")
            else {
                return nil
            }
            letterboxPipelineState = try device.makeComputePipelineState(function: letterboxFunction)
            rotatePipelineState = try device.makeComputePipelineState(function: rotateFunction)
        } catch {
            return nil
        }
    }

    func resize(_ pixelBuffer: CVPixelBuffer, isPortrait: Bool) -> (buffer: CVPixelBuffer, info: LetterboxInfo)? {
        autoreleasepool {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            defer {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                // pixelBuffer is a function parameter; cannot be set to nil, but document this
            }

            // Enable rotation for portrait mode
            var shouldRotate = isPortrait && width > height

            // Additional check for mismatch
            if (isPortrait && width > height) || (!isPortrait && height > width) {
                shouldRotate = true // Force rotation if dimensions don't match expected orientation
            }

            // Calculate letterbox parameters
            let targetSize: Float = 640.0
            let scale: Float
            let padX: Int
            let padY: Int

            if shouldRotate {
                // After rotation, dimensions swap
                scale = min(targetSize / Float(height), targetSize / Float(width))
                let scaledWidth = Int(Float(height) * scale)
                let scaledHeight = Int(Float(width) * scale)
                padX = (640 - scaledWidth) / 2
                padY = (640 - scaledHeight) / 2
            } else {
                scale = min(targetSize / Float(width), targetSize / Float(height))
                let scaledWidth = Int(Float(width) * scale)
                let scaledHeight = Int(Float(height) * scale)
                padX = (640 - scaledWidth) / 2
                padY = (640 - scaledHeight) / 2
            }

            let letterbox = LetterboxInfo(scale: scale, padX: padX, padY: padY, wasRotated: shouldRotate)

            // Create textures
            guard let inputTexture = createTexture(from: pixelBuffer) else {
                return nil
            }

            guard let pool = outputPool(width: 640, height: 640) else {
                return nil
            }
            var pooledBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pooledBuffer)
            guard let outputPixelBuffer = pooledBuffer,
                  let outputTexture = createTexture(from: outputPixelBuffer)
            else {
                return nil
            }

            defer {
                // No explicit unlock needed for outputPixelBuffer here,
                // but flush cache explicitly to ensure resources are freed
                CVMetalTextureCacheFlush(textureCache, 0)
                // outputPixelBuffer will be released by ARC after function returns
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                return nil
            }

            // Process texture (rotate if needed)
            let processedTexture: MTLTexture

            if shouldRotate {
                // Reuse a cached intermediate texture; only (re)allocate if the input
                // dimensions changed (they're constant for a given camera/orientation).
                if cachedRotatedDims?.w != height || cachedRotatedDims?.h != width || cachedRotatedTexture == nil {
                    let rotatedDesc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm,
                        width: height, // Swapped dimensions
                        height: width,
                        mipmapped: false
                    )
                    rotatedDesc.usage = [.shaderRead, .shaderWrite]
                    cachedRotatedTexture = device.makeTexture(descriptor: rotatedDesc)
                    cachedRotatedDims = (height, width)
                }

                guard let rotatedTexture = cachedRotatedTexture,
                      let rotateEncoder = commandBuffer.makeComputeCommandEncoder()
                else {
                    return nil
                }

                // Rotate the input
                rotateEncoder.setComputePipelineState(rotatePipelineState)
                rotateEncoder.setTexture(inputTexture, index: 0)
                rotateEncoder.setTexture(rotatedTexture, index: 1)

                let rotateThreadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
                let rotateThreadgroups = MTLSize(
                    width: (height + 15) / 16,
                    height: (width + 15) / 16,
                    depth: 1
                )

                rotateEncoder.dispatchThreadgroups(rotateThreadgroups, threadsPerThreadgroup: rotateThreadgroupSize)
                rotateEncoder.endEncoding()

                processedTexture = rotatedTexture
            } else {
                processedTexture = inputTexture
            }

            // Now letterbox resize
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return nil
            }

            encoder.setComputePipelineState(letterboxPipelineState)
            encoder.setTexture(processedTexture, index: 0)
            encoder.setTexture(outputTexture, index: 1)

            var scaleBuffer = SIMD2<Float>(scale, scale)
            var offsetBuffer = SIMD2<Float>(Float(padX), Float(padY))
            encoder.setBytes(&scaleBuffer, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            encoder.setBytes(&offsetBuffer, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (640 + 15) / 16,
                height: (640 + 15) / 16,
                depth: 1
            )

            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            CVMetalTextureCacheFlush(textureCache, 0)
            // All buffers will be released at this point

            return (outputPixelBuffer, letterbox)
        }
    }

    private func createTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let texture = cvTexture else {
            return nil
        }

        return CVMetalTextureGetTexture(texture)
    }

    private func outputPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = outputBufferPool { return pool }

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )

        outputBufferPool = (status == kCVReturnSuccess) ? pool : nil
        return outputBufferPool
    }

    func cleanup() {
        CVMetalTextureCacheFlush(textureCache, 0)
        // Force flush all cached textures
    }
}
