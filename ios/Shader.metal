#include <metal_stdlib>
using namespace metal;

// Bilinear interpolation resize kernel
kernel void resize_texture(texture2d<float, access::read> inputTexture [[texture(0)]],
                          texture2d<float, access::write> outputTexture [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]])
{
    // Get output dimensions
    uint outputWidth = outputTexture.get_width();
    uint outputHeight = outputTexture.get_height();
    
    // Check bounds
    if (gid.x >= outputWidth || gid.y >= outputHeight) {
        return;
    }
    
    // Get input dimensions
    uint inputWidth = inputTexture.get_width();
    uint inputHeight = inputTexture.get_height();
    
    // Calculate source coordinates with bilinear interpolation
    float srcX = (float(gid.x) + 0.5f) * float(inputWidth) / float(outputWidth) - 0.5f;
    float srcY = (float(gid.y) + 0.5f) * float(inputHeight) / float(outputHeight) - 0.5f;
    
    // Clamp to input bounds
    srcX = max(0.0f, min(float(inputWidth - 1), srcX));
    srcY = max(0.0f, min(float(inputHeight - 1), srcY));
    
    // Get integer coordinates
    uint x0 = uint(floor(srcX));
    uint y0 = uint(floor(srcY));
    uint x1 = min(x0 + 1, inputWidth - 1);
    uint y1 = min(y0 + 1, inputHeight - 1);
    
    // Get fractional parts
    float fx = srcX - float(x0);
    float fy = srcY - float(y0);
    
    // Sample four neighboring pixels
    float4 p00 = inputTexture.read(uint2(x0, y0));
    float4 p10 = inputTexture.read(uint2(x1, y0));
    float4 p01 = inputTexture.read(uint2(x0, y1));
    float4 p11 = inputTexture.read(uint2(x1, y1));
    
    // Bilinear interpolation
    float4 p0 = mix(p00, p10, fx);
    float4 p1 = mix(p01, p11, fx);
    float4 result = mix(p0, p1, fy);
    
    // Write to output texture
    outputTexture.write(result, gid);
}
