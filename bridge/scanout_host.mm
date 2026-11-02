// SPDX-License-Identifier: MIT
// Host check of the GPU scanout (GpuScanoutPresenter.h): a half-float frame converted by the compute kernel stores exactly the bytes of the
// display driver's table (NativeHalfCodes.h), for linear and encoded frames, with padded rows on both sides; a BGRA frame is copied with
// its alpha opaque.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <cassert>
#include "../NativeBridgeMetalFrontend.h"
#include "../GpuScanoutPresenter.h"
#include "../GpuScanoutClient.h"

// Shader priming's progress lives in the plugin (PrimeShaders.h); the frontend's telemetry reads it.
extern "C" {volatile uint32_t native_prime_compiling, native_prime_libraries_done, native_prime_libraries_total, native_prime_made, native_prime_rate;}

static void *pages(size_t bytes) {
    void *p = nullptr;
    return posix_memalign(&p, (size_t)getpagesize(), bytes) ? nullptr : p;
}

#ifdef NGP_TIMING_API
static void clientProtocol(id<MTLDevice> device,void *out,size_t outBytes,void *in,size_t inBytes,
                           uint32_t width,uint32_t height,size_t outStride,size_t inStride) {
    struct Peer {
        NGPMode mode;
        NGPSwap swap;
        uint64_t address;
        unsigned timed=0,legacy=0,markers=0;
        uint32_t reject=0;
    };
    for(uint32_t rejection:{0u,0xe00002c2u,0xe00002c7u,0xe00002bcu}) {
        Peer peer={{NGP_VERSION,NGP_BGRX8888,width,height,outStride,outBytes},
                   {1,(uint64_t)(uintptr_t)in,inBytes,inStride,width,height,NGP_BGRX8888,0},(uint64_t)(uintptr_t)out};
        peer.reject=rejection;
        gpuscanout::Transport transport={&peer,
            [](void *context,uint32_t method,const void *input,size_t size,void *output,size_t)->int {
                auto &p=*static_cast<Peer *>(context);
                switch(method) {
                case NGP_METHOD_MODE:memcpy(output,&p.mode,sizeof p.mode);return 0;
                case NGP_METHOD_OVERLAY:*static_cast<NGPOverlay *>(output)={};return 0;
                case NGP_METHOD_WAIT_SWAP:memcpy(output,&p.swap,sizeof p.swap);++p.swap.sequence;return 0;
                case NGP_METHOD_COMPLETE_SWAP:
                    if(size==sizeof(NGPCompleteTimed)) {
                        ++p.timed;const auto &q=*static_cast<const NGPCompleteTimed *>(input);
                        assert(q.done.status==0 && !q.done.reserved && !q.reserved);
                        return (int)p.reject;
                    }
                    assert(size==sizeof(NGPComplete));++p.legacy;return 0;
                default:assert(false);return -1;
                }
            },
            [](void *context,uint64_t *address,uint64_t *length)->int {
                auto &p=*static_cast<Peer *>(context);*address=p.address;*length=p.mode.bytes;return 0;
            },
            [](void *context,uint32_t value) {if(value==0x6730 || value==0x6731)++static_cast<Peer *>(context)->markers;}};
        gpuscanout::Stats stats={};stats.verified=4;
        gpuscanout::Client client;
        assert(client.open(device,transport,&stats));
        if(rejection==0xe00002bcu) {
            assert(!client.serveOne(1) && peer.timed==1 && !peer.legacy && stats.failures==1);
        } else {
            assert(client.serveOne(1) && client.serveOne(1) && stats.frames==2 && !stats.failures);
            assert(peer.timed==(rejection?1u:2u) && peer.legacy==(rejection?2u:0u));
            assert(peer.markers==2);
        }
    }
}
#endif

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) return 2;
        unsetenv("SHENG_DIAG");
        id<MTLDevice> device = native_bridge_metal_open(argv[1], argv[2], 0x6e6d62, nullptr);
        if (!device) {std::printf("FAIL device\n"); return 1;}
        const size_t page = (size_t)getpagesize();
        const uint32_t width = 1003, height = 517;
        const size_t outStride = width * 4 + 96, outBytes = (outStride * height + page - 1) & ~(page - 1);
        const size_t inStride = width * 8 + 64, inBytes = (inStride * height + page - 1) & ~(page - 1);
        uint8_t *out = (uint8_t *)pages(outBytes), *in = (uint8_t *)pages(inBytes);
        if (!out || !in) return 1;
        srandom(7);
        int failed = 0;
        for (uint32_t bandRows : {0u, 73u, height}) {
#ifndef NGP_OVERLAY_API
        if (bandRows) continue;
#endif
        const uint32_t bandFirst = bandRows == height ? 0 : 17;
        gpupresent::Presenter presenter(device, {out, outBytes, outStride, width, height, bandFirst, bandRows});
        if (!presenter.ready()) {std::printf("FAIL presenter\n"); return 1;}
        for (uint32_t format : {(uint32_t)NGP_RGBA16F_LINEAR, (uint32_t)NGP_RGBA16F_ENCODED}) {
            for (size_t i = 0; i < inBytes / 2; ++i) {
                // every pattern class: random bits, small positives, around 1.0, negatives, infinities and NaNs
                uint16_t v = (uint16_t)random();
                if (i % 7 == 0) v = (uint16_t)(0x3c00 - (random() & 0x3ff));
                ((uint16_t *)in)[i] = v;
            }
            memset(out, 0x5a, outBytes);
            const uint64_t began=gpupresent::nowUs();
            const gpupresent::Result r = presenter.present({in, inBytes, inStride, width, height, 0, format});
            const auto &t=presenter.timing();
            assert(uint64_t(t.encodeUs)+t.submitUs+t.waitUs<=gpupresent::nowUs()-began);
            if (r != gpupresent::kOk) {std::printf("FAIL format %u: result %d\n", format, (int)r); ++failed; continue;}
            uint64_t wrong = 0;
            for (uint32_t y = 0; y < height; ++y) {
                const uint16_t *src = (const uint16_t *)(in + y * inStride);
                const uint32_t *dst = (const uint32_t *)(out + y * outStride);
                for (uint32_t x = 0; x < width; ++x) {
                    const bool encoded = format == NGP_RGBA16F_ENCODED;
                    const uint32_t want = y >= bandFirst && y - bandFirst < bandRows ? 0x5a5a5a5au :
                                          0xff000000u | (uint32_t)native_half::code(src[4 * x], encoded) << 16 |
                                          (uint32_t)native_half::code(src[4 * x + 1], encoded) << 8 | native_half::code(src[4 * x + 2], encoded);
                    if (dst[x] != want && wrong++ < 4) std::printf("  format %u (%u,%u): %08x want %08x\n", format, x, y, dst[x], want);
                }
                // the padding after each row is left alone
                for (size_t b = width * 4; b < outStride; ++b) if (out[y * outStride + b] != 0x5a && wrong++ < 4) std::printf("  padding written\n");
            }
            if (wrong) {std::printf("FAIL format %u: %llu wrong\n", format, (unsigned long long)wrong); ++failed;}
        }
        // BGRA is copied with its alpha made opaque (the display blends the scanout by its alpha), every row, the padding left alone
        for (size_t i = 0; i < inBytes; ++i) in[i] = (uint8_t)random();
        memset(out, 0x5a, outBytes);
        if (presenter.present({in, inBytes, width * 4 + 64, width, height, 0, NGP_BGRX8888}) != gpupresent::kOk) {std::printf("FAIL BGRA copy\n"); ++failed;}
        uint64_t bgraWrong = 0;
        for (uint32_t y = 0; y < height; ++y) {
            const uint32_t *src = (const uint32_t *)(in + y * (width * 4 + 64)), *dst = (const uint32_t *)(out + y * outStride);
            for (uint32_t x = 0; x < width; ++x) {
                const uint32_t want = y >= bandFirst && y - bandFirst < bandRows ? 0x5a5a5a5au : src[x] | 0xff000000u;
                if (dst[x] != want && bgraWrong++ < 4) std::printf("  BGRA (%u,%u): %08x want %08x\n", x, y, dst[x], want);
            }
            for (size_t b = width * 4; b < outStride; ++b) if (out[y * outStride + b] != 0x5a && bgraWrong++ < 4) std::printf("  BGRA padding written\n");
        }
        if (bgraWrong) {std::printf("FAIL BGRA copy: %llu wrong\n", (unsigned long long)bgraWrong); ++failed;}
        if (presenter.present({in, inBytes, inStride, width, height, 0, 77}) != gpupresent::kBadFrame) {std::printf("FAIL unknown format taken\n"); ++failed;}
        const auto &invalid=presenter.timing();
        assert(!invalid.encodeUs && !invalid.submitUs && !invalid.waitUs && invalid.gpuUs==UINT32_MAX);
        }
#ifdef NGP_TIMING_API
        clientProtocol(device,out,outBytes,in,inBytes,width,height,outStride,width*4+64);
#endif
        if (failed) return 1;
        std::printf("PASS: half-float frames convert to the display driver's bytes on the GPU (linear and encoded), BGRA copies opaque, diagnostic bands and padding preserved, unknown formats refused\n");
    }
    return 0;
}
