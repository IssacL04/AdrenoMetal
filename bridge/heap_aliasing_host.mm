// SPDX-License-Identifier: MIT
// Adapted from none24smu/UniXNU-zeta tests/heap-aliasing-host.mm (MIT).
// Exercises the actual frontend and Rust bridge with a supplied Vulkan loader.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <pthread/qos.h>
#include "bridge/NativeMetalObjects.h"
#include "NativeBridgeMetalFrontend.h"
@interface NSObject (GpuCoreCount)
- (NSUInteger)gpuCoreCount;
@end
#define CHECK(x) do { if(!(x)) { std::fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);return 1; } } while(0)
int main(int argc,char **argv) {
 if(argc!=3)return 2;
 @autoreleasepool {
  id<MTLDevice> device=native_bridge_metal_open(argv[1],argv[2],0x7a657461,nullptr);
  CHECK(device && [(id)device gpuCoreCount]==6);
  // A full automatic heap must reuse a still-retained buffer after makeAliasable.
  MTLHeapDescriptor *hd=[MTLHeapDescriptor new];hd.size=16384;hd.storageMode=MTLStorageModeShared;
  id<MTLHeap> heap=[device newHeapWithDescriptor:hd];CHECK(heap);
  id<MTLBuffer> first,second,replacement;
  __weak id<MTLBuffer> releasedFirst;
  @autoreleasepool {
  first=[heap newBufferWithLength:8192 options:MTLResourceStorageModeShared];
  second=[heap newBufferWithLength:8192 options:MTLResourceStorageModeShared];
  CHECK(first && second && heap.usedSize==16384 && !first.isAliasable);
  CHECK(![heap newBufferWithLength:8192 options:MTLResourceStorageModeShared]);
  void *address=first.contents;std::memset(address,0x3a,8192);
  [first makeAliasable];[first makeAliasable];
  CHECK(first.isAliasable && heap.usedSize==8192);
  replacement=[heap newBufferWithLength:8192 options:MTLResourceStorageModeShared];
  CHECK(replacement && replacement.contents==address && replacement.heap==heap && !replacement.isAliasable);
  CHECK(((unsigned char *)replacement.contents)[0]==0x3a && heap.usedSize==16384);
  releasedFirst=first;first=nil;
  } // Drain helper-factory autoreleases before asserting actual destruction.
  CHECK(!releasedFirst && heap.usedSize==16384); // old owner cannot free the replacement
  second=nil;replacement=nil;CHECK(heap.usedSize==0);
  id<MTLBuffer> outside=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  CHECK(outside && !outside.isAliasable);[outside makeAliasable];CHECK(!outside.isAliasable);
  outside=nil;heap=nil;
  // Placement heaps start aliasable and expose the actual requested offset.
  hd.type=MTLHeapTypePlacement;hd.size=32768;
  heap=[device newHeapWithDescriptor:hd];CHECK(heap);
  first=[heap newBufferWithLength:4096 options:MTLResourceStorageModeShared offset:4096];
  CHECK(first && first.isAliasable && first.heapOffset==4096 && first.heap==heap);
  [first makeAliasable];CHECK(first.isAliasable);first=nil;heap=nil;
  // Retained texture views must share aliasability and return the same heap.
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
  td.storageMode=MTLStorageModePrivate;
  td.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsageRenderTarget|MTLTextureUsagePixelFormatView;
  MTLSizeAndAlign need=[device heapTextureSizeAndAlignWithDescriptor:td];CHECK(need.size && need.align);
  hd.type=MTLHeapTypeAutomatic;hd.storageMode=MTLStorageModePrivate;hd.size=2*((need.size+need.align-1)/need.align*need.align);
  heap=[device newHeapWithDescriptor:hd];CHECK(heap);
  NSMutableArray<id<MTLTexture>> *held=[NSMutableArray array];
  id<MTLTexture> original,view,reused;
  __weak id<MTLTexture> releasedOriginal,releasedView;
  NSUInteger before=0;
  @autoreleasepool {
  bool full=false;
  for(unsigned i=0;i<64;++i) {
   const NSUInteger occupied=heap.usedSize;
   id<MTLTexture> t=[heap newTextureWithDescriptor:td];
   CHECK(t);
   if(heap.usedSize==occupied) {
    // Upstream spills full automatic heaps into standalone textures.
    CHECK(!t.isAliasable);[t makeAliasable];CHECK(!t.isAliasable && heap.usedSize==occupied);
    full=true;break;
   }
   [held addObject:t];
  }
  CHECK(full && held.count>=2);
  original=held[0];
  view=[original newTextureViewWithPixelFormat:td.pixelFormat];
  CHECK(view && view.heap==heap && !view.isAliasable);
  before=heap.usedSize;
  [view makeAliasable];[view makeAliasable];
  CHECK(view.isAliasable && original.isAliasable && heap.usedSize<before);
  reused=[heap newTextureWithDescriptor:td];CHECK(reused && !reused.isAliasable && heap.usedSize==before);
  releasedOriginal=original;releasedView=view;
  [held removeObjectAtIndex:0];original=nil;view=nil;
  }
  CHECK(!releasedOriginal && !releasedView && heap.usedSize==before);
  for(unsigned i=0;i<32;++i) {
   [reused makeAliasable];
   @autoreleasepool {
    id<MTLTexture> next=[heap newTextureWithDescriptor:td];CHECK(next && heap.usedSize==before);
    reused=nil;CHECK(heap.usedSize==before);reused=next;
   }
  }
  reused=nil;[held removeAllObjects];CHECK(heap.usedSize==0);
  id<MTLBuffer> large=[device newBufferWithLength:16u<<20 options:MTLResourceStorageModeShared];CHECK(large);
  id<MTLCommandQueue> queue=[device newCommandQueue];CHECK(queue);
  id<MTLCommandBuffer> command=[queue commandBuffer];CHECK(command);
  __block qos_class_t completionClass=QOS_CLASS_UNSPECIFIED;
  [command addCompletedHandler:^(id<MTLCommandBuffer> done) {completionClass=qos_class_self();}];
  [command commit];[command waitUntilCompleted];
  CHECK(command.status==MTLCommandBufferStatusCompleted && completionClass==QOS_CLASS_USER_INTERACTIVE);
  struct StageRecord {uint64_t when,id;uint32_t sequence;uint16_t stage,arg;};
  static_assert(sizeof(StageRecord)==24);
  StageRecord records[8]={};uint64_t next=0,sites[32*12]={};
  const bool diagnostics=std::getenv("SHENG_DIAG")!=nullptr;
  CHECK((nmb_stage_ring_read(1,records,8,&next)>0)==diagnostics);
  CHECK((nmb_allocation_sites(sites,32)>0)==diagnostics);
  std::puts("PASS: completion handler QoS and opt-in runtime stage/allocation diagnostics");
  std::puts("PASS: frontend heap buffer/texture/view aliasing, retained-owner reuse, repeated release, placement offsets and non-heap controls; no pixel proof");
 }
 return 0;
}
