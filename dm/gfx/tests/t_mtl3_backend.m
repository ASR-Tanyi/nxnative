// Tests the actual Metal 3 backend, independently of the Metal 4 NVN replay.
// No game files. scripts/check_mac15.py compiles and runs this with validation.
#import "../nvn/nvn_mtl3.h"
#include <stdint.h>
#include <stdio.h>

static int bad(const char *expression, int line, NSError *error) {
    fprintf(stderr, "[RED] Metal 3 backend test line %d: %s (%s)\n", line, expression,
            error ? error.localizedDescription.UTF8String : "no error detail");
    return 1;
}
#define REQUIRE(expression) do { if (!(expression)) return bad(#expression, __LINE__, error); } while (0)

// Exercise the GPU-error latch without deliberately faulting the user's GPU.
@interface DmMtl3Queue (FailureTest)
- (void)completedWithError:(NSError *)error;
@end

static int map_tests(id<MTLDevice> device) {
    NSError *error = nil;
    DmMtl3BufferMap *map = [DmMtl3BufferMap new];
    id<MTLBuffer> buffer = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    REQUIRE(buffer);
    REQUIRE([map addBuffer:buffer error:&error]);
    REQUIRE([map addBuffer:buffer error:&error]);   // duplicate registration is idempotent
    NSUInteger offset = 0;
    REQUIRE([map bufferAtAddress:buffer.gpuAddress + 16 length:240 offset:&offset error:&error] == buffer);
    REQUIRE(offset == 16);
    REQUIRE(![map bufferAtAddress:buffer.gpuAddress + 16 length:241 offset:&offset error:&error]);
    REQUIRE(error.code == DmMtl3MissingAddress);
    REQUIRE(![map bufferAtAddress:UINT64_MAX length:2 offset:&offset error:&error]);
    DmMtl3Bindings *bindings = [DmMtl3Bindings new];
    REQUIRE([bindings setAddress:buffer.gpuAddress + 16 length:16 atIndex:0 map:map error:&error]);
    REQUIRE(![bindings setAddress:buffer.gpuAddress length:1 atIndex:DM_MTL3_BUFFERS map:map error:&error]);
    REQUIRE(![bindings setTexture:nil atIndex:DM_MTL3_TEXTURES error:&error]);
    REQUIRE(![bindings setSamplerState:nil atIndex:DM_MTL3_SAMPLERS error:&error]);
    [map removeBuffer:buffer]; [map removeBuffer:buffer];
    REQUIRE(![map bufferAtAddress:buffer.gpuAddress length:1 offset:&offset error:&error]);
    REQUIRE([bindings setAddress:0 length:0 atIndex:0 map:map error:&error]);
    [bindings clear];
    puts("PASS: Metal 3 buffer map, offsets, bounds, removal and binding validation");
    return 0;
}

static int submission_tests(id<MTLDevice> device, id<MTLLibrary> library) {
    NSError *error = nil;
    enum { COUNT = 64, OFFSET = 16, SIDE = 4, ROW = 256 };
    MTLResourceOptions options = MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked;
    id<MTLBuffer> values = [device newBufferWithLength:OFFSET + COUNT * sizeof(uint32_t) options:options];
    id<MTLBuffer> readback = [device newBufferWithLength:COUNT * sizeof(uint32_t) options:options];
    id<MTLBuffer> pixels = [device newBufferWithLength:ROW * SIDE options:MTLResourceStorageModeShared];
    uint32_t seven = 7, fifteen = 15;
    id<MTLBuffer> delta7 = [device newBufferWithBytes:&seven length:4 options:options];
    id<MTLBuffer> delta15 = [device newBufferWithBytes:&fifteen length:4 options:options];
    REQUIRE(values && readback && pixels && delta7 && delta15);
    for (unsigned i = 0; i < COUNT; i++) ((uint32_t *)((uint8_t *)values.contents + OFFSET))[i] = 20 + i;

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:SIDE height:SIDE mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.hazardTrackingMode = MTLHazardTrackingModeUntracked;
    td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    id<MTLTexture> image = [device newTextureWithDescriptor:td];
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [device newTextureWithDescriptor:td];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:sd];
    REQUIRE(image && target && sampler);
    struct { uint64_t address; MTLResourceID image, sampler; } raw = {values.gpuAddress + OFFSET, image.gpuResourceID, sampler.gpuResourceID};
    _Static_assert(sizeof raw == 24, "the raw argument buffer ABI");
    id<MTLBuffer> arguments = [device newBufferWithBytes:&raw length:sizeof raw options:options];
    REQUIRE(arguments);
    id<MTLFunction> addFunction = [library newFunctionWithName:@"m3_add"];
    id<MTLFunction> colorFunction = [library newFunctionWithName:@"m3_color"];
    REQUIRE(addFunction && colorFunction);
    id<MTLComputePipelineState> add = [device newComputePipelineStateWithFunction:addFunction error:&error];
    id<MTLComputePipelineState> color = [device newComputePipelineStateWithFunction:colorFunction error:&error];
    REQUIRE(add && color);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"m3_vertex"];
    pd.fragmentFunction = [library newFunctionWithName:@"m3_fragment"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    REQUIRE(pd.vertexFunction && pd.fragmentFunction);
    id<MTLRenderPipelineState> render = [device newRenderPipelineStateWithDescriptor:pd error:&error];
    REQUIRE(render);

    DmMtl3BufferMap *map = [DmMtl3BufferMap new];
    REQUIRE([map addBuffer:values error:&error]);
    REQUIRE([map addBuffer:delta7 error:&error]);
    REQUIRE([map addBuffer:delta15 error:&error]);
    REQUIRE([map addBuffer:arguments error:&error]);
    DmMtl3Queue *queue = [[DmMtl3Queue alloc] initWithDevice:device error:&error];
    REQUIRE(queue);
    // Encode the consumer first, then commit the producer first. The shared fence
    // must order by commits, even with untracked and indirectly accessed resources.
    DmMtl3Submission *consumer = [queue submissionWithError:&error];
    DmMtl3Submission *producer = [queue submissionWithError:&error];
    REQUIRE(consumer && producer && !consumer.serial && !producer.serial);
    DmMtl3Bindings *fragment = [DmMtl3Bindings new];
    REQUIRE([fragment setAddress:arguments.gpuAddress length:sizeof raw atIndex:0 map:map error:&error]);
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1);
    id<MTLRenderCommandEncoder> re = [consumer beginRender:pass error:&error];
    REQUIRE(re);
    REQUIRE(![consumer beginBlit:&error]);   // overlapping encoders are rejected
    REQUIRE(![consumer applyRenderBindings:fragment stages:0 error:&error]);
    error = nil;
    REQUIRE([consumer applyRenderBindings:fragment stages:MTLRenderStageFragment error:&error]);
    REQUIRE([consumer useResource:values usage:MTLResourceUsageRead error:&error]);
    REQUIRE([consumer useResource:image usage:MTLResourceUsageRead | MTLResourceUsageSample error:&error]);
    REQUIRE([consumer keepAlive:sampler error:&error]);
    [re setRenderPipelineState:render]; [re setViewport:(MTLViewport){0, 0, SIDE, SIDE, 0, 1}];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    REQUIRE([consumer endEncoding:&error]);
    id<MTLBlitCommandEncoder> be = [consumer beginBlit:&error];
    REQUIRE(be);
    [be copyFromBuffer:values sourceOffset:OFFSET toBuffer:readback destinationOffset:0 size:COUNT * sizeof(uint32_t)];
    [be copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(SIDE, SIDE, 1)
              toBuffer:pixels destinationOffset:0 destinationBytesPerRow:ROW destinationBytesPerImage:ROW * SIDE];
    REQUIRE([consumer endEncoding:&error]);

    DmMtl3Bindings *compute = [DmMtl3Bindings new];
    REQUIRE([compute setAddress:values.gpuAddress + OFFSET length:COUNT * 4 atIndex:0 map:map error:&error]);
    REQUIRE([compute setAddress:delta7.gpuAddress length:4 atIndex:1 map:map error:&error]);
    id<MTLComputeCommandEncoder> ce = [producer beginCompute:&error];
    REQUIRE(ce);
    [ce setComputePipelineState:add];
    REQUIRE([producer applyComputeBindings:compute error:&error]);
    [ce dispatchThreads:MTLSizeMake(COUNT, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    REQUIRE([producer computeBarrier:&error]);
    REQUIRE([compute setAddress:delta15.gpuAddress length:4 atIndex:1 map:map error:&error]);
    REQUIRE([producer applyComputeBindings:compute error:&error]);
    [ce dispatchThreads:MTLSizeMake(COUNT, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [compute clear];
    REQUIRE([compute setTexture:image atIndex:0 error:&error]);
    REQUIRE([producer applyComputeBindings:compute error:&error]);
    [ce setComputePipelineState:color];
    [ce dispatchThreads:MTLSizeMake(SIDE, SIDE, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    REQUIRE([producer endEncoding:&error]);

    // Registry removal and table reuse must not release previously encoded work.
    [map removeBuffer:values]; [map removeBuffer:delta7]; [map removeBuffer:delta15]; [map removeBuffer:arguments];
    [compute clear]; [fragment clear];
    values = nil; delta7 = nil; delta15 = nil; arguments = nil; image = nil; sampler = nil;
    __block BOOL producerOK = NO, consumerOK = NO;
    REQUIRE([producer addCompletedHandler:^(uint64_t serial, MTLCommandBufferStatus status, NSError *e, CFTimeInterval a, CFTimeInterval b) {
        producerOK = serial == 1 && status == MTLCommandBufferStatusCompleted && !e && a > 0 && b >= a;
        printf("producer serial %llu: GPU %.3f ms%s\n", (unsigned long long)serial, (b - a) * 1000, e ? e.description.UTF8String : "");
    } error:&error]);
    REQUIRE([consumer addCompletedHandler:^(uint64_t serial, MTLCommandBufferStatus status, NSError *e, CFTimeInterval a, CFTimeInterval b) {
        consumerOK = serial == 2 && status == MTLCommandBufferStatusCompleted && !e && a > 0 && b >= a;
        printf("consumer serial %llu: GPU %.3f ms%s\n", (unsigned long long)serial, (b - a) * 1000, e ? e.description.UTF8String : "");
    } error:&error]);
    REQUIRE([producer commit:&error]); REQUIRE([consumer commit:&error]);
    REQUIRE([producer waitUntilCompleted:10 error:&error]); REQUIRE([consumer waitUntilCompleted:10 error:&error]);
    REQUIRE(producerOK && consumerOK);
    for (unsigned i = 0; i < COUNT; i++) {
        uint32_t got = ((uint32_t *)readback.contents)[i];
        if (got != 42 + i) {
            fprintf(stderr, "value[%u]: got %u, expected %u\n", i, got, 42 + i);
            return bad("compute readback", __LINE__, nil);
        }
    }
    for (unsigned y = 0; y < SIDE; y++) for (unsigned x = 0; x < SIDE; x++) {
        const uint8_t *p = (const uint8_t *)pixels.contents + y * ROW + x * 4;
        if (p[0] != 0 || p[1] != 255 || p[2] != 0 || p[3] != 255) {
            fprintf(stderr, "pixel[%u,%u]: got (%u,%u,%u,%u), expected green\n", x, y, p[0], p[1], p[2], p[3]);
            return bad("render readback", __LINE__, nil);
        }
    }
    REQUIRE(![consumer commit:&error]); REQUIRE(![consumer beginCompute:&error]);
    puts("PASS: Metal 3 two submissions, rebinding, compute barrier, indirect texture/sampler, draw, blit and feedback");
    return 0;
}

static int lifetime_tests(id<MTLDevice> device) {
    NSError *error = nil;
    DmMtl3Queue *queue = [[DmMtl3Queue alloc] initWithDevice:device error:&error];
    REQUIRE(queue);
    DmMtl3Submission *cancelled = [queue submissionWithError:&error];
    REQUIRE(cancelled && [cancelled beginBlit:&error]);
    REQUIRE([cancelled cancel:&error]);
    REQUIRE(![cancelled commit:&error]); REQUIRE(![cancelled waitUntilCompleted:0 error:&error]);
    DmMtl3Submission *submission = [queue submissionWithError:&error];
    id<MTLSharedEvent> gate = [device newSharedEvent], signal = [device newSharedEvent];
    REQUIRE(submission && gate && signal);
    REQUIRE([submission waitForEvent:gate value:1 error:&error]);
    __weak NSObject *weak;
    @autoreleasepool {
        NSObject *sentinel = [NSObject new]; weak = sentinel;
        REQUIRE([submission keepAlive:sentinel error:&error]);
    }
    id<MTLBlitCommandEncoder> blit = [submission beginBlit:&error];
    id<MTLBuffer> buffer = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    REQUIRE(blit && buffer);
    [blit fillBuffer:buffer range:NSMakeRange(0, 16) value:0x5a];
    REQUIRE([submission endEncoding:&error]);
    REQUIRE([submission signalEvent:signal value:9 error:&error]);
    REQUIRE([submission commit:&error]);
    @autoreleasepool { REQUIRE(weak != nil); }
    REQUIRE(![submission waitUntilCompleted:0 error:&error]); REQUIRE(error.code == DmMtl3TimedOut);
    REQUIRE(![submission cancel:&error]);
    gate.signaledValue = 1;
    REQUIRE([submission waitUntilCompleted:10 error:&error]);
    REQUIRE(signal.signaledValue == 9 && weak == nil);
    for (int i = 0; i < 16; i++) REQUIRE(((uint8_t *)buffer.contents)[i] == 0x5a);
    DmMtl3Submission *pending = [queue submissionWithError:&error]; REQUIRE(pending);
    NSError *fault = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorInternal userInfo:nil];
    [queue completedWithError:fault];
    REQUIRE(![pending commit:&error] && error == fault);
    REQUIRE(![queue submissionWithError:&error] && error == fault);
    REQUIRE([pending cancel:&error]);
    puts("PASS: Metal 3 cancellation, GPU event wait/signal, timeout, completion lifetime and error latch");
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSError *error = nil;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); REQUIRE(device);
        const char *path = argc > 1 ? argv[1] : "mtl3_backend.metallib";
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:@(path)] error:&error]; REQUIRE(library);
        if (map_tests(device) || submission_tests(device, library) || lifetime_tests(device)) return 1;
        puts("PASS: Metal 3 backend core (NVN replay and BOTW integration still pending)");
        return 0;
    }
}
