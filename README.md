# AdrenoMetal

Metal frontend through metal2vulkan and Turnip.

The frontend uses metal2vulkan and Turnip with the kernel GPU interface and selected OS ABI. GPU composition has been verified on sheng with A740.

Build and interface details: [documentation](https://unixnu.com/drivers/adreno-metal). Component sources and dependencies: [catalog](https://unixnu.com/reference/components).

The A830 candidate uses `build-adreno-metal-plugin.py --chip a830`. It excludes the A740-only recorded command replay, including any stale `TurnipReplay.h`, and uses live Turnip device discovery and command generation. Its iOS Turnip library, Metal bridge, plugin and probe daemon now compile and pass the build-time signing checks. OnePlus 13T images have shown GPU submissions and presentation on device; Run 88 boots with improved interaction, and its SYSMEM control restores normal colors. Run 91 confirms correct colors and readable diagnostics at about 40 GPU presentations/s; sustained 120 FPS remains unverified.

The scanout worker closes its handoff connection when serving ends, including exception unwinding. A board presenter that implements the optional close hook can then release an outstanding frame and resume its display fallback.

The scanout client negotiates an optional diagnostic row band and excludes it from blits and pixel comparison. Stable kernel mapping IDs enable its existing four-entry import cache. Unsupported overlay negotiation keeps the legacy full-frame path; worker teardown releases the presenter before closing its handoff connection.

Optional heap aliasing now forwards buffer/texture/view ownership and offsets to the pinned runtime, allowing automatic heaps to reuse storage while old objects remain retained. The real frontend/Rust host regression and old-code control cover reuse and destruction; this is separate from phone GPU performance.

The current main frontend and 24 runtime patches use metal2vulkan 624bab3918de5b978e1101517abca2b4fa426565. The A830 plugin build supplies six shader processors to gpuCoreCount; this is topology for MPS sizing, not an active-core measurement. Existing heap alias forwarding and the board's negotiated overlay band are retained.

The build checks the plugin, frontend and probe syntax before compiling the Rust bridge. The iPadOS 27 framebuffer experiment and its helper are limited to arm64e builds.

The actual frontend/Rust heap regression and old-code control passed in Run 89. The texture fixture accounts for upstream standalone allocation after an automatic heap fills, while retaining the aliasing, ownership and release assertions. Run 88 production code is unchanged.

Compute scanout now excludes the negotiated diagnostic band for both opaque BGRA and half-float conversion, as the blit path does. The pixel regression covers a middle band and a whole-frame band with padded pitches; the actual macOS/MoltenVK pixel regression passed in Run 90; Run 90 and Run 91 device feedback confirms readable diagnostics.

The OnePlus 13T Run 88 SYSMEM control restored correct colors on device. Its candidate profile now uses `sheng-tu-debug=sysmem,nocb` pending A830 GMEM validation. Interaction is reported around 30-60 FPS with control-center and cold-launch stalls; sustained frame rate has not been measured.

The A830 performance candidate uses opt-in profiling, iOS worker QoS and non-lazy SYSMEM attachments. The upstream runtime patch series is checked against the pinned translator. Its 120 Hz software pacing does not qualify panel refresh or sustained FPS; Run 90 confirms correct colors and readable diagnostic rows on device.

The current main integration uses AdrenoMetal 831a9dc and the upstream 24-patch runtime series. Scanout markers and periodic PF text are opt-in after the first frame. Optional 40-byte completion records carry dependency-wait, encode/import, submit, completion-wait and runtime GPU timestamp durations; a size/unsupported refusal falls back once to the legacy 16-byte record. Kernel offer-to-delivery time and observed software VSYNC rate are reported separately. A missing GPU timestamp remains unknown; a host Vulkan driver may report a host-derived interval. Run 91 showed about 40 GPU presentations/s on OnePlus 13T, so 120 FPS and physical panel timing remain unqualified.

The A830/iPadOS 17 candidate now shares version-keyed shader caches between writable processes of the same UID, with container-local fallback when the shared directory is unavailable. Unique temporary import files prevent concurrent cache import collisions. The 26-patch runtime series adds specialized function names, shared storage for large indexed constants and allocation-size queries; the frontend adds swizzled texture views, function-constant reflection, asynchronous descriptor selectors, mip/slice range copies, viewport/scissor arrays and command-queue limits. Requested multisampling remains the default.

Optional frame diagnostics link Metal command IDs, runtime/Vulkan commands, kernel fences and the board's scanout request. Completed IOSurface samples retain raw texels and color metadata; the OnePlus presenter adds bounded samples of its completed GPU scanout mapping. Enable `sheng-gpu-trace=1 sheng-gpu-pixels=1` only when collecting a trace. These additions are host-tested; their device behavior and performance still require measurement.
