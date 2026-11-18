// The direct NVN replay uses one logical compute/copy encoder and mutable stage
// tables. These objects implement that interface on native Metal 3 submissions.
#pragma once
#import "nvn_mtl3.h"

@interface DmMtl3ReplayTable : DmMtl3Bindings
- (instancetype)initWithMap:(DmMtl3BufferMap *)map;
- (void)setAddress:(MTLGPUAddress)address atIndex:(NSUInteger)index;
- (void)bindTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index;
- (void)bindSampler:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index;
@end

@interface DmMtl3ReplayBuffer : NSObject
- (instancetype)initWithQueue:(DmMtl3Queue *)queue map:(DmMtl3BufferMap *)map;
@property(nonatomic, readonly) DmMtl3Submission *submission;
- (id)computeCommandEncoder;
- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor;
- (void)useResidencySet:(id<MTLResidencySet>)set;
@end

// Direct texture bindings carry the object on Metal 3. Shader-visible handles
// in the guest's driver buffer always keep their GPU resource ID.
static inline void nvn_table_texture(id table, id<MTLTexture> texture, NSUInteger slot) {
#if DM_MAC15
    [(DmMtl3ReplayTable *)table bindTexture:texture atIndex:slot];
#else
    [(id<MTL4ArgumentTable>)table setTexture:texture.gpuResourceID atIndex:slot];
#endif
}
static inline void nvn_table_sampler(id table, id<MTLSamplerState> sampler, NSUInteger slot) {
#if DM_MAC15
    [(DmMtl3ReplayTable *)table bindSampler:sampler atIndex:slot];
#else
    [(id<MTL4ArgumentTable>)table setSamplerState:sampler.gpuResourceID atIndex:slot];
#endif
}
