# metal4-capture-race

This project tries to reproduce a crash in Apple's Metal 4 framework. The crash
occurs when many threads compile pipelines at the same time and Metal records
("captures") the compiled code into one shared archive. The crash was found in
[nxnative](https://github.com/seedds/nxnative)
([issue #815](https://github.com/seedds/nxnative/issues/815)).

> **Status: not reproduced.** The crash from nxnative did not occur in this
> project. A different crash did occur in one test mode. See [Results](#results).

> **Reported to Apple:** Feedback
> [FB25478288](https://feedbackassistant.apple.com/feedback/25478288) and the
> Apple Developer Forums thread
> [856142](https://developer.apple.com/forums/thread/856142). If you see this
> crash too, file your own Feedback report and mention FB25478288. Duplicate
> reports help Apple rank the bug.

Contents:

1. [Words you need to know](#1-words-you-need-to-know)
2. [The problem](#2-the-problem)
3. [Why the crash could occur](#3-why-the-crash-could-occur)
4. [Why the crash is hard to reproduce](#4-why-the-crash-is-hard-to-reproduce)
5. [Workarounds](#5-workarounds)
6. [Ideas that do not help](#6-ideas-that-do-not-help)
7. [Who can fix what](#7-who-can-fix-what)
8. [Build and run the repro](#8-build-and-run-the-repro)
9. [Results](#results)
10. [Report to Apple](#10-report-to-apple)
11. [Files](#11-files)

[COMPARISON.md](COMPARISON.md) compares this Metal 4 API with Vulkan and
Direct3D 12. Those APIs tell you clearly if a shared cache is safe to use from
many threads. Metal 4 does not.

## 1. Words you need to know

| Word | Meaning |
|---|---|
| **Pipeline** | A GPU program that is ready to draw. It contains a **vertex function** and a **fragment function** (the two **stage functions**). |
| **Compile** | Change shader code into machine code for the GPU. This is slow (from milliseconds to seconds). |
| **`MTL4Compiler`** | The Metal 4 object that compiles pipelines. Many threads can use one compiler at the same time. |
| **Serializer** (`MTL4PipelineDataSetSerializer`) | An object that you attach to a compiler. When it is set to `CaptureBinaries`, it keeps a copy of all machine code that the compiler makes. This is **capture**. |
| **Archive** | The file that the serializer writes (`serializeAsArchiveAndFlushToURL:`). On the next launch, the app loads it and does not compile again. |
| **Flush period** | nxnative writes the archive from time to time. Each time, it starts a new compiler and a new serializer. The time between two writes is one flush period. |
| **Entry** | One item in the archive: the machine code of one compiled program. |
| **Retain / release** | Objective-C counts the owners of each object. *Retain* adds an owner. *Release* removes one. When no owner remains, the object is freed (deleted). |
| **Use-after-free** | A program uses an object after the object was freed. The memory now contains other data, so the program crashes or does something wrong. |
| **Race** | Two threads change or read the same data at the same time, and the result depends on which thread is first. |

## 2. The problem

nxnative does these steps before a game starts (the "pipeline prebuild"):

1. It makes a compiler with a capture serializer.
2. It starts 12 threads. (12 is `maximumConcurrentCompilationTaskCount` on an
   M2 Max.)
3. Each thread compiles pipelines from a list. Many pipelines in the list
   **use the same vertex function**. For example, Ocarina of Time has
   33,365 pipelines but only 15,850 vertex functions. Up to 996 pipelines in a
   row use the same vertex function.
4. From time to time, it writes the archive and starts a new flush period.

On an M2 Max with macOS 27.2, three of three prebuilds crashed. The first crash
came after only 2 seconds. The crash report looks like this:

```
EXC_BAD_ACCESS (SIGSEGV), "possible pointer authentication failure"

objc_msgSend
MultiLevelAirntBinaryCache::getElementAtDestination(MTLBinaryKey*, ...)
-[MTLCompiler compileFunctionRequestInternal:frameworkLinking:linkDataSize:reflectionOnly:compilerTask:completionHandler:]
...
AGX::Compiler::compileProgram<AGX::VertexProgramKey, ...>
```

All crashing code is inside Apple's `Metal.framework`. No nxnative code is in
the crashing thread.

Details of the pipelines in nxnative (for readers who know Metal):

- The descriptors are `MTL4RenderPipelineDescriptor`s.
- The stage functions are `MTL4LibraryFunctionDescriptor`s. Some are wrapped in
  an `MTL4SpecializedFunctionDescriptor` with no constants.
- All colour attachments are `Unspecialized`. (These are flexible "base"
  pipelines.)
- Each library is loaded again for each pipeline with `newLibraryWithData:`
  from a `.metallib` file. Its label is its file name.

## 3. Why the crash could occur

We do not have Metal's source code. This section is a **hypothesis**. It comes
from the crash reports (the function names in the crashing thread) and from
how the crash behaves. It is not proved.

What the crash reports show:

- The crash is in `MultiLevelAirntBinaryCache::getElementAtDestination`. From
  its name, this function gets a compiled program from the destination
  archive, that is, the serializer's archive.
- It crashes when it sends an Objective-C message (`objc_msgSend`) to an
  object. "Possible pointer authentication failure" is what macOS shows when a
  program sends a message to an object that was already freed.
- It occurs only with capture on, only with many threads, and much more often
  when many pipelines use the same vertex function. When compiles of the same
  stage function do not run at the same time (workaround A), it stops.

A possible explanation:

| Step | What Metal could do | Is the entry safe? |
|---|---|---|
| 1 | Thread A asks the archive for the entry of a program. | – |
| 2 | The archive finds the entry while it holds its internal lock. | Yes. The lock protects it. |
| 3 | The archive releases its lock and gives the entry to thread A, but thread A does not become an owner of the entry. | **No.** Only the archive owns it. |
| 4 | Thread A reads the program data from the entry. | **No.** |
| 5 | Thread A keeps (retains) the data. | Safe again, but possibly too late. |

If this is correct, the entry has no owner that protects it between step 3
and step 5. Now think about a second thread that compiles **the same vertex
function** at the same time:

```
Thread A                                   Thread B (same vertex function)
--------                                   -------------------------------
step 2: find entry E (locked)
step 3: get E, unlocked, not an owner
                                           capture the same program again:
                                           the archive replaces E
                                           E has no owner -> E is freed
step 4: read E   <- E is freed memory
CRASH (objc_msgSend on a freed object)
```

**Note:** This project has not yet made this crash occur, so a test does not
prove the hypothesis. Other causes are possible.

## 4. Why the crash is hard to reproduce

If the hypothesis is correct, the unsafe time (step 3 to step 5) is very short. A
second thread must replace the same entry in exactly that time. nxnative has
very large, real shaders and a lot of load, so this occurs often there. The
small shaders in this project make the race less probable.

## 5. Workarounds

A workaround does not repair the bug in Metal. It prevents the conditions that
cause the bug. nxnative uses workarounds A, B and D. Workarounds C and E are
proposals.

| | Workaround | Stops the crash? | Cost | Status |
|---|---|---|---|---|
| A | One capture compile per stage function at a time | Almost: not after the 2 s limit | Threads wait | In nxnative |
| B | Neighbouring pipelines to the same thread | No, but A then almost never waits | None (it is faster) | In nxnative |
| C | After the 2 s limit, compile without capture | Closes the gap in A | Some pipelines are not archived | Proposal |
| D | Write the archive only after its compiles return | Stops the second race (writing vs capturing) | None | In nxnative's prebuild |
| E | One compiler and serializer per thread | Yes, if the archive is the only shared state | More archive files | Proposal; `--per-thread-capture` here |

### A. One capture compile per stage function at a time (nxnative uses this)

**Rule:** Two capture compiles must not use the same stage function at the
same time.

How nxnative does it (`dm/gfx/nvn/nvn_mtl.m`: `cap_fn_key`, `cap_fns_take`,
`cap_fns_give`). This project does the same with `--serial-same-vertex`.

1. Make a key for each stage function: the library's label (its file name)
   plus the function name. Two `MTLLibrary` objects that come from the same
   file get the same key. This is important, because nxnative loads a new
   library object for each pipeline.
2. Before a capture compile, wait until no other capture compile uses the
   vertex key or the fragment key.
3. Mark the two keys as "in use". Compile. Then remove the marks and wake up
   the threads that wait.

```c
// Simplified from nxnative
take(vertex_key, fragment_key);   // wait until no compile uses these keys, then mark them
pipeline = [compiler newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&err];
give(vertex_key, fragment_key);   // remove the marks, wake waiting threads
```

Compiles that use different functions still run in parallel. Compiles without
a serializer do not need the lock, because the race is in the capture archive,
not in the compiler.

**Limit:** nxnative waits for a maximum of 2 seconds (`CAP_FN_WAIT_MS`).
Sometimes Metal's compiler does not return at all (nxnative issue #294). The
limit makes sure that one such compile does not stop all other compiles. But
after 2 seconds, the waiting compile starts **next to** the compile that has
the same function. This is the condition that causes the crash. In nxnative's
measurements, 1,167 compiles (list order) and about 400 compiles (equal parts
per thread) started after the limit. None of them crashed, but that is luck,
not a guarantee. Workaround C closes this gap.

### B. Give pipelines with the same vertex function to the same thread (nxnative uses this)

If 12 threads take pipelines from the list one by one, neighbouring pipelines
(which often use the same vertex function) go to different threads. Then the
threads wait for each other all the time (workaround A).

nxnative gives each thread a **chunk of 256 neighbouring pipelines**
(`PRE_CHUNK`). One thread then compiles a group with the same vertex function
one after another. Metal compiles the vertex program once and then finds it in
the archive. When a thread has no new chunk, it helps with the chunks of other
threads.

Result (Ocarina of Time, 6,000 pipelines, empty archive, M2 Max, 12 threads):

| Order | Time | Waits |
|---|---|---|
| List order, one by one | 786 s (10,000 pipelines) | 3,976 |
| 12 equal parts | 295–308 s | about 570 |
| Chunks of 256 | **213 s** | **4** |

So workaround B makes the prebuild faster and makes the 2-second limit of
workaround A almost never occur.

### C. After the time limit, compile without capture (proposal, not implemented)

When the wait of workaround A reaches 2 seconds, do not start the compile next
to the other one. Compile the pipeline with **a second compiler that has no
serializer**:

```c
if (!take_with_timeout(vertex_key, fragment_key, 2000 /* ms */)) {
    // Another compile of the same function did not finish in 2 s.
    // Do not capture next to it: compile without a serializer.
    pipeline = [plain_compiler newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&err];
    // This pipeline is not in this period's archive. A later run captures it.
} else {
    pipeline = [capture_compiler newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&err];
    give(vertex_key, fragment_key);
}
```

- Advantage: two capture compiles of the same function never run at the same
  time, so the race cannot occur.
- Cost: some pipelines are not in the archive, so they compile again on a
  later run. Make one `plain_compiler` and use it again. Do not make a new
  compiler for each pipeline.
- Status: not implemented and not tested.

### D. Do not write the archive while compiles capture into it

This is a second, different race (see [Results](#results)). Rule: write a
flush period's archive only after all compiles of that period have returned.
nxnative's prebuild does this. This project's `--flush-concurrent` mode breaks
this rule on purpose, and it crashes.

### E. One compiler and one serializer for each thread (proposal)

The crash needs two threads that capture into **the same** archive. Thus, do
not share the archive:

1. Give each worker thread its own `MTL4Compiler` with its own
   `MTL4PipelineDataSetSerializer`.
2. Each thread writes its own archive at the end of its own flush period. No
   other thread uses that serializer, so a write can never occur during a
   capture (workaround D is automatic).
3. At the next launch, load all the archives.

```c
// Each worker, once:
compiler[tid] = new_compiler_with_its_own_serializer();
// For each pipeline: no lock, because nothing is shared
pipeline = [compiler[tid] newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:&err];
```

- Advantage: there is no lock and no time limit, so there is no gap like the
  one in workaround A. The race cannot occur **if the archive is the only
  shared object**.
- Risk: Metal can have other caches that all compilers in the process share.
  `MultiLevelAirntBinaryCache` ("multi-level") can have a level above the
  archive. If that level is shared, the race can still occur. We do not know
  this yet.
- Cost: there are more archive files (one for each thread and period). A
  vertex program that two threads compile is in two archives. nxnative already
  writes one archive for each flush period, so it already loads more than one.
- Status: this project has the mode `--per-thread-capture`. It runs and
  builds all pipelines. But this project cannot make the crash occur, so a
  clean run here does not prove the workaround. The real test is nxnative's
  prebuild **without** the lock of workaround A: three of three runs crashed
  before. If three runs with workaround E do not crash, that is good evidence.

## 6. Ideas that do not help

| Idea | Why it does not help |
|---|---|
| **Patch the bug in `Metal.framework`** | `Metal.framework` is in the system's signed shared library cache. On iOS, an app cannot change system code: code signing does not permit it. On macOS, each player must turn off System Integrity Protection. You cannot ship that. |
| **Replace Metal's private methods at runtime** (method swizzling) | If the hypothesis in section 3 is correct, the unsafe time starts **inside** Metal, after Metal releases its own internal lock. A replacement method can only run before or after Metal's code, not inside it, so a small unsafe time stays. The replacement cannot use Metal's internal lock either. Also, the classes are private, so each macOS or iOS update can break the replacement. |
| **Build fewer shaders** (nxnative's `--seen-shaders`) | This changes how many shaders are built, not how the compiles share an archive. Pipelines in the list still share vertex functions, so the race can still occur. Also, it can make the game slower: a partial build has no `c1_full.tsv` or `cb_extent.tsv`, so the host gives each shader its own 64 KiB of constants (nxnative `docs/reference/frame-rate.md`, "Dedicated c1 constants as slices of a bank": frame p50 of 100 ms before the fix, and a p99 of 100–114 ms after it). Shaders that are not in the list do not draw. Use it only for a fast check. For performance, build all shaders. |
| **Use one compile thread** | This stops the race, because no two compiles occur at the same time. But the prebuild becomes about 12 times slower. |
| **Do not capture** (`--no-capture`) | This stops the race, because there is no archive. But there is no archive at the next launch either, so the game compiles every pipeline again on each launch and stutters. |
| **Retry after the crash** | nxnative's archive keeps the periods that it wrote before the crash, so each run goes further. But each run can crash again, and a crash during a game is not acceptable. |

## 7. Who can fix what

We are the developers of nxnative and of this project. We are **not** the
developers of `Metal.framework`. Thus:

| Who | What they can do |
|---|---|
| **Apple** | Find and repair the bug where it is. If the hypothesis in section 3 is correct, the archive must give a caller an entry that the caller owns, or copy the data out while it still holds its lock. Document if `MTL4PipelineDataSetSerializer` and `serializeAsArchiveAndFlushToURL:` are safe to use from many threads. Vulkan and Direct3D 12 document this (see [COMPARISON.md](COMPARISON.md)). |
| **We (app developers)** | Make sure that our code never causes the conditions of the bug. Workarounds A to D do this partly. Workaround E can do it fully, if the risk in E is not real. Report the bug ([section 10](#10-report-to-apple): FB25478288). |

## 8. Build and run the repro

You need:

- macOS 26 or later with Metal 4 (tested on macOS 27.2)
- Xcode with the Metal toolchain
- Python 3

If your shell sets an old `SDKROOT`, run `unset SDKROOT` first. (The scripts do
this themselves.) All build output goes into `build/`. Git ignores this folder.

```sh
cd repro
./build.sh 1 4 512        # SEED NUM_VS NUM_FS: builds ../build/repro and ../build/shaders-1/*.metallib
../build/repro --shaders ../build/shaders-1 --pipelines 5000 --flush-every 100
./run.sh LABEL SEED [repro options]   # one run with new shaders; adds a line to ../build/results.tsv
./matrix.sh 5000 2        # first set of test modes
./matrix2.sh 2            # second set, closer to nxnative
./matrix3.sh 2            # third set: the modes matrix2.sh did not reach, and workaround E
```

**Caution:** a full matrix runs for a long time (up to 600 s for each run).
Close other programs that use much memory before you start it.

### The test shaders

`gen_shaders.py` writes one `.metal` file for each function: `NUM_VS` vertex
functions and `NUM_FS` fragment functions. `xcrun metal` and `xcrun metallib`
compile each file into one `.metallib`.

- The vertex functions read their data from buffers by `vertex_id`. (The
  pipeline has an empty `MTLVertexDescriptor`.) They are large on purpose:
  48 unrolled matrix and math steps, and 16 `float4` outputs. A large shader
  makes the compile slower, so the unsafe time can occur more often.
- All fragment functions are different. Even-numbered ones read all 16 vertex
  outputs, so their pipelines can share one linked vertex program. Odd-numbered
  ones read a random part of the outputs.
- The seed changes the shader source. A new seed makes sure that Metal's disk
  cache does not already contain the shaders. `run.sh` uses a new seed for
  each run.

### Options of `repro`

| Option | What it does |
|---|---|
| `--threads N` | Number of worker threads (default: `maximumConcurrentCompilationTaskCount`, 12 on an M2 Max) |
| `--libs-per-pipeline` (default) / `--shared-libs` | Load a new library for each pipeline (as nxnative does), or use one `MTLLibrary` per shader for all pipelines |
| `--serial-same-vertex` | Workaround A: a lock for each vertex function around each compile |
| `--no-capture` | Control test: a compiler without a serializer |
| `--flush-every N` | After each N pipelines, write the archive and start a new compiler and serializer |
| `--flush-concurrent` | Start the new compiler, then write the old serializer while compiles can still use it (breaks workaround D) |
| `--per-thread-capture` | Workaround E: each worker has its own compiler and serializer and writes its own archive after each `--flush-every` of its own pipelines. No locks. Cannot be used with `--serial-same-vertex` or `--flush-concurrent` |
| `--specialize never\|always\|mixed` | Wrap stage functions in `MTL4SpecializedFunctionDescriptor` with no constants (mixed: about one in three) |
| `--unspecialized` | Set all 8 colour attachments to `Unspecialized` (base pipelines, as nxnative does) |
| `--grouped` | Put pipelines with the same vertex function next to each other (default: mix them, so all 12 threads use the same few functions at the same time) |
| `--pipelines N`, `--timeout S` | Stop after N pipelines (exit 0) or after S seconds (exit 3) |

Exit codes: 0 = all pipelines were built. 2 = one or more pipelines failed.
3 = timeout. A crash gives a signal exit (`run.sh` writes `139` for SIGSEGV)
and an `.ips` report in `~/Library/Logs/DiagnosticReports`.

## Results

Runs on 2026-11-07, M2 Max, macOS 27.2, 12 threads (if not given differently).
Each line in `build/results.tsv` has: label, seed, exit code, seconds,
pipelines built, crash report. A copy of the results from this day is in
[`evidence/results.tsv`](evidence/results.tsv).

| Mode | Runs | Result |
|---|---|---|
| `cap-flush100`, `cap-flush100-nvs1`, `cap-flush100-shared`, `cap-flush5000` | 2 each | 5000/5000, no crash |
| `cap-spec-always`, `cap-24threads` (24 threads) | 2 each | 5000/5000, no crash |
| `serial-same-vertex` (workaround A), `no-capture` (control) | 2 each | 5000/5000, no crash |
| `unspec-flush100` (4 VS, 2048 FS, unspecialized) | 2 | 8000/8000, no crash |
| `unspec-nvs1-flush100` (1 VS, 2048 FS) | 1 complete (3003) | 2000/2048 at the 600 s limit, no crash |
| `cap-flush100-concurrent` (`--flush-concurrent`) | 2 (2007, 2008) | **SIGSEGV both times** (500/5000 after 56 s; immediately) |

Early runs: `default` (101) built 30000 pipelines but had 10386 errors after
`serializeAsArchiveAndFlushToURL:` failed (`MTLBinaryArchiveDomain` code 3,
"cannot open .../com.apple.gpuarchiver/.../PersistentState"). `nvs1` (102)
built 20000/20000. `cap-flush24` (1001) was stopped by hand at 2500/10000.

**The `--flush-concurrent` crash is not the nxnative crash.** Both crashes are
`KERN_INVALID_ADDRESS at 0x30` in `dispatch_data_create_map`, called from
`-[_MTLBinaryArchive(MTLBinaryArchiveInternal) newArchiverIdWithBinaryKey:entry:srcArchiverId:functionType:]`
in the compile's completion block. They are not in `getElementAtDestination`. The crashing thread is
`com.apple.MTLCompilerConnectionQueue`. The full stacks are in
[`evidence/`](evidence/).
They occur because the archive is written while compiles still capture into it
(an entry's `dispatch_data` is NULL). This shows a second race, between writing
and capturing (workaround D). It does not show the race between two captures.
Apple does not document if writing a serializer while it is in use is
permitted.

`per-thread-capture` (workaround E) had a short check only: 600 pipelines,
`--flush-every 50`, 23 archives written, no errors, no crash. That shows that
the mode works. It does not prove the workaround.

**Not run yet.** `matrix2.sh` stopped during run 3004, because the Mac went down
for a different reason. `matrix3.sh` runs these modes:

- `unspec-noflush`
- `unspec-nvs64-grouped`
- `unspec-serial-same-vertex`
- `flush-concurrent-serial-same-vertex`: does workaround A also stop the write
  race? (Expected: no.)
- `flush-concurrent-1thread`: does the write race occur with only one compile
  at a time?
- `per-thread-capture`, `unspec-per-thread-capture`: workaround E with full
  runs.

## 10. Report to Apple

- **Feedback Assistant:** [FB25478288](https://feedbackassistant.apple.com/feedback/25478288)
  (submitted 2026-11-07, with nxnative's crash reports and this repository).
  Only the person who filed it can open this link. Other people can refer to
  the number in their own reports.
- **Apple Developer Forums:** [thread 856142](https://developer.apple.com/forums/thread/856142).

The text below is close to the submitted report. It is for Apple's engineers,
so it uses Metal's own terms.

**Title:** Metal 4: use-after-free in `MultiLevelAirntBinaryCache::getElementAtDestination` when concurrent `MTL4Compiler` compiles capture the same vertex function into an `MTL4PipelineDataSetSerializer`

**Area:** Metal / Metal 4 compiler · **Type:** Crash · **Reproducibility:**
intermittent, needs heavy concurrency (attach the app's crash logs; this
standalone repro does not trigger it).

**Environment:** MacBook Pro M2 Max, macOS 27.2, Xcode 27.2, Metal toolchain
32023.922.4. Also seen on iOS (attach logs if any).

**Description:**
An app creates an `MTL4Compiler` whose descriptor has an
`MTL4PipelineDataSetSerializer` (configuration `CaptureBinaries`) and calls
`newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:` from 12
threads (`maximumConcurrentCompilationTaskCount`). Many pipelines share a
vertex function. Intermittently the process crashes with SIGSEGV in
`objc_msgSend` ("possible pointer authentication failure"), called from
`MultiLevelAirntBinaryCache::getElementAtDestination(MTLBinaryKey*, …, MTLReflectionType)`,
called from
`-[MTLCompiler compileFunctionRequestInternal:frameworkLinking:linkDataSize:reflectionOnly:compilerTask:completionHandler:]`
inside `AGX::Compiler::compileProgram<AGX::VertexProgramKey, …>`.

The crash happens only with capture on, under heavy concurrency, and much more
often when many pipelines share a vertex function. Running capture compiles
that share a stage function one at a time stops it. This suggests that a
binary archive entry is freed by a concurrent capture of the same program
while `getElementAtDestination` still uses it.

**Steps to reproduce:**

1. Create a serializer with `MTL4PipelineDataSetSerializerConfigurationCaptureBinaries`
   and a compiler with it.
2. On 12 threads, compile thousands of `MTL4RenderPipelineDescriptor`s that
   share a few vertex functions (`MTL4LibraryFunctionDescriptor`, each library
   loaded with `newLibraryWithData:`) and use different fragment functions.
   Colour attachments are unspecialized.
3. Optionally, flush the serializer periodically with
   `serializeAsArchiveAndFlushToURL:` and start a new compiler and serializer.

**Expected:** Pipelines compile, and capture is thread-safe. `MTL4Compiler` is
`Sendable`, and its documentation says it applies multithreading by default.
The serializer is attached implicitly, so the app cannot lock around its
internal updates.

**Actual:** Intermittent SIGSEGV in `getElementAtDestination` (probably a use-after-free of a
binary archive entry).

**Workaround:** Serialize capture compiles that share a stage function. Please
also document the thread-safety contract of `MTL4PipelineDataSetSerializer`
and `serializeAsArchiveAndFlushToURL:`. See COMPARISON.md for what Vulkan and
D3D12 state.

**Attachments:** crash reports from nxnative (three from one day on an M2 Max,
all with the same stack) and this repository.

## 11. Files

| File | Contents |
|---|---|
| `repro/repro.m` | The repro (Objective-C, ARC, only Metal and Foundation) |
| `repro/gen_shaders.py`, `repro/build.sh` | Make and compile the test shaders |
| `repro/run.sh`, `repro/matrix.sh`, `repro/matrix2.sh`, `repro/matrix3.sh` | Run tests and record results |
| `evidence/` | The results of 2026-11-07 and the crashing thread of each crash report (runs 2007, 2008) |
| `vulkan/` | Optional Vulkan version of the test (one `VkPipelineCache`, 12 threads, MoltenVK) |
| `COMPARISON.md` | What Vulkan, Direct3D 12 and Metal 4 promise about many threads and one shared cache |
