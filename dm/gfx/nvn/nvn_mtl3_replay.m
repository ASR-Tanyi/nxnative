#if DM_MAC15
#import "nvn_mtl3_replay.h"
#import <objc/runtime.h>

static void checked(BOOL ok, NSError *error, SEL operation) {
    if (ok) return;
    fprintf(stderr, "[RED] Metal 3 NVN %s: %s\n", sel_getName(operation),
            error.localizedDescription.UTF8String ?: "invalid replay state");
    abort();
}
#define ENCODE(operation) do { NSError *err = nil; BOOL ok = (operation); checked(ok, err, _cmd); } while (0)

@implementation DmMtl3ReplayTable {
    DmMtl3BufferMap *_map;
}
- (instancetype)initWithMap:(DmMtl3BufferMap *)map {
    if ((self = [super init])) _map = map;
    return self;
}
- (void)setAddress:(MTLGPUAddress)address atIndex:(NSUInteger)index {
    ENCODE([self setAddress:address length:1 atIndex:index map:_map error:&err]);
}
- (void)bindTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    ENCODE([self setTexture:texture atIndex:index error:&err]);
}
- (void)bindSampler:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    ENCODE([self setSamplerState:sampler atIndex:index error:&err]);
}
@end

@interface DmMtl3ReplayEncoder : NSObject {
@protected
    DmMtl3Submission *_sub;
    DmMtl3BufferMap *_map;
}
- (instancetype)initWithSubmission:(DmMtl3Submission *)sub map:(DmMtl3BufferMap *)map;
@end

@implementation DmMtl3ReplayEncoder
- (instancetype)initWithSubmission:(DmMtl3Submission *)sub map:(DmMtl3BufferMap *)map {
    if ((self = [super init])) { _sub = sub; _map = map; }
    return self;
}
- (id<MTLBuffer>)buffer:(uint64_t)address length:(NSUInteger)length offset:(NSUInteger *)offset {
    NSError *error = nil;
    id<MTLBuffer> buffer = [_map bufferAtAddress:address length:length offset:offset error:&error];
    checked(buffer != nil, error, _cmd);
    return buffer;
}
- (void)endEncoding { ENCODE([_sub endEncoding:&err]); }
// beginRender/beginCompute/beginBlit wait for the queue fence and endEncoding
// updates it. These bracket even a logical encoder split across native passes.
- (void)barrierAfterQueueStages:(NSUInteger)a beforeStages:(NSUInteger)b visibilityOptions:(NSUInteger)v {}
- (void)barrierAfterStages:(NSUInteger)a beforeQueueStages:(NSUInteger)b visibilityOptions:(NSUInteger)v {}
@end

@interface DmMtl3ReplayCompute : DmMtl3ReplayEncoder @end
@implementation DmMtl3ReplayCompute {
    id<MTLComputeCommandEncoder> _compute;
    id<MTLBlitCommandEncoder> _blit;
    id<MTLComputePipelineState> _pipeline;
    DmMtl3Bindings *_table;
    NSString *_label;
    NSUInteger _memory[31];
    uint32_t _memorySlots;
}
- (void)setLabel:(NSString *)label { _label = [label copy]; _compute.label = label; _blit.label = label; }
- (void)setArgumentTable:(DmMtl3Bindings *)table { _table = table; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)pipeline { _pipeline = pipeline; }
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index {
    checked(index < 31, nil, _cmd);
    _memory[index] = length; _memorySlots |= 1u << index;
}
- (id<MTLComputeCommandEncoder>)dispatchEncoder {
    if (_blit) { ENCODE([_sub endEncoding:&err]); _blit = nil; }
    if (!_compute) {
        NSError *error = nil;
        _compute = [_sub beginCompute:&error]; checked(_compute != nil, error, _cmd);
        _compute.label = _label;
    }
    checked(_pipeline != nil, nil, _cmd);
    [_compute setComputePipelineState:_pipeline];
    for (uint32_t bits = _memorySlots; bits; bits &= bits - 1) {
        unsigned slot = __builtin_ctz(bits);
        [_compute setThreadgroupMemoryLength:_memory[slot] atIndex:slot];
    }
    if (_table) ENCODE([_sub applyComputeBindings:_table error:&err]);
    return _compute;
}
- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)threads {
    [[self dispatchEncoder] dispatchThreadgroups:groups threadsPerThreadgroup:threads];
}
- (void)dispatchThreadgroupsWithIndirectBuffer:(uint64_t)address threadsPerThreadgroup:(MTLSize)threads {
    NSUInteger offset = 0;
    id<MTLBuffer> buffer = [self buffer:address length:sizeof(MTLDispatchThreadgroupsIndirectArguments) offset:&offset];
    [[self dispatchEncoder] dispatchThreadgroupsWithIndirectBuffer:buffer indirectBufferOffset:offset threadsPerThreadgroup:threads];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    // The replay's texture/buffer copies and fills have the native blit ABI.
    // Only forward selectors the blit protocol actually implements.
    if (!protocol_getMethodDescription(@protocol(MTLBlitCommandEncoder), selector, YES, YES).name)
        return [super forwardingTargetForSelector:selector];
    if (_compute) { ENCODE([_sub endEncoding:&err]); _compute = nil; }
    if (!_blit) {
        NSError *error = nil;
        _blit = [_sub beginBlit:&error]; checked(_blit != nil, error, _cmd);
        _blit.label = _label;
    }
    return _blit;
}
- (void)barrierAfterEncoderStages:(NSUInteger)a beforeEncoderStages:(NSUInteger)b visibilityOptions:(NSUInteger)v {
    if (_compute) ENCODE([_sub computeBarrier:&err]);
    if (_blit) { ENCODE([_sub endEncoding:&err]); _blit = nil; }
}
@end

@interface DmMtl3ReplayRender : DmMtl3ReplayEncoder
- (instancetype)initWithSubmission:(DmMtl3Submission *)sub map:(DmMtl3BufferMap *)map descriptor:(MTLRenderPassDescriptor *)descriptor;
@end

static const MTLRenderStages renderStages[] = {MTLRenderStageVertex, MTLRenderStageFragment, MTLRenderStageObject, MTLRenderStageMesh};
@implementation DmMtl3ReplayRender {
    id<MTLRenderCommandEncoder> _render;
    DmMtl3Bindings *_tables[4];
}
- (instancetype)initWithSubmission:(DmMtl3Submission *)sub map:(DmMtl3BufferMap *)map descriptor:(MTLRenderPassDescriptor *)descriptor {
    if ((self = [super initWithSubmission:sub map:map])) {
        NSError *error = nil;
        _render = [sub beginRender:descriptor error:&error]; checked(_render != nil, error, _cmd);
    }
    return self;
}
- (id)forwardingTargetForSelector:(SEL)selector { return _render; }
- (void)setArgumentTable:(DmMtl3Bindings *)table atStages:(MTLRenderStages)stages {
    for (NSUInteger i = 0; i < 4; i++) if (stages & renderStages[i]) _tables[i] = table;
}
- (void)bindStages:(MTLRenderStages)stages {
    for (NSUInteger i = 0; i < 4; i++) if ((stages & renderStages[i]) && _tables[i])
        ENCODE([_sub applyRenderBindings:_tables[i] stages:renderStages[i] error:&err]);
}
- (void)barrierAfterEncoderStages:(NSUInteger)after beforeEncoderStages:(NSUInteger)before visibilityOptions:(NSUInteger)visibility {
    // NVN render barriers select vertex/fragment. Their bit values agree with
    // MTLStages, while the all-stages mask also includes non-render work.
    MTLRenderStages stages = MTLRenderStageVertex | MTLRenderStageFragment;
    if ((after & stages) && (before & stages))
        [_render memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures | MTLBarrierScopeRenderTargets
                            afterStages:after & stages beforeStages:before & stages];
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)first vertexCount:(NSUInteger)count {
    [self bindStages:MTLRenderStageVertex | MTLRenderStageFragment];
    [_render drawPrimitives:type vertexStart:first vertexCount:count];
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)first vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)base {
    [self bindStages:MTLRenderStageVertex | MTLRenderStageFragment];
    [_render drawPrimitives:type vertexStart:first vertexCount:count instanceCount:instances baseInstance:base];
}
- (void)drawPrimitives:(MTLPrimitiveType)type indirectBuffer:(uint64_t)address {
    NSUInteger offset = 0;
    id<MTLBuffer> args = [self buffer:address length:sizeof(MTLDrawPrimitivesIndirectArguments) offset:&offset];
    [self bindStages:MTLRenderStageVertex | MTLRenderStageFragment];
    [_render drawPrimitives:type indirectBuffer:args indirectBufferOffset:offset];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)indexType indexBuffer:(uint64_t)address indexBufferLength:(NSUInteger)length instanceCount:(NSUInteger)instances baseVertex:(NSInteger)vertex baseInstance:(NSUInteger)base {
    if (!count || !instances) return;
    NSUInteger width = indexType == MTLIndexTypeUInt16 ? 2 : 4, offset = 0;
    checked(count <= length / width, nil, _cmd);
    id<MTLBuffer> indices = [self buffer:address length:count * width offset:&offset];
    [self bindStages:MTLRenderStageVertex | MTLRenderStageFragment];
    [_render drawIndexedPrimitives:type indexCount:count indexType:indexType indexBuffer:indices indexBufferOffset:offset instanceCount:instances baseVertex:vertex baseInstance:base];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexType:(MTLIndexType)indexType indexBuffer:(uint64_t)address indexBufferLength:(NSUInteger)length indirectBuffer:(uint64_t)indirect {
    NSUInteger indexOffset = 0, argsOffset = 0;
    id<MTLBuffer> indices = [self buffer:address length:length offset:&indexOffset];
    id<MTLBuffer> args = [self buffer:indirect length:sizeof(MTLDrawIndexedPrimitivesIndirectArguments) offset:&argsOffset];
    [self bindStages:MTLRenderStageVertex | MTLRenderStageFragment];
    [_render drawIndexedPrimitives:type indexType:indexType indexBuffer:indices indexBufferOffset:indexOffset indirectBuffer:args indirectBufferOffset:argsOffset];
}
- (void)drawMeshThreadgroups:(MTLSize)groups threadsPerObjectThreadgroup:(MTLSize)object threadsPerMeshThreadgroup:(MTLSize)mesh {
    [self bindStages:MTLRenderStageObject | MTLRenderStageMesh | MTLRenderStageFragment];
    [_render drawMeshThreadgroups:groups threadsPerObjectThreadgroup:object threadsPerMeshThreadgroup:mesh];
}
- (void)drawMeshThreadgroupsWithIndirectBuffer:(uint64_t)address threadsPerObjectThreadgroup:(MTLSize)object threadsPerMeshThreadgroup:(MTLSize)mesh {
    NSUInteger offset = 0;
    id<MTLBuffer> args = [self buffer:address length:sizeof(MTLDispatchThreadgroupsIndirectArguments) offset:&offset];
    [self bindStages:MTLRenderStageObject | MTLRenderStageMesh | MTLRenderStageFragment];
    [_render drawMeshThreadgroupsWithIndirectBuffer:args indirectBufferOffset:offset threadsPerObjectThreadgroup:object threadsPerMeshThreadgroup:mesh];
}
@end

@implementation DmMtl3ReplayBuffer {
    DmMtl3BufferMap *_map;
}
- (instancetype)initWithQueue:(DmMtl3Queue *)queue map:(DmMtl3BufferMap *)map {
    if ((self = [super init])) {
        NSError *error = nil;
        _submission = [queue submissionWithError:&error]; checked(_submission != nil, error, _cmd);
        _map = map;
    }
    return self;
}
- (id)computeCommandEncoder { return [[DmMtl3ReplayCompute alloc] initWithSubmission:_submission map:_map]; }
- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor {
    return [[DmMtl3ReplayRender alloc] initWithSubmission:_submission map:_map descriptor:descriptor];
}
- (void)useResidencySet:(id<MTLResidencySet>)set { ENCODE([_submission useResidencySet:set error:&err]); }
@end
#endif
