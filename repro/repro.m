// Metal 4 pipeline-capture race repro.
//
// Many threads build render pipelines concurrently through one MTL4Compiler
// whose descriptor carries an MTL4PipelineDataSetSerializer configured with
// MTL4PipelineDataSetSerializerConfigurationCaptureBinaries. Many pipelines
// share the same vertex function (different fragment functions, formats and
// blend states). Suspected bug: a use-after-free in
// MultiLevelAirntBinaryCache::getElementAtDestination when two compiles of the
// same vertex program meet in the serializer's binary archive.
//
// Build: ./build.sh   Run: ../build/repro --shaders ../build/shaders-1 [options]
// Exit codes: 0 all pipelines built, 2 pipeline errors, 3 timeout, 64 usage.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef enum { SPEC_NEVER, SPEC_ALWAYS, SPEC_MIXED } SpecMode;

static struct {
    NSString *shaderDir;
    long pipelines;
    int threads;
    BOOL libsPerPipeline;
    BOOL serialSameVertex;
    BOOL capture;
    long flushEvery;
    BOOL flushConcurrent;
    BOOL perThreadCapture;
    SpecMode spec;
    BOOL unspec;
    BOOL grouped;
    int timeoutSec;
    int nvs, nfs;
} opt = {nil, 20000, 0, YES, NO, YES, 0, NO, NO, SPEC_MIXED, NO, NO, 600, 0, 0};

static id<MTLDevice> gDevice;
static NSMutableArray<NSData *> *gVsData, *gFsData;          // metallib bytes
static NSMutableArray<id<MTLLibrary>> *gVsLib, *gFsLib;      // shared libraries
static pthread_mutex_t *gVsLocks;                            // --serial-same-vertex

// The current compiler (replaced on every flush). Workers hold the read lock
// while they compile; a non-concurrent flush takes the write lock.
static pthread_rwlock_t gCompilerLock = PTHREAD_RWLOCK_INITIALIZER;
static id<MTL4Compiler> gCompiler;
static id<MTL4PipelineDataSetSerializer> gSerializer;
static pthread_mutex_t gFlushMutex = PTHREAD_MUTEX_INITIALIZER;
static long gNextFlushAt;
static _Atomic int gFlushCount;

// --per-thread-capture (workaround E): every worker has its own compiler and
// serializer, so no two threads ever capture into the same archive. Each slot
// is used only by its own worker.
#define MAX_THREADS 64
static id<MTL4Compiler> gThreadCompiler[MAX_THREADS];
static id<MTL4PipelineDataSetSerializer> gThreadSerializer[MAX_THREADS];
static long gThreadBuilt[MAX_THREADS];

static atomic_long gNext, gDone, gErrors;
static NSDate *gStart;

static const MTLPixelFormat kFormats[] = {
    MTLPixelFormatRGBA8Unorm, MTLPixelFormatBGRA8Unorm, MTLPixelFormatRGBA16Float,
    MTLPixelFormatRG11B10Float, MTLPixelFormatRGB10A2Unorm, MTLPixelFormatRGBA32Float,
};
#define NUM_FORMATS (int)(sizeof(kFormats) / sizeof(kFormats[0]))

static void usage(void) {
    fprintf(stderr,
        "usage: repro --shaders DIR [options]\n"
        "  --pipelines N          pipelines to build (default 20000)\n"
        "  --threads N            worker threads (default: device maximumConcurrentCompilationTaskCount)\n"
        "  --libs-per-pipeline    fresh newLibraryWithData: for every pipeline (default)\n"
        "  --shared-libs          one MTLLibrary per shader, shared by all pipelines\n"
        "  --serial-same-vertex   workaround: never compile two pipelines with the same vertex function at once\n"
        "  --no-capture           control: compiler without a pipeline data set serializer\n"
        "  --flush-every N        every N pipelines, serializeAsArchiveAndFlushToURL: and start a new compiler+serializer\n"
        "  --flush-concurrent     flush without stopping the other workers (they keep using the old compiler)\n"
        "  --per-thread-capture   workaround E: one compiler + serializer per worker; each worker flushes its own\n"
        "  --specialize M         never|always|mixed: wrap functions in MTL4SpecializedFunctionDescriptor (default mixed)\n"
        "  --unspecialized        leave all 8 colour attachments unspecialized (flexible \"base\" pipelines, as nxnative captures)\n"
        "  --grouped              order pipelines in runs that share one vertex shader (default: interleave vertex shaders)\n"
        "  --timeout S            give up after S seconds, exit 3 (default 600)\n");
    exit(64);
}

static NSData *loadFile(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) { fprintf(stderr, "cannot read %s\n", path.UTF8String); exit(64); }
    return d;
}

static id<MTLLibrary> libFromData(NSData *d, NSString *label) {
    // Same route as nxnative: dispatch_data from the metallib bytes.
    dispatch_data_t dd = dispatch_data_create(d.bytes, d.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *err = nil;
    id<MTLLibrary> lib = [gDevice newLibraryWithData:dd error:&err];
    if (!lib) { fprintf(stderr, "newLibraryWithData: %s\n", err.description.UTF8String); exit(1); }
    lib.label = label;   // as nxnative: labelled with its file name
    return lib;
}

static id<MTL4Compiler> newCompiler(NSString *label, id<MTL4PipelineDataSetSerializer> *serializerOut) {
    MTL4CompilerDescriptor *cd = [MTL4CompilerDescriptor new];
    cd.label = label;
    *serializerOut = nil;
    if (opt.capture) {
        MTL4PipelineDataSetSerializerDescriptor *sd = [MTL4PipelineDataSetSerializerDescriptor new];
        sd.configuration = MTL4PipelineDataSetSerializerConfigurationCaptureBinaries;
        *serializerOut = [gDevice newPipelineDataSetSerializerWithDescriptor:sd];
        cd.pipelineDataSetSerializer = *serializerOut;
    }
    NSError *err = nil;
    id<MTL4Compiler> c = [gDevice newCompilerWithDescriptor:cd error:&err];
    if (!c) { fprintf(stderr, "newCompilerWithDescriptor: %s\n", err.description.UTF8String); exit(1); }
    return c;
}

static void makeCompiler(void) {
    id<MTL4PipelineDataSetSerializer> s;
    gCompiler = newCompiler([NSString stringWithFormat:@"repro-compiler-%d", gFlushCount], &s);
    gSerializer = s;
}

static void makeThreadCompiler(int tid) {
    id<MTL4PipelineDataSetSerializer> s;
    gThreadCompiler[tid] = newCompiler([NSString stringWithFormat:@"repro-compiler-t%d-%d", tid, gFlushCount], &s);
    gThreadSerializer[tid] = s;
}

static void flushSerializer(id<MTL4PipelineDataSetSerializer> s, int n) {
    NSString *dir = [opt.shaderDir stringByAppendingPathComponent:@"../archives"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:
                                         [NSString stringWithFormat:@"capture-%d-%d.metallib", getpid(), n]]];
    NSError *err = nil;
    if (![s serializeAsArchiveAndFlushToURL:url error:&err]) {
        if ([err.localizedDescription containsString:@"Nothing to serialize"]) return;
        fprintf(stderr, "[flush %d] serializeAsArchiveAndFlushToURL failed: %s\n", n, err.description.UTF8String);
    } else
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];   // keep the disk clean
}

static void maybeFlush(long done) {
    if (!opt.capture || opt.flushEvery <= 0) return;
    pthread_mutex_lock(&gFlushMutex);
    if (done < gNextFlushAt) { pthread_mutex_unlock(&gFlushMutex); return; }
    gNextFlushAt += opt.flushEvery;
    if (opt.flushConcurrent) {
        // Swap in a new compiler, then serialize the old one while other
        // workers may still be compiling on it.
        pthread_rwlock_wrlock(&gCompilerLock);
        id<MTL4PipelineDataSetSerializer> old = gSerializer;
        gFlushCount++;
        makeCompiler();
        pthread_rwlock_unlock(&gCompilerLock);
        flushSerializer(old, gFlushCount);
    } else {
        pthread_rwlock_wrlock(&gCompilerLock);
        gFlushCount++;
        flushSerializer(gSerializer, gFlushCount);
        makeCompiler();
        pthread_rwlock_unlock(&gCompilerLock);
    }
    pthread_mutex_unlock(&gFlushMutex);
}

static MTL4FunctionDescriptor *funcDesc(id<MTLLibrary> lib, NSString *name, long salt) {
    MTL4LibraryFunctionDescriptor *lf = [MTL4LibraryFunctionDescriptor new];
    lf.library = lib;
    lf.name = name;
    BOOL wrap = opt.spec == SPEC_ALWAYS || (opt.spec == SPEC_MIXED && (salt % 3) == 0);
    if (!wrap) return lf;
    MTL4SpecializedFunctionDescriptor *sf = [MTL4SpecializedFunctionDescriptor new];
    sf.functionDescriptor = lf;
    sf.constantValues = [MTLFunctionConstantValues new];   // empty constants
    return sf;
}

static void flushSerializer(id<MTL4PipelineDataSetSerializer> s, int n);
static void buildOne(long i, int tid) {
    // Pipeline i: vertex shader i % nvs, so consecutive pipelines (which the
    // workers pick up at the same time) share vertex functions.
    // With --grouped, runs of nfs consecutive pipelines share one vertex
    // shader instead (as nxnative's prebuild orders its pairs).
    int vs, fs;
    long rest;
    if (opt.grouped) {
        fs = (int)(i % opt.nfs); rest = i / opt.nfs;
        vs = (int)(rest % opt.nvs); rest /= opt.nvs;
    } else {
        vs = (int)(i % opt.nvs); rest = i / opt.nvs;
        fs = (int)(rest % opt.nfs); rest /= opt.nfs;
    }
    int fmt = (int)(rest % NUM_FORMATS);
    BOOL blend = ((rest / NUM_FORMATS) & 1) != 0;

    id<MTLLibrary> vlib = opt.libsPerPipeline ? libFromData(gVsData[vs], [NSString stringWithFormat:@"vs_%d.metallib", vs]) : gVsLib[vs];
    id<MTLLibrary> flib = opt.libsPerPipeline ? libFromData(gFsData[fs], [NSString stringWithFormat:@"fs_%d.metallib", fs]) : gFsLib[fs];

    MTL4RenderPipelineDescriptor *rd = [MTL4RenderPipelineDescriptor new];
    rd.label = [NSString stringWithFormat:@"p%ld", i];
    rd.vertexFunctionDescriptor = funcDesc(vlib, [NSString stringWithFormat:@"vs_%d", vs], i);
    rd.fragmentFunctionDescriptor = funcDesc(flib, [NSString stringWithFormat:@"fs_%d", fs], i / 7);
    rd.vertexDescriptor = [MTLVertexDescriptor new];   // empty: pulling-style
    rd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    if (opt.unspec) {
        for (int a = 0; a < 8; a++) {
            MTL4RenderPipelineColorAttachmentDescriptor *c = rd.colorAttachments[a];
            c.pixelFormat = MTLPixelFormatUnspecialized; c.writeMask = MTLColorWriteMaskUnspecialized;
            c.blendingState = MTL4BlendStateUnspecialized;
            c.sourceRGBBlendFactor = c.destinationRGBBlendFactor = MTLBlendFactorUnspecialized;
            c.sourceAlphaBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorUnspecialized;
            c.rgbBlendOperation = c.alphaBlendOperation = MTLBlendOperationUnspecialized;
        }
    } else
        rd.colorAttachments[0].pixelFormat = kFormats[fmt];
    if (blend && !opt.unspec) {
        rd.colorAttachments[0].blendingState = MTL4BlendStateEnabled;
        rd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        rd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }

    NSError *err = nil;
    id<MTLRenderPipelineState> ps;
    if (opt.perThreadCapture) {
        // No lock at all: this worker's compiler and serializer are its own.
        ps = [gThreadCompiler[tid] newRenderPipelineStateWithDescriptor:rd compilerTaskOptions:nil error:&err];
        if (opt.capture && opt.flushEvery > 0 && ++gThreadBuilt[tid] % opt.flushEvery == 0) {
            flushSerializer(gThreadSerializer[tid], ++gFlushCount);   // only this worker uses it: never a concurrent flush
            makeThreadCompiler(tid);
        }
    } else {
        if (opt.serialSameVertex) pthread_mutex_lock(&gVsLocks[vs]);
        // Without --flush-concurrent the read lock is held across the compile, so a
        // flush never overlaps a compile. With it, the old compiler may be flushed
        // while this compile still runs on it.
        pthread_rwlock_rdlock(&gCompilerLock);
        id<MTL4Compiler> c = gCompiler;
        if (opt.flushConcurrent) pthread_rwlock_unlock(&gCompilerLock);
        ps = [c newRenderPipelineStateWithDescriptor:rd compilerTaskOptions:nil error:&err];
        if (!opt.flushConcurrent) pthread_rwlock_unlock(&gCompilerLock);
        if (opt.serialSameVertex) pthread_mutex_unlock(&gVsLocks[vs]);
    }

    if (!ps) {
        long e = atomic_fetch_add(&gErrors, 1) + 1;
        if (e <= 10) fprintf(stderr, "pipeline %ld (vs_%d fs_%d fmt %d blend %d) failed: %s\n",
                             i, vs, fs, fmt, blend, err.localizedDescription.UTF8String);
    }
    long done = atomic_fetch_add(&gDone, 1) + 1;
    if (done % 500 == 0) {
        double t = -[gStart timeIntervalSinceNow];
        printf("[progress] %ld/%ld pipelines, %.1f s, %.0f/s, flushes %d, errors %ld\n",
               done, opt.pipelines, t, done / t, gFlushCount, atomic_load(&gErrors));
        fflush(stdout);
    }
    if (!opt.perThreadCapture) maybeFlush(done);
}

static void *worker(void *arg) {
    int tid = (int)(intptr_t)arg;
    if (opt.perThreadCapture) @autoreleasepool { makeThreadCompiler(tid); }
    for (;;) {
        long i = atomic_fetch_add(&gNext, 1);
        if (i >= opt.pipelines) break;
        @autoreleasepool { buildOne(i, tid); }
    }
    if (opt.perThreadCapture && opt.capture) @autoreleasepool { flushSerializer(gThreadSerializer[tid], ++gFlushCount); }
    return NULL;
}

static void *watchdog(void *arg) {
    (void)arg;
    sleep(opt.timeoutSec);
    printf("TIMEOUT after %d s: %ld/%ld pipelines built\n", opt.timeoutSec, atomic_load(&gDone), opt.pipelines);
    fflush(stdout);
    _exit(3);
}

static int countFiles(NSString *prefix) {
    int n = 0;
    while ([[NSFileManager defaultManager] fileExistsAtPath:
            [opt.shaderDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%d.metallib", prefix, n]]])
        n++;
    return n;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        for (int a = 1; a < argc; a++) {
            const char *s = argv[a];
            #define NEXT() (a + 1 < argc ? argv[++a] : (usage(), ""))
            if (!strcmp(s, "--shaders")) opt.shaderDir = @(NEXT());
            else if (!strcmp(s, "--pipelines")) opt.pipelines = atol(NEXT());
            else if (!strcmp(s, "--threads")) opt.threads = atoi(NEXT());
            else if (!strcmp(s, "--libs-per-pipeline")) opt.libsPerPipeline = YES;
            else if (!strcmp(s, "--shared-libs")) opt.libsPerPipeline = NO;
            else if (!strcmp(s, "--serial-same-vertex")) opt.serialSameVertex = YES;
            else if (!strcmp(s, "--no-capture")) opt.capture = NO;
            else if (!strcmp(s, "--flush-every")) opt.flushEvery = atol(NEXT());
            else if (!strcmp(s, "--flush-concurrent")) opt.flushConcurrent = YES;
            else if (!strcmp(s, "--per-thread-capture")) opt.perThreadCapture = YES;
            else if (!strcmp(s, "--unspecialized")) opt.unspec = YES;
            else if (!strcmp(s, "--grouped")) opt.grouped = YES;
            else if (!strcmp(s, "--timeout")) opt.timeoutSec = atoi(NEXT());
            else if (!strcmp(s, "--specialize")) {
                const char *m = NEXT();
                opt.spec = !strcmp(m, "never") ? SPEC_NEVER : !strcmp(m, "always") ? SPEC_ALWAYS : SPEC_MIXED;
            } else usage();
        }
        if (!opt.shaderDir) usage();
        opt.nvs = countFiles(@"vs");
        opt.nfs = countFiles(@"fs");
        if (!opt.nvs || !opt.nfs) { fprintf(stderr, "no vs_N/fs_N.metallib in %s\n", opt.shaderDir.UTF8String); return 64; }

        gDevice = MTLCreateSystemDefaultDevice();
        if (!gDevice) { fprintf(stderr, "no Metal device\n"); return 1; }
        if (opt.threads <= 0) opt.threads = (int)gDevice.maximumConcurrentCompilationTaskCount;
        if (opt.threads > MAX_THREADS) opt.threads = MAX_THREADS;
        if (opt.perThreadCapture && (opt.serialSameVertex || opt.flushConcurrent)) {
            fprintf(stderr, "--per-thread-capture cannot be combined with --serial-same-vertex or --flush-concurrent\n"); return 64;
        }

        gVsData = [NSMutableArray new]; gFsData = [NSMutableArray new];
        gVsLib = [NSMutableArray new]; gFsLib = [NSMutableArray new];
        for (int i = 0; i < opt.nvs; i++) {
            [gVsData addObject:loadFile([opt.shaderDir stringByAppendingPathComponent:[NSString stringWithFormat:@"vs_%d.metallib", i]])];
            if (!opt.libsPerPipeline) [gVsLib addObject:libFromData(gVsData[i], [NSString stringWithFormat:@"vs_%d.metallib", i])];
        }
        for (int i = 0; i < opt.nfs; i++) {
            [gFsData addObject:loadFile([opt.shaderDir stringByAppendingPathComponent:[NSString stringWithFormat:@"fs_%d.metallib", i]])];
            if (!opt.libsPerPipeline) [gFsLib addObject:libFromData(gFsData[i], [NSString stringWithFormat:@"fs_%d.metallib", i])];
        }
        gVsLocks = calloc(opt.nvs, sizeof(pthread_mutex_t));
        for (int i = 0; i < opt.nvs; i++) pthread_mutex_init(&gVsLocks[i], NULL);

        NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
        printf("device %s, macOS %ld.%ld.%ld, maximumConcurrentCompilationTaskCount %lu\n",
               gDevice.name.UTF8String, (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion,
               (unsigned long)gDevice.maximumConcurrentCompilationTaskCount);
        printf("mode: threads %d, %s, capture %s, serial-same-vertex %s, flush-every %ld%s, specialize %s%s\n",
               opt.threads, opt.libsPerPipeline ? "libs-per-pipeline" : "shared-libs",
               opt.capture ? "binaries" : "off", opt.serialSameVertex ? "on" : "off", opt.flushEvery,
               opt.flushConcurrent ? " (concurrent)" : "",
               opt.spec == SPEC_NEVER ? "never" : opt.spec == SPEC_ALWAYS ? "always" : "mixed",
               opt.unspec ? ", unspecialized colour attachments" : "");
        if (opt.perThreadCapture) printf("capture: one compiler + serializer per worker (workaround E)\n");
        if (opt.grouped) printf("order: grouped (runs of %d pipelines share a vertex shader)\n", opt.nfs);
        printf("shaders: %d vertex, %d fragment; %ld pipelines (%ld distinct)\n", opt.nvs, opt.nfs, opt.pipelines,
               (long)opt.nvs * opt.nfs * (opt.unspec ? 1 : NUM_FORMATS * 2));
        fflush(stdout);

        if (!opt.perThreadCapture) makeCompiler();
        gNextFlushAt = opt.flushEvery;
        gStart = [NSDate date];

        pthread_t wd;
        pthread_create(&wd, NULL, watchdog, NULL);
        pthread_t *th = calloc(opt.threads, sizeof(pthread_t));
        for (int t = 0; t < opt.threads; t++) {
            pthread_attr_t at;
            pthread_attr_init(&at);
            pthread_attr_setstacksize(&at, 8 << 20);
            pthread_create(&th[t], &at, worker, (void *)(intptr_t)t);
        }
        for (int t = 0; t < opt.threads; t++) pthread_join(th[t], NULL);

        if (opt.capture && !opt.perThreadCapture) flushSerializer(gSerializer, ++gFlushCount);
        double t = -[gStart timeIntervalSinceNow];
        long errs = atomic_load(&gErrors);
        printf("DONE: %ld pipelines in %.1f s, %d flushes, %ld errors\n", atomic_load(&gDone), t, gFlushCount, errs);
        return errs ? 2 : 0;
    }
}
