#import "nvn_mtl3.h"
#import <dispatch/dispatch.h>
#include "nvn_mtl3_range.h"
#include <math.h>

NSString *const DmMtl3ErrorDomain = @"org.nxnative.metal3";
static NSError *m3_error(DmMtl3Error code, NSString *message) {
    return [NSError errorWithDomain:DmMtl3ErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}
static BOOL m3_fail(NSError **error, DmMtl3Error code, NSString *message) {
    if (error) *error = m3_error(code, message);
    return NO;
}

@implementation DmMtl3BufferMap {
    NSLock *_lock;
    NSMutableArray<id<MTLBuffer>> *_buffers;
    NSMutableData *_ranges;
}
- (instancetype)init {
    if ((self = [super init])) { _lock = [NSLock new]; _buffers = [NSMutableArray new]; _ranges = [NSMutableData new]; }
    return self;
}
- (BOOL)addBuffer:(id<MTLBuffer>)buffer error:(NSError **)error {
    if (!buffer || !nvn_mtl3_range_valid(buffer.gpuAddress, buffer.length))
        return m3_fail(error, DmMtl3InvalidArgument, @"buffer has an empty or overflowing GPU range");
    [_lock lock];
    if ([_buffers indexOfObjectIdenticalTo:buffer] != NSNotFound) { [_lock unlock]; return YES; }
    const nvn_mtl3_range *ranges = _ranges.bytes;
    NSUInteger lo = 0, hi = _buffers.count;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (ranges[mid].lo <= buffer.gpuAddress) lo = mid + 1; else hi = mid;
    }
    nvn_mtl3_range range = {buffer.gpuAddress, buffer.gpuAddress + buffer.length, 0};
    [_buffers insertObject:buffer atIndex:lo];
    [_ranges replaceBytesInRange:NSMakeRange(lo * sizeof range, 0) withBytes:&range length:sizeof range];
    nvn_mtl3_range_index(_ranges.mutableBytes, _buffers.count);
    [_lock unlock];
    return YES;
}
- (void)removeBuffer:(id<MTLBuffer>)buffer {
    [_lock lock];
    NSUInteger i = [_buffers indexOfObjectIdenticalTo:buffer];
    if (i != NSNotFound) {
        [_buffers removeObjectAtIndex:i];
        [_ranges replaceBytesInRange:NSMakeRange(i * sizeof(nvn_mtl3_range), sizeof(nvn_mtl3_range)) withBytes:NULL length:0];
        nvn_mtl3_range_index(_ranges.mutableBytes, _buffers.count);
    }
    [_lock unlock];
}
- (id<MTLBuffer>)bufferAtAddress:(uint64_t)address length:(NSUInteger)length offset:(NSUInteger *)offset error:(NSError **)error {
    [_lock lock];
    const nvn_mtl3_range *ranges = _ranges.bytes;
    size_t i = nvn_mtl3_range_find(ranges, _buffers.count, address, length);
    id<MTLBuffer> buffer = nil;
    if (i != SIZE_MAX) { buffer = _buffers[i]; if (offset) *offset = (NSUInteger)(address - ranges[i].lo); }
    [_lock unlock];
    if (!buffer) m3_fail(error, DmMtl3MissingAddress,
                        [NSString stringWithFormat:@"GPU range %#llx + %lu has no registered buffer",
                         (unsigned long long)address, (unsigned long)length]);
    return buffer;
}
@end

@interface DmMtl3Bindings ()
- (BOOL)validateDevice:(id<MTLDevice>)device error:(NSError **)error;
- (void)applyCompute:(id<MTLComputeCommandEncoder>)encoder keep:(NSHashTable *)keep;
- (void)applyRender:(id<MTLRenderCommandEncoder>)encoder stages:(MTLRenderStages)stages keep:(NSHashTable *)keep;
@end

@implementation DmMtl3Bindings {
    id<MTLBuffer> _buffers[DM_MTL3_BUFFERS];
    NSUInteger _offsets[DM_MTL3_BUFFERS];
    id<MTLTexture> _textures[DM_MTL3_TEXTURES];
    id<MTLSamplerState> _samplers[DM_MTL3_SAMPLERS];
}
- (BOOL)setAddress:(uint64_t)address length:(NSUInteger)length atIndex:(NSUInteger)index map:(DmMtl3BufferMap *)map error:(NSError **)error {
    if (index >= DM_MTL3_BUFFERS) return m3_fail(error, DmMtl3InvalidArgument, @"buffer binding index exceeds 30");
    id<MTLBuffer> buffer = nil; NSUInteger offset = 0;
    if (address) {
        buffer = [map bufferAtAddress:address length:length offset:&offset error:error];
        if (!buffer) return NO;   // failed writes preserve the previous binding
    }
    _buffers[index] = buffer; _offsets[index] = offset;
    return YES;
}
- (BOOL)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index error:(NSError **)error {
    if (index >= DM_MTL3_TEXTURES) return m3_fail(error, DmMtl3InvalidArgument, @"texture binding index exceeds 127");
    _textures[index] = texture; return YES;
}
- (BOOL)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index error:(NSError **)error {
    if (index >= DM_MTL3_SAMPLERS) return m3_fail(error, DmMtl3InvalidArgument, @"sampler binding index exceeds 15");
    _samplers[index] = sampler; return YES;
}
- (void)clear {
    for (NSUInteger i = 0; i < DM_MTL3_BUFFERS; i++) { _buffers[i] = nil; _offsets[i] = 0; }
    for (NSUInteger i = 0; i < DM_MTL3_TEXTURES; i++) _textures[i] = nil;
    for (NSUInteger i = 0; i < DM_MTL3_SAMPLERS; i++) _samplers[i] = nil;
}
- (BOOL)validateDevice:(id<MTLDevice>)device error:(NSError **)error {
    for (NSUInteger i = 0; i < DM_MTL3_BUFFERS; i++) if (_buffers[i] && _buffers[i].device != device)
        return m3_fail(error, DmMtl3InvalidArgument, @"buffer belongs to another Metal device");
    for (NSUInteger i = 0; i < DM_MTL3_TEXTURES; i++) if (_textures[i] && _textures[i].device != device)
        return m3_fail(error, DmMtl3InvalidArgument, @"texture belongs to another Metal device");
    for (NSUInteger i = 0; i < DM_MTL3_SAMPLERS; i++) if (_samplers[i] && _samplers[i].device != device)
        return m3_fail(error, DmMtl3InvalidArgument, @"sampler belongs to another Metal device");
    return YES;
}
// Metal borrows these arrays for the duration of set*:. The stage table owns
// the objects and the submission additionally retains each one it encodes.
- (void)snapshotBuffers:(id<MTLBuffer> __unsafe_unretained *)buffers
               textures:(id<MTLTexture> __unsafe_unretained *)textures
               samplers:(id<MTLSamplerState> __unsafe_unretained *)samplers keep:(NSHashTable *)keep {
    for (NSUInteger i = 0; i < DM_MTL3_BUFFERS; i++) {
        buffers[i] = _buffers[i]; if (buffers[i]) [keep addObject:buffers[i]];
    }
    for (NSUInteger i = 0; i < DM_MTL3_TEXTURES; i++) {
        textures[i] = _textures[i]; if (textures[i]) [keep addObject:textures[i]];
    }
    for (NSUInteger i = 0; i < DM_MTL3_SAMPLERS; i++) {
        samplers[i] = _samplers[i]; if (samplers[i]) [keep addObject:samplers[i]];
    }
}
- (void)applyCompute:(id<MTLComputeCommandEncoder>)encoder keep:(NSHashTable *)keep {
    __unsafe_unretained id<MTLBuffer> buffers[DM_MTL3_BUFFERS];
    __unsafe_unretained id<MTLTexture> textures[DM_MTL3_TEXTURES];
    __unsafe_unretained id<MTLSamplerState> samplers[DM_MTL3_SAMPLERS];
    [self snapshotBuffers:buffers textures:textures samplers:samplers keep:keep];
    [encoder setBuffers:buffers offsets:_offsets withRange:NSMakeRange(0, DM_MTL3_BUFFERS)];
    [encoder setTextures:textures withRange:NSMakeRange(0, DM_MTL3_TEXTURES)];
    [encoder setSamplerStates:samplers withRange:NSMakeRange(0, DM_MTL3_SAMPLERS)];
}
- (void)applyRender:(id<MTLRenderCommandEncoder>)encoder stages:(MTLRenderStages)stages keep:(NSHashTable *)keep {
    __unsafe_unretained id<MTLBuffer> buffers[DM_MTL3_BUFFERS];
    __unsafe_unretained id<MTLTexture> textures[DM_MTL3_TEXTURES];
    __unsafe_unretained id<MTLSamplerState> samplers[DM_MTL3_SAMPLERS];
    [self snapshotBuffers:buffers textures:textures samplers:samplers keep:keep];
    NSRange br = NSMakeRange(0, DM_MTL3_BUFFERS), tr = NSMakeRange(0, DM_MTL3_TEXTURES), sr = NSMakeRange(0, DM_MTL3_SAMPLERS);
    if (stages & MTLRenderStageVertex) {
        [encoder setVertexBuffers:buffers offsets:_offsets withRange:br];
        [encoder setVertexTextures:textures withRange:tr];
        [encoder setVertexSamplerStates:samplers withRange:sr];
    }
    if (stages & MTLRenderStageFragment) {
        [encoder setFragmentBuffers:buffers offsets:_offsets withRange:br];
        [encoder setFragmentTextures:textures withRange:tr];
        [encoder setFragmentSamplerStates:samplers withRange:sr];
    }
    if (stages & MTLRenderStageObject) {
        [encoder setObjectBuffers:buffers offsets:_offsets withRange:br];
        [encoder setObjectTextures:textures withRange:tr];
        [encoder setObjectSamplerStates:samplers withRange:sr];
    }
    if (stages & MTLRenderStageMesh) {
        [encoder setMeshBuffers:buffers offsets:_offsets withRange:br];
        [encoder setMeshTextures:textures withRange:tr];
        [encoder setMeshSamplerStates:samplers withRange:sr];
    }
}
@end

@interface DmMtl3Queue ()
- (BOOL)commitSubmission:(DmMtl3Submission *)submission error:(NSError **)error;
- (void)completedWithError:(NSError *)error;
@end
@interface DmMtl3Submission ()
- (instancetype)initWithOwner:(DmMtl3Queue *)owner command:(id<MTLCommandBuffer>)command fence:(id<MTLFence>)fence;
- (void)submitWithSerial:(uint64_t)serial;
@end

@implementation DmMtl3Queue {
    id<MTLCommandQueue> _queue;
    id<MTLFence> _fence;
    NSError *_failure;
    uint64_t _serial;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error {
    return [self initWithCommandQueue:[device newCommandQueue] error:error];
}
- (instancetype)initWithCommandQueue:(id<MTLCommandQueue>)queue error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _queue = queue; _fence = [queue.device newFence];
    if (!_queue || !_fence) { m3_fail(error, DmMtl3AllocationFailed, @"cannot create the Metal 3 queue or fence"); return nil; }
    // Seed the fence before any consumer. Metal evaluates fence dependencies at
    // commit, so independently encoded submissions can later commit in any order.
    // Each pass waits first and updates last: never update then wait in one pass.
    id<MTLCommandBuffer> seed = [_queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [seed blitCommandEncoder];
    if (!encoder) { m3_fail(error, DmMtl3AllocationFailed, @"cannot initialize the Metal 3 queue fence"); return nil; }
    [encoder updateFence:_fence]; [encoder endEncoding];
    __weak DmMtl3Queue *owner = self;
    [seed addCompletedHandler:^(id<MTLCommandBuffer> command) {
        if (command.status == MTLCommandBufferStatusError)
            [owner completedWithError:command.error ?: m3_error(DmMtl3GPUFailed, @"queue fence initialization failed")];
    }];
    [seed commit];
    return self;
}
- (DmMtl3Submission *)submissionWithError:(NSError **)error {
    @synchronized (self) {
        if (_failure) { if (error) *error = _failure; return nil; }
    }
    // Allocation can wait for an in-flight buffer. Completion must be able to
    // acquire our lock while that happens, including on a GPU error.
    id<MTLCommandBuffer> command = [_queue commandBuffer];
    if (!command) { m3_fail(error, DmMtl3AllocationFailed, @"cannot allocate a command buffer"); return nil; }
    @synchronized (self) {
        if (_failure) { if (error) *error = _failure; return nil; }
        return [[DmMtl3Submission alloc] initWithOwner:self command:command fence:_fence];
    }
}
- (BOOL)commitSubmission:(DmMtl3Submission *)submission error:(NSError **)error {
    @synchronized (self) {
        if (_failure) { if (error) *error = _failure; return NO; }
        [submission submitWithSerial:++_serial];
        return YES;
    }
}
- (void)completedWithError:(NSError *)error {
    if (!error) return;
    @synchronized (self) { if (!_failure) _failure = error; }
}
@end

@implementation DmMtl3Submission {
    DmMtl3Queue *_owner;
    id<MTLCommandBuffer> _command;
    id<MTLFence> _fence;
    MTLRenderStages _fenceStages;
    id<MTLCommandEncoder> _encoder;
    int _kind;   // 0 none, 1 compute, 2 render, 3 blit
    int _state;  // 0 encoding, 1 committed, 2 cancelled
    uint64_t _serial;
    NSHashTable *_keep;
    NSMutableArray *_handlers;
    dispatch_group_t _done;
}
- (instancetype)initWithOwner:(DmMtl3Queue *)owner command:(id<MTLCommandBuffer>)command fence:(id<MTLFence>)fence {
    if ((self = [super init])) {
        _owner = owner; _command = command; _fence = fence;
        _fenceStages = MTLRenderStageVertex | MTLRenderStageFragment;
        if ([command.device supportsFamily:MTLGPUFamilyApple7]) _fenceStages |= MTLRenderStageObject | MTLRenderStageMesh;
        _keep = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
        _handlers = [NSMutableArray new]; _done = dispatch_group_create();
    }
    return self;
}
- (uint64_t)serial { return _serial; }
- (BOOL)encoding:(NSError **)error {
    return !_state || m3_fail(error, DmMtl3InvalidState, @"submission is already committed or cancelled");
}
- (BOOL)outsidePass:(NSError **)error {
    if (![self encoding:error]) return NO;
    return !_encoder || m3_fail(error, DmMtl3InvalidState, @"end the active encoder first");
}
- (id<MTLComputeCommandEncoder>)beginCompute:(NSError **)error {
    if (![self outsidePass:error]) return nil;
    id<MTLComputeCommandEncoder> encoder = [_command computeCommandEncoder];
    if (!encoder) { m3_fail(error, DmMtl3AllocationFailed, @"cannot create compute encoder"); return nil; }
    [encoder waitForFence:_fence]; _encoder = encoder; _kind = 1;
    return encoder;
}
- (id<MTLRenderCommandEncoder>)beginRender:(MTLRenderPassDescriptor *)pass error:(NSError **)error {
    if (![self outsidePass:error]) return nil;
    if (!pass) { m3_fail(error, DmMtl3InvalidArgument, @"render pass is nil"); return nil; }
    id<MTLRenderCommandEncoder> encoder = [_command renderCommandEncoderWithDescriptor:pass];
    if (!encoder) { m3_fail(error, DmMtl3AllocationFailed, @"cannot create render encoder"); return nil; }
    [encoder waitForFence:_fence beforeStages:_fenceStages];
    _encoder = encoder; _kind = 2;
    return encoder;
}
- (id<MTLBlitCommandEncoder>)beginBlit:(NSError **)error {
    if (![self outsidePass:error]) return nil;
    id<MTLBlitCommandEncoder> encoder = [_command blitCommandEncoder];
    if (!encoder) { m3_fail(error, DmMtl3AllocationFailed, @"cannot create blit encoder"); return nil; }
    [encoder waitForFence:_fence]; _encoder = encoder; _kind = 3;
    return encoder;
}
- (BOOL)endEncoding:(NSError **)error {
    if (![self encoding:error]) return NO;
    if (_kind == 1) [(id<MTLComputeCommandEncoder>)_encoder updateFence:_fence];
    else if (_kind == 2) [(id<MTLRenderCommandEncoder>)_encoder updateFence:_fence afterStages:_fenceStages];
    else if (_kind == 3) [(id<MTLBlitCommandEncoder>)_encoder updateFence:_fence];
    [_encoder endEncoding]; _encoder = nil; _kind = 0;
    return YES;
}
- (BOOL)applyComputeBindings:(DmMtl3Bindings *)bindings error:(NSError **)error {
    if (![self encoding:error]) return NO;
    if (_kind != 1 || !bindings) return m3_fail(error, DmMtl3InvalidState, @"compute bindings require an active compute encoder and table");
    if (![bindings validateDevice:_command.device error:error]) return NO;
    [bindings applyCompute:(id)_encoder keep:_keep];
    return YES;
}
- (BOOL)applyRenderBindings:(DmMtl3Bindings *)bindings stages:(MTLRenderStages)stages error:(NSError **)error {
    if (![self encoding:error]) return NO;
    if (_kind != 2 || !bindings) return m3_fail(error, DmMtl3InvalidState, @"render bindings require an active render encoder and table");
    if (!stages || (stages & ~(MTLRenderStageVertex | MTLRenderStageFragment | MTLRenderStageObject | MTLRenderStageMesh)))
        return m3_fail(error, DmMtl3InvalidArgument, @"unsupported Metal 3 render binding stages");
    if (![bindings validateDevice:_command.device error:error]) return NO;
    [bindings applyRender:(id)_encoder stages:stages keep:_keep];
    return YES;
}
- (BOOL)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage error:(NSError **)error {
    if (![self encoding:error]) return NO;
    if (!resource || resource.device != _command.device || !usage || (usage & ~(MTLResourceUsageRead | MTLResourceUsageWrite)))
        return m3_fail(error, DmMtl3InvalidArgument, @"invalid indirect resource, device or usage");
    if (_kind == 1) [(id<MTLComputeCommandEncoder>)_encoder useResource:resource usage:usage];
    else if (_kind == 2) [(id<MTLRenderCommandEncoder>)_encoder useResource:resource usage:usage stages:MTLRenderStageVertex | MTLRenderStageFragment];
    else return m3_fail(error, DmMtl3InvalidState, @"indirect resources require an active compute or render encoder");
    [_keep addObject:resource];
    return YES;
}
- (BOOL)useResidencySet:(id<MTLResidencySet>)set error:(NSError **)error {
    if (![self outsidePass:error]) return NO;
    if (!set || set.device != _command.device) return m3_fail(error, DmMtl3InvalidArgument, @"invalid residency set or device");
    [_command useResidencySet:set];
    return YES;
}
- (BOOL)presentDrawable:(id<MTLDrawable>)drawable minimumDuration:(CFTimeInterval)duration error:(NSError **)error {
    if (![self outsidePass:error]) return NO;
    if (!drawable || !isfinite(duration) || duration < 0) return m3_fail(error, DmMtl3InvalidArgument, @"invalid drawable or duration");
    if (duration > 0) [_command presentDrawable:drawable afterMinimumDuration:duration];
    else [_command presentDrawable:drawable];
    return YES;
}
- (BOOL)keepAlive:(id)object error:(NSError **)error {
    if (![self encoding:error]) return NO;
    if (!object) return m3_fail(error, DmMtl3InvalidArgument, @"cannot retain a nil object");
    [_keep addObject:object]; return YES;
}
- (BOOL)computeBarrier:(NSError **)error {
    if (![self encoding:error]) return NO;
    if (_kind != 1) return m3_fail(error, DmMtl3InvalidState, @"compute barrier requires an active compute encoder");
    [(id<MTLComputeCommandEncoder>)_encoder memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures];
    return YES;
}
- (BOOL)canEncodeEvent:(id<MTLEvent>)event error:(NSError **)error {
    if (![self outsidePass:error]) return NO;
    if (!event) return m3_fail(error, DmMtl3InvalidArgument, @"missing Metal event");
    // MTLEvent.device can be nil for a shared event. Shared events can also
    // be used on another device when their creator is reported.
    id<MTLDevice> device = event.device;
    if (device && device != _command.device && ![event conformsToProtocol:@protocol(MTLSharedEvent)])
        return m3_fail(error, DmMtl3InvalidArgument, @"device-local Metal event belongs to another device");
    return YES;
}
- (BOOL)waitForEvent:(id<MTLEvent>)event value:(uint64_t)value error:(NSError **)error {
    if (![self canEncodeEvent:event error:error]) return NO;
    [_command encodeWaitForEvent:event value:value]; [_keep addObject:event]; return YES;
}
- (BOOL)signalEvent:(id<MTLEvent>)event value:(uint64_t)value error:(NSError **)error {
    if (![self canEncodeEvent:event error:error]) return NO;
    [_command encodeSignalEvent:event value:value]; [_keep addObject:event]; return YES;
}
- (BOOL)addCompletedHandler:(DmMtl3Completion)handler error:(NSError **)error {
    if (![self encoding:error]) return NO;
    if (!handler) return m3_fail(error, DmMtl3InvalidArgument, @"completion handler is nil");
    [_handlers addObject:[handler copy]]; return YES;
}
- (BOOL)commit:(NSError **)error {
    if (![self endEncoding:error]) return NO;
    return [_owner commitSubmission:self error:error];
}
- (void)submitWithSerial:(uint64_t)serial {
    _state = 1; _serial = serial;
    // Transfer the set itself, avoiding an autoreleased snapshot that could
    // keep resources alive until the caller's frame-long pool drains.
    NSHashTable *held = _keep; _keep = nil;
    NSArray *handlers = [_handlers copy]; [_handlers removeAllObjects];
    DmMtl3Queue *owner = _owner; dispatch_group_t done = _done;
    dispatch_group_enter(done);
    [_command addCompletedHandler:^(id<MTLCommandBuffer> command) {
        NSError *error = command.error;
        if (!error && command.status != MTLCommandBufferStatusCompleted)
            error = m3_error(DmMtl3GPUFailed, @"command buffer did not complete successfully");
        [owner completedWithError:error];
        for (DmMtl3Completion handler in handlers) handler(serial, command.status, error, command.GPUStartTime, command.GPUEndTime);
        [held removeAllObjects];   // indirect resources live through GPU completion, not just encoding
        dispatch_group_leave(done);
    }];
    [_command commit];
}
- (BOOL)waitUntilCompleted:(NSTimeInterval)timeout error:(NSError **)error {
    if (_state != 1) return m3_fail(error, DmMtl3InvalidState, @"only a committed submission can be waited on");
    if (!isfinite(timeout) || timeout < 0 || timeout >= (double)INT64_MAX / NSEC_PER_SEC)
        return m3_fail(error, DmMtl3InvalidArgument, @"invalid completion timeout");
    if (dispatch_group_wait(_done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))))
        return m3_fail(error, DmMtl3TimedOut, @"GPU completion timed out (the submitted work is still in flight)");
    if (_command.status != MTLCommandBufferStatusCompleted) {
        if (error) *error = _command.error ?: m3_error(DmMtl3GPUFailed, @"command buffer failed");
        return NO;
    }
    return YES;
}
- (BOOL)cancel:(NSError **)error {
    if (![self endEncoding:error]) return NO;
    _state = 2; _command = nil; [_keep removeAllObjects]; [_handlers removeAllObjects];
    return YES;
}
@end
