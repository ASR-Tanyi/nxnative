// Metal 3 execution primitives for the mac15 NVN renderer. Compile with ARC.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const DmMtl3ErrorDomain;
typedef NS_ENUM(NSInteger, DmMtl3Error) {
    DmMtl3InvalidArgument = 1, DmMtl3MissingAddress, DmMtl3InvalidState,
    DmMtl3AllocationFailed, DmMtl3GPUFailed, DmMtl3TimedOut,
};

// Thread-safe registry. Registration owns the buffer until explicit removal.
// Bindings resolved before removal keep their own strong reference, so in-flight
// work survives registry removal. Register every allocation, including arenas.
@interface DmMtl3BufferMap : NSObject
- (BOOL)addBuffer:(id<MTLBuffer>)buffer error:(NSError * _Nullable * _Nullable)error;
- (void)removeBuffer:(id<MTLBuffer>)buffer;
- (nullable id<MTLBuffer>)bufferAtAddress:(uint64_t)address length:(NSUInteger)length
                                  offset:(NSUInteger * _Nullable)offset error:(NSError * _Nullable * _Nullable)error;
@end

enum { DM_MTL3_BUFFERS = 31, DM_MTL3_TEXTURES = 128, DM_MTL3_SAMPLERS = 16 };
// Single encoding thread. Apply before each draw/dispatch, after any edits.
// Address 0 clears a buffer slot; nil clears a texture or sampler slot.
// This table owns the entire stage's slots (applying it clears unset slots too).
@interface DmMtl3Bindings : NSObject
- (BOOL)setAddress:(uint64_t)address length:(NSUInteger)length atIndex:(NSUInteger)index
               map:(DmMtl3BufferMap *)map error:(NSError * _Nullable * _Nullable)error;
- (BOOL)setTexture:(nullable id<MTLTexture>)texture atIndex:(NSUInteger)index error:(NSError * _Nullable * _Nullable)error;
- (BOOL)setSamplerState:(nullable id<MTLSamplerState>)sampler atIndex:(NSUInteger)index error:(NSError * _Nullable * _Nullable)error;
- (void)clear;
@end

@class DmMtl3Submission;
typedef void (^DmMtl3Completion)(uint64_t serial, MTLCommandBufferStatus status,
                               NSError * _Nullable error, CFTimeInterval gpuStart, CFTimeInterval gpuEnd);

// Creation and commit may be called from different threads. Each submission is
// encoded on one thread. Commit order, not creation order, defines GPU order.
// Fences conservatively order every pass, including untracked/aliased resources.
// A GPU failure latches on the queue: subsequent submissions fail explicitly.
@interface DmMtl3Queue : NSObject
- (nullable instancetype)initWithCommandQueue:(id<MTLCommandQueue>)queue error:(NSError * _Nullable * _Nullable)error;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError * _Nullable * _Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
- (nullable DmMtl3Submission *)submissionWithError:(NSError * _Nullable * _Nullable)error;
@end

@interface DmMtl3Submission : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) uint64_t serial;   // 0 until committed
// Only one encoder may be open. End it through this object, never directly on
// the returned encoder. State/draw/copy calls use the native Metal 3 encoders.
- (nullable id<MTLComputeCommandEncoder>)beginCompute:(NSError * _Nullable * _Nullable)error;
- (nullable id<MTLRenderCommandEncoder>)beginRender:(MTLRenderPassDescriptor *)pass error:(NSError * _Nullable * _Nullable)error;
- (nullable id<MTLBlitCommandEncoder>)beginBlit:(NSError * _Nullable * _Nullable)error;
- (BOOL)endEncoding:(NSError * _Nullable * _Nullable)error;
- (BOOL)applyComputeBindings:(DmMtl3Bindings *)bindings error:(NSError * _Nullable * _Nullable)error;
- (BOOL)applyRenderBindings:(DmMtl3Bindings *)bindings stages:(MTLRenderStages)stages error:(NSError * _Nullable * _Nullable)error;
// Resources inside an argument buffer are not discovered by Metal. Declare
// every indirectly used resource per pass; retain indirect samplers separately.
- (BOOL)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage error:(NSError * _Nullable * _Nullable)error;
- (BOOL)useResidencySet:(id<MTLResidencySet>)set error:(NSError * _Nullable * _Nullable)error;
- (BOOL)presentDrawable:(id<MTLDrawable>)drawable minimumDuration:(CFTimeInterval)duration error:(NSError * _Nullable * _Nullable)error;
- (BOOL)keepAlive:(id)object error:(NSError * _Nullable * _Nullable)error;
- (BOOL)computeBarrier:(NSError * _Nullable * _Nullable)error;
// Events require no active encoder. They are real GPU waits/signals, not CPU
// completion counters. The caller must ensure every wait has a producer.
- (BOOL)waitForEvent:(id<MTLEvent>)event value:(uint64_t)value error:(NSError * _Nullable * _Nullable)error;
- (BOOL)signalEvent:(id<MTLEvent>)event value:(uint64_t)value error:(NSError * _Nullable * _Nullable)error;
// Handlers run on Metal's completion thread; do not wait for this submission
// inside a handler. waitUntilCompleted also waits for these handlers to return.
- (BOOL)addCompletedHandler:(DmMtl3Completion)handler error:(NSError * _Nullable * _Nullable)error;
- (BOOL)commit:(NSError * _Nullable * _Nullable)error;   // ends an open pass; cannot commit twice
- (BOOL)waitUntilCompleted:(NSTimeInterval)timeout error:(NSError * _Nullable * _Nullable)error;
- (BOOL)cancel:(NSError * _Nullable * _Nullable)error;   // only before commit; does not submit work
@end
NS_ASSUME_NONNULL_END
