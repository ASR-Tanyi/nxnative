// Standalone Metal 3 prerequisite check. Built by scripts/check_mac15.py, not the host.
// Checks direct GPU-address argument buffers, classic compute/render/blit encoders,
// a shared-event signal and CPU readback. A pass is not a BOTW rendering test.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>

static int fail(NSString *message) {
    fprintf(stderr, "[RED] mac15 GPU probe: %s\n", message.UTF8String);
    return 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return fail(@"expected the probe.metallib path");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return fail(@"no Metal device");
        printf("GPU: %s; unified memory: %d; BC textures: %d; argument buffers: Tier %d (enum %lu)\n",
               device.name.UTF8String, device.hasUnifiedMemory, device.supportsBCTextureCompression,
               device.argumentBuffersSupport == MTLArgumentBuffersTier2 ? 2 : 1,
               (unsigned long)device.argumentBuffersSupport);
        if (!device.hasUnifiedMemory || !device.supportsBCTextureCompression ||
            device.argumentBuffersSupport != MTLArgumentBuffersTier2)
            return fail(@"the NVN port needs unified memory, BC textures and tier-2 argument buffers");

        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error];
        if (!library) return fail([NSString stringWithFormat:@"loading the offline library: %@", error]);
        id<MTLFunction> kernel = [library newFunctionWithName:@"probe_compute"];
        id<MTLFunction> vertex = [library newFunctionWithName:@"probe_vertex"];
        id<MTLFunction> fragment = [library newFunctionWithName:@"probe_fragment"];
        if (!kernel || !vertex || !fragment) return fail(@"the probe library is missing an entry point");
        id<MTLComputePipelineState> compute = [device newComputePipelineStateWithFunction:kernel error:&error];
        if (!compute) return fail([NSString stringWithFormat:@"compute pipeline: %@", error]);
        MTLRenderPipelineDescriptor *pipeline = [MTLRenderPipelineDescriptor new];
        pipeline.vertexFunction = vertex; pipeline.fragmentFunction = fragment;
        pipeline.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> render = [device newRenderPipelineStateWithDescriptor:pipeline error:&error];
        if (!render) return fail([NSString stringWithFormat:@"render pipeline: %@", error]);

        enum { COUNT = 64, SIDE = 4, ROW = 256 };
        id<MTLBuffer> input = [device newBufferWithLength:COUNT * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLBuffer> output = [device newBufferWithLength:COUNT * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTLBuffer> pixels = [device newBufferWithLength:ROW * SIDE options:MTLResourceStorageModeShared];
        if (!input || !output || !pixels) return fail(@"buffer allocation failed");
        for (unsigned i = 0; i < COUNT; i++) ((uint32_t *)input.contents)[i] = i;
        // Metal 3 permits direct encoding on tier-2 devices. Indirect resources must
        // also be declared with useResource; setting this argument buffer is not enough.
        struct { uint64_t input, output; } addresses = {input.gpuAddress, output.gpuAddress};
        id<MTLBuffer> args = [device newBufferWithBytes:&addresses length:sizeof addresses options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                            width:SIDE height:SIDE mipmapped:NO];
        textureDesc.storageMode = MTLStorageModePrivate; textureDesc.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> texture = [device newTextureWithDescriptor:textureDesc];
        id<MTLSharedEvent> event = [device newSharedEvent];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        if (!args || !texture || !event || !command) return fail(@"GPU resource or command allocation failed");

        id<MTLComputeCommandEncoder> ce = [command computeCommandEncoder];
        if (!ce) return fail(@"no compute encoder");
        [ce setComputePipelineState:compute]; [ce setBuffer:args offset:0 atIndex:0];
        [ce useResource:input usage:MTLResourceUsageRead];
        [ce useResource:output usage:MTLResourceUsageWrite];
        [ce dispatchThreads:MTLSizeMake(COUNT, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [ce endEncoding];

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1);
        id<MTLRenderCommandEncoder> re = [command renderCommandEncoderWithDescriptor:pass];
        if (!re) return fail(@"no render encoder");
        [re setRenderPipelineState:render];
        [re setViewport:(MTLViewport){0, 0, SIDE, SIDE, 0, 1}];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];
        id<MTLBlitCommandEncoder> be = [command blitCommandEncoder];
        if (!be) return fail(@"no blit encoder");
        [be copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(SIDE, SIDE, 1) toBuffer:pixels destinationOffset:0
                 destinationBytesPerRow:ROW destinationBytesPerImage:ROW * SIDE];
        [be endEncoding];
        [command encodeSignalEvent:event value:1];
        [command commit]; [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted)
            return fail([NSString stringWithFormat:@"command buffer: %@", command.error]);
        if (event.signaledValue != 1) return fail(@"the shared event was not signaled");
        for (unsigned i = 0; i < COUNT; i++) {
            if (((uint32_t *)output.contents)[i] != i * 3 + 7)
                return fail([NSString stringWithFormat:@"GPU-address compute readback differs at %u", i]);
        }
        for (unsigned y = 0; y < SIDE; y++) for (unsigned x = 0; x < SIDE; x++) {
            const uint8_t *p = (const uint8_t *)pixels.contents + y * ROW + x * 4;
            if (p[0] || p[1] != 255 || p[2] || p[3] != 255)
                return fail([NSString stringWithFormat:@"render/blit readback differs at %u,%u", x, y]);
        }
        puts("PASS: Metal 3 offline library, GPU-address bindings, compute, draw, blit and shared event");
        return 0;
    }
}
