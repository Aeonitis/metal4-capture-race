# Concurrent pipeline creation into one shared cache: Vulkan, Direct3D 12, Metal 4

The Metal 4 pattern in this repository is: many threads create pipelines at once
through one `MTL4Compiler`, and every result is captured into the one
`MTL4PipelineDataSetSerializer` attached to that compiler. Many of those
pipelines share a stage function. Now and then the serializer is written out
while it is in use or just after. This note sets out what each API promises for
that pattern, quoting only what its specification or documentation says.

Sources were read on 2026-11-07. The Vulkan text comes from the specification
source in [KhronosGroup/Vulkan-Docs](https://github.com/KhronosGroup/Vulkan-Docs)
(`main` branch: `chapters/pipelines.adoc`, `chapters/fundamentals.adoc`,
`xml/vk.xml`), which is rendered at <https://docs.vulkan.org/spec/latest/>.

## Vulkan: `VkPipelineCache`

**The default is an internally synchronized shared cache.** From
[Pipeline Cache, Creating a Pipeline Cache](https://docs.vulkan.org/spec/latest/chapters/pipelines.html#pipelines-cache-create):

> Once created, a pipeline cache can be passed to the vkCreateGraphicsPipelines,
> [...] and vkCreateComputePipelines commands. If the pipeline cache passed into
> these commands is not VK_NULL_HANDLE, the implementation will query it for
> possible reuse opportunities and update it with new content. **The use of the
> pipeline cache object in these commands is internally synchronized, and the
> same pipeline cache object can be used in multiple threads simultaneously.**

A note in the same section then says:

> Implementations should make every effort to limit any critical sections to the
> actual accesses to the cache, which is expected to be significantly shorter
> than the duration of the vkCreate*Pipelines commands.

The general rule in [Threading Behavior](https://docs.vulkan.org/spec/latest/chapters/fundamentals.html#fundamentals-threadingbehavior)
is: "All commands support being called concurrently from multiple threads", and
"Any object parameters that are not labeled as externally synchronized are either
not mutated by the command or are internally synchronized." In the registry
(`vk.xml`), the `pipelineCache` parameter of `vkCreateGraphicsPipelines` and
`vkCreateComputePipelines` is `externsync="maybe"`: external synchronization
applies only under the opt-in flag described next. The `dstCache` parameter of
`vkMergePipelineCaches` is also `externsync="maybe"`, and `vkDestroyPipelineCache`
is `externsync="true"`. `vkGetPipelineCacheData` has no `externsync` at all, so
an application may read the whole cache out (the counterpart of
`serializeAsArchiveAndFlushToURL:`) while other threads are still creating
pipelines into it.

**Opting out is explicit.** `VK_PIPELINE_CACHE_CREATE_EXTERNALLY_SYNCHRONIZED_BIT`
came from `VK_EXT_pipeline_creation_cache_control` and is core since Vulkan 1.3:

> VK_PIPELINE_CACHE_CREATE_EXTERNALLY_SYNCHRONIZED_BIT specifies that all
> commands that modify the created VkPipelineCache will be externally
> synchronized. When set, the implementation may skip any unnecessary processing
> needed to support simultaneous modification from multiple threads where
> allowed.

When the flag is set, valid usage VUID-vkCreateComputePipelines-pipelineCache-02873
(and its graphics counterpart) says: "host access to pipelineCache must be
externally synchronized." So the application takes on the locking only when it
asks to. `VK_KHR_maintenance8` adds
`VK_PIPELINE_CACHE_CREATE_INTERNALLY_SYNCHRONIZED_MERGE_BIT_KHR`, which makes
`vkMergePipelineCaches` into that cache internally synchronized as well.

**`VK_EXT_pipeline_creation_cache_control`** ([appendix](https://registry.khronos.org/vulkan/specs/latest/man/html/VK_EXT_pipeline_creation_cache_control.html))
also adds `VK_PIPELINE_CREATE_FAIL_ON_PIPELINE_COMPILE_REQUIRED_BIT` and
`VK_PIPELINE_CREATE_EARLY_RETURN_ON_FAILURE_BIT`, which let an application ask
for a pipeline only if it can be made without compiling. Its background section
lists what a pipeline-creating call may do, including "Internal thread
synchronization or yielding of the current thread's core". In other words,
implementations are expected to synchronize internally.

**`VK_KHR_pipeline_binary`** ([Pipeline Binaries](https://docs.vulkan.org/spec/latest/chapters/pipelines.html#pipelines-binaries))
replaces the opaque cache with application-owned `VkPipelineBinaryKHR` objects.
They are extracted from a pipeline created with
`VK_PIPELINE_CREATE_2_CAPTURE_DATA_BIT_KHR`, or looked up in the driver's internal
cache (`pipelineBinaryInternalCache`, `VK_PIPELINE_BINARY_MISSING_KHR` on a
miss). "When creating a pipeline that includes VkPipelineBinaryInfoKHR [...], or
has the VK_PIPELINE_CREATE_2_CAPTURE_DATA_BIT_KHR flag set, the use of
VkPipelineCache objects is not allowed." Capture is per pipeline object: each
thread owns what it captured, and there is no shared mutable container that
concurrent creations write into. `vkCreatePipelineBinariesKHR`,
`vkGetPipelineBinaryDataKHR` and `vkReleaseCapturedPipelineDataKHR` carry no
`externsync` parameters in `vk.xml`. This is the closest Vulkan analogue to Metal
4's "capture binaries", and its design leaves no shared container to race on.

**What Vulkan promises for this repro's pattern:** N threads × `vkCreateGraphicsPipelines`
× one `VkPipelineCache` (created without the externally synchronized flag),
pipelines sharing a `VkShaderModule`, plus a concurrent `vkGetPipelineCacheData`,
is valid usage, and the implementation must make it safe. A crash there would be
a driver bug by the specification's own words.

`vulkan/vk_cache_race.c` exercises exactly this pattern (12 threads, one shared
vertex module, 256 fragment modules, a thread calling `vkGetPipelineCacheData`
in a loop, no application lock) on MoltenVK 1.4.2. Its results are in the README.
MoltenVK builds pipelines through Metal's older `MTLDevice` pipeline API, not
through `MTL4Compiler` plus `MTL4PipelineDataSetSerializer`, so it shows the
contract, not the Metal 4 code path.

## Direct3D 12: `ID3D12PipelineLibrary`

[`ID3D12Device1::CreatePipelineLibrary`, Remarks, "Thread Safety"](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device1-createpipelinelibrary):

> The pipeline library is thread-safe to use, and will internally synchronize as
> necessary, with one exception: **multiple threads loading the same PSO (via
> LoadComputePipeline, LoadGraphicsPipeline, or LoadPipeline) should synchronize
> themselves, as this act may modify the state of that pipeline within the
> library in a non-thread-safe manner.**

Other rules that matter here:

- [`StorePipeline`](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12pipelinelibrary-storepipeline):
  the name is "a unique name [...]. Overwriting is not supported." It returns
  `E_INVALIDARG if the name already exists`. An entry is never replaced, so an
  entry another thread already looked up cannot be freed under it. Replacement is
  exactly what the Metal crash looks like (see the README).
- `Serialize` and `GetSerializedSize` fall under the general "thread-safe [...]
  internally synchronize" statement. No exception is documented for them.
- The library's initial blob is not copied: "The pointer provided as input to
  this method must remain valid for the lifetime of the object returned." The
  application owns that lifetime.
- "At no point in the lifecycle of a pipeline library is there duplication
  between PSOs with identical sub-components": the library deduplicates shared
  shaders internally, as Metal's archive does.
- PSO creation itself (`CreateGraphicsPipelineState`) is meant to be
  free-threaded: the [D3D12 CPU efficiency design spec](https://microsoft.github.io/DirectX-Specs/d3d/CPUEfficiency.html)
  lists "Pipeline State objects must be able to be created in a free-threaded
  manner" as a goal. The per-method reference pages say nothing about threading.
- `ID3D12PipelineLibrary1::LoadPipeline` (stream descriptions) falls under the
  same rule, including the same-PSO exception.

**D3D12 shader cache APIs** ([`ID3D12ShaderCacheSession`](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nn-d3d12-id3d12shadercachesession),
[ShaderCache spec](https://microsoft.github.io/DirectX-Specs/d3d/ShaderCache.html))
are an application key/value store ("to enable applications to cache DXBC, DXIL,
or other intermediate shader code representations, tied to some opaque key").
They are not the PSO capture path. Their documentation says nothing about
threading, beyond "Caches with the same identifier are shared across all
sessions in the same process" and the `*.lock` files that make up a disk cache.

**What D3D12 promises for this repro's pattern:** concurrent `StorePipeline` and
`Serialize` on one library are internally synchronized. Concurrent loads of
*different* PSOs are internally synchronized. Concurrent loads of the *same* PSO
are the one documented case where the application must lock. That is close to
the workaround here: Microsoft names the hazard (one entry touched by several
threads at once) and documents it, where Metal 4 says nothing.

## Metal 4: `MTL4Compiler` and `MTL4PipelineDataSetSerializer`

What Apple documents (macOS 27.2 SDK headers and
[developer.apple.com](https://developer.apple.com/documentation/metal/mtl4pipelinedatasetserializer)):

- `MTL4Compiler` is declared `NS_SWIFT_SENDABLE`, and its documentation page lists
  it as inheriting from `Sendable`
  ([MTL4Compiler](https://developer.apple.com/documentation/metal/mtl4compiler)).
  Under Swift's concurrency model that means one compiler may be used from
  several concurrency domains, which implies thread-safe use. The article
  [Using the Metal 4 compilation API](https://developer.apple.com/documentation/metal/using-the-metal-4-compilation-api)
  says "The MTL4Compiler protocol applies multithreading in macOS and iOS by
  default", and recommends asynchronous compilation and dispatch queues.
  `MTLDevice.maximumConcurrentCompilationTaskCount` exists to size that
  concurrency. `MTL4Archive` is `Sendable` too.
- `MTL4PipelineDataSetSerializer` is described as "A fast-addition container for
  collecting data during pipeline state creation". The compiler "stores data for
  all pipelines it creates" into it (`MTL4CompilerDescriptor.pipelineDataSetSerializer`).
  The protocol is **not** marked `Sendable`; it inherits only `NSObjectProtocol`.
  **Apple documents nothing about its thread safety:** not whether captures from
  concurrent compiles into one serializer are synchronized, not whether
  `serializeAsArchiveAndFlushToURL:` may run while compiles are in flight, and
  not what "flush" means for entries still in use. No header in the SDK
  (`MTL4Compiler.h`, `MTL4PipelineDataSetSerializer.h`, `MTLDevice.h`) has any
  threading note for these types. The only threading notes in the `MTL4*`
  headers concern `MTL4CommitOptions` and command-buffer encoding.

Reading the two together: the compiler is presented as safe to use from many
threads, and it writes into the serializer implicitly on every compile. An
application cannot lock "the serializer" around those writes. It can only lock
around whole compiles, which defeats the multithreaded compiler. So the
reasonable reading is that the compiler must synchronize its own captures, as
Vulkan states outright for `vkCreate*Pipelines` with a shared `VkPipelineCache`.

## Side by side

| | Vulkan `VkPipelineCache` | D3D12 `ID3D12PipelineLibrary` | Metal 4 compiler + serializer |
|---|---|---|---|
| Concurrent creation into one shared cache | Internally synchronized, stated in spec | Internally synchronized, stated in docs | Not documented. The compiler is `Sendable`; the serializer is not |
| Same shader / same entry from several threads at once | Covered by the same guarantee | Same PSO *load* from several threads: **app must synchronize** (documented exception) | Not documented. Crashes (see README) |
| Reading the cache out while creation runs | `vkGetPipelineCacheData` not externally synchronized | `Serialize` covered by "thread-safe" | Not documented |
| Opt-out for speed | `VK_PIPELINE_CACHE_CREATE_EXTERNALLY_SYNCHRONIZED_BIT` | none | none |
| Entry replacement | Implementation detail (merge "should prune duplicates") | Not allowed (`E_INVALIDARG` on an existing name) | Suspected: the crash looks like a looked-up entry freed by another thread (see README) |
| Per-pipeline capture alternative | `VK_KHR_pipeline_binary` (no shared container) | n/a | n/a |
