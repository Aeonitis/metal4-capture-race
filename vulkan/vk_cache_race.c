// Vulkan analogue of the Metal 4 repro: many threads call
// vkCreateGraphicsPipelines with ONE shared VkPipelineCache, and every
// pipeline uses the same vertex shader module (different fragment shaders).
// A separate thread calls vkGetPipelineCacheData while they run (the
// "flush" analogue). The Vulkan spec makes this legal without any locking
// by the application (see ../COMPARISON.md).
//
// Build/run: ./build.sh && ../build/vk_cache_race [pipelines] [threads]
// Runs on MoltenVK, which translates to Metal (it does not use the Metal 4
// MTL4Compiler / MTL4PipelineDataSetSerializer path), so this shows the API
// contract, not a test of the Metal 4 bug.

#include <vulkan/vulkan.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s failed: %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static VkDevice dev;
static VkPipelineCache cache;
static VkPipelineLayout layout;
static VkRenderPass rpass;
static VkShaderModule vsMod;
static VkShaderModule *fsMods;
static int nfs;
static long total;
static atomic_long next, done;
static atomic_int finished;

static void *readFile(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    fseek(f, 0, SEEK_END); *len = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
    void *p = malloc(*len);
    if (fread(p, 1, *len, f) != *len) exit(1);
    fclose(f);
    return p;
}

static VkShaderModule module(const char *path) {
    size_t len; void *code = readFile(path, &len);
    VkShaderModuleCreateInfo ci = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, len, code};
    VkShaderModule m; CHECK(vkCreateShaderModule(dev, &ci, NULL, &m));
    free(code);
    return m;
}

static void build(long i) {
    VkPipelineShaderStageCreateInfo st[2] = {
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_VERTEX_BIT, vsMod, "main", NULL},
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_FRAGMENT_BIT, fsMods[i % nfs], "main", NULL},
    };
    VkPipelineVertexInputStateCreateInfo vi = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo ia = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, NULL, 0, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
    VkPipelineViewportStateCreateInfo vp = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, NULL, 0, 1, NULL, 1, NULL};
    VkPipelineRasterizationStateCreateInfo rs = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    rs.polygonMode = VK_POLYGON_MODE_FILL; rs.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo ms = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState ba = {0};
    ba.colorWriteMask = 0xf;
    ba.blendEnable = (i / nfs) & 1;   // vary state so pipelines stay distinct
    ba.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA; ba.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    ba.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE; ba.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
    VkPipelineColorBlendStateCreateInfo cb = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    cb.attachmentCount = 1; cb.pAttachments = &ba;
    VkDynamicState dyn[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo ds = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, NULL, 0, 2, dyn};
    VkGraphicsPipelineCreateInfo ci = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    ci.stageCount = 2; ci.pStages = st; ci.pVertexInputState = &vi; ci.pInputAssemblyState = &ia;
    ci.pViewportState = &vp; ci.pRasterizationState = &rs; ci.pMultisampleState = &ms; ci.pColorBlendState = &cb;
    ci.pDynamicState = &ds; ci.layout = layout; ci.renderPass = rpass;
    VkPipeline p;
    // No application lock: the spec says use of pipelineCache here is internally synchronized.
    CHECK(vkCreateGraphicsPipelines(dev, cache, 1, &ci, NULL, &p));
    vkDestroyPipeline(dev, p, NULL);
}

static void *worker(void *a) {
    (void)a;
    for (;;) {
        long i = atomic_fetch_add(&next, 1);
        if (i >= total) break;
        build(i);
        long d = atomic_fetch_add(&done, 1) + 1;
        if (d % 500 == 0) { printf("[progress] %ld/%ld\n", d, total); fflush(stdout); }
    }
    return NULL;
}

static void *reader(void *a) {
    // vkGetPipelineCacheData is not externally synchronized: it may run while
    // other threads create pipelines into the same cache.
    (void)a;
    long reads = 0;
    while (!atomic_load(&finished)) {
        size_t sz = 0;
        CHECK(vkGetPipelineCacheData(dev, cache, &sz, NULL));
        void *buf = malloc(sz ? sz : 1);
        VkResult r = vkGetPipelineCacheData(dev, cache, &sz, buf);
        if (r != VK_SUCCESS && r != VK_INCOMPLETE) { fprintf(stderr, "vkGetPipelineCacheData: %d\n", r); exit(1); }
        free(buf);
        reads++;
    }
    printf("cache reads during creation: %ld\n", reads);
    return NULL;
}

int main(int argc, char **argv) {
    total = argc > 1 ? atol(argv[1]) : 4000;
    int nthreads = argc > 2 ? atoi(argv[2]) : 12;
    const char *dir = argc > 3 ? argv[3] : "../build/vk-shaders";

    const char *exts[] = {VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vk_cache_race", 1, NULL, 0, VK_API_VERSION_1_3};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR, &app, 0, NULL, 1, exts};
    VkInstance inst; CHECK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t n = 1; VkPhysicalDevice pd;
    VkResult er = vkEnumeratePhysicalDevices(inst, &n, &pd);
    if ((er != VK_SUCCESS && er != VK_INCOMPLETE) || n == 0) { fprintf(stderr, "no Vulkan device\n"); return 1; }
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd, &props);
    float prio = 1.0f;
    VkDeviceQueueCreateInfo q = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &prio};
    const char *dexts[] = {"VK_KHR_portability_subset"};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &q, 0, NULL, 1, dexts, NULL};
    CHECK(vkCreateDevice(pd, &dci, NULL, &dev));

    VkPipelineCacheCreateInfo pcci = {VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO};   // flags 0: internally synchronized
    CHECK(vkCreatePipelineCache(dev, &pcci, NULL, &cache));
    VkPipelineLayoutCreateInfo plci = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
    VkAttachmentDescription att = {0, VK_FORMAT_R8G8B8A8_UNORM, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR,
        VK_ATTACHMENT_STORE_OP_STORE, VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE,
        VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkAttachmentReference ref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sp = {0, VK_PIPELINE_BIND_POINT_GRAPHICS, 0, NULL, 1, &ref, NULL, NULL, 0, NULL};
    VkRenderPassCreateInfo rpci = {VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, NULL, 0, 1, &att, 1, &sp, 0, NULL};
    CHECK(vkCreateRenderPass(dev, &rpci, NULL, &rpass));

    char path[1024];
    snprintf(path, sizeof path, "%s/vs.spv", dir);
    vsMod = module(path);
    for (nfs = 0;; nfs++) {
        snprintf(path, sizeof path, "%s/fs_%d.spv", dir, nfs);
        FILE *f = fopen(path, "rb"); if (!f) break; fclose(f);
    }
    fsMods = calloc(nfs, sizeof *fsMods);
    for (int i = 0; i < nfs; i++) { snprintf(path, sizeof path, "%s/fs_%d.spv", dir, i); fsMods[i] = module(path); }
    printf("device %s (%s), %d threads, %ld pipelines, 1 vertex + %d fragment shaders, one shared VkPipelineCache\n",
           props.deviceName, "MoltenVK", nthreads, total, nfs);

    pthread_t rd; pthread_create(&rd, NULL, reader, NULL);
    pthread_t *th = calloc(nthreads, sizeof *th);
    for (int t = 0; t < nthreads; t++) pthread_create(&th[t], NULL, worker, NULL);
    for (int t = 0; t < nthreads; t++) pthread_join(th[t], NULL);
    atomic_store(&finished, 1);
    pthread_join(rd, NULL);
    size_t sz = 0; CHECK(vkGetPipelineCacheData(dev, cache, &sz, NULL));
    printf("DONE: %ld pipelines, final cache data %zu bytes\n", atomic_load(&done), sz);
    return 0;
}
