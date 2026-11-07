#!/usr/bin/env python3
"""Generate the repro's Metal shaders: a few heavy vertex shaders and many
distinct fragment shaders, one .metal file per function.

Usage: gen_shaders.py OUT_DIR NUM_VS NUM_FS SEED

SEED is mixed into every shader as a constant, so a new seed gives shaders
that no on-disk Metal compiler cache has seen before.
"""
import os
import random
import sys

NUM_VARYINGS = 16  # float4 user outputs of every vertex shader

HEADER = """#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 pos [[position]];
%s};
""" % "".join("    float4 v%d [[user(locn%d)]];\n" % (i, i) for i in range(NUM_VARYINGS))


def vertex_shader(idx, seed, rng):
    # Pulling-style: reads its inputs from buffers by vertex_id. Lots of
    # unrolled math so that the backend compile takes a while.
    lines = [HEADER]
    lines.append("constant float SEED = %d.0f;\n" % seed)
    lines.append(
        "vertex VOut vs_%d(uint vid [[vertex_id]],\n"
        "                 const device float4 *pos [[buffer(0)]],\n"
        "                 const device float4x4 *mats [[buffer(1)]],\n"
        "                 const device float4 *params [[buffer(2)]]) {\n" % idx)
    lines.append("    VOut o;\n    float4 p = pos[vid];\n    float4 acc = p;\n")
    for i in range(48):
        m = rng.randint(0, 31)
        c = rng.uniform(0.1, 2.0)
        fn = rng.choice(["sin", "cos", "fract", "sqrt(abs", "exp2(-abs"])
        call = "%s(acc.%s * %.4f + SEED))" % (fn, rng.choice(["xyzw", "yzwx", "wzyx", "zxwy"]), c) \
            if "(" in fn else "%s(acc.%s * %.4f + SEED)" % (fn, rng.choice(["xyzw", "yzwx", "wzyx", "zxwy"]), c)
        lines.append("    acc = mats[(vid + %d) & 31] * acc + %s * params[%d];\n" % (m, call, i % 64))
        if i % 3 == 0:
            lines.append("    acc = normalize(acc + float4(%.3f, %.3f, %.3f, 1.0));\n"
                         % (rng.random(), rng.random(), rng.random()))
    lines.append("    o.pos = acc;\n")
    for v in range(NUM_VARYINGS):
        lines.append("    acc = fma(acc, params[%d], float4(%.4f)); o.v%d = %s(acc * %.3f);\n"
                     % (v + 8, rng.random(), v, rng.choice(["sin", "cos", "tanh", "fract"]), rng.uniform(0.5, 3)))
    lines.append("    return o;\n}\n")
    return "".join(lines)


def fragment_shader(idx, seed, rng):
    # Every fragment shader is distinct: a different constant, a different
    # chain of math, and a different subset of the vertex outputs it reads
    # (so the linked vertex program can differ too).
    lines = [HEADER]
    lines.append("constant float SEED = %d.0f;\n" % seed)
    lines.append(
        "fragment float4 fs_%d(VOut in [[stage_in]],\n"
        "                     const device float4 *k [[buffer(0)]]) {\n" % idx)
    # Even fragment shaders read every vertex output (so their pipelines can
    # share one linked vertex program); odd ones read a random subset.
    if idx % 2 == 0:
        used = list(range(NUM_VARYINGS))
    else:
        used = sorted(rng.sample(range(NUM_VARYINGS), rng.randint(2, NUM_VARYINGS)))
    lines.append("    float4 c = float4(%d.0f / 997.0f + SEED * 1e-6f);\n" % idx)
    order = used + [rng.choice(used) for _ in range(rng.randint(0, 16))]
    for n, v in enumerate(order):
        op = rng.choice(["c = c * in.v%d + k[%d];", "c = sin(c + in.v%d) * k[%d];",
                         "c = mix(c, in.v%d, k[%d].x);", "c = fract(c * in.v%d + k[%d].yzwx);"])
        lines.append("    " + op % (v, (n + idx) % 32) + "\n")
    lines.append("    return c;\n}\n")
    return "".join(lines)


def main():
    out, nvs, nfs, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    os.makedirs(out, exist_ok=True)
    for i in range(nvs):
        with open(os.path.join(out, "vs_%d.metal" % i), "w") as f:
            f.write(vertex_shader(i, seed, random.Random(seed * 1000 + i)))
    for i in range(nfs):
        with open(os.path.join(out, "fs_%d.metal" % i), "w") as f:
            f.write(fragment_shader(i, seed, random.Random(seed * 100000 + 7919 * i + 1)))


if __name__ == "__main__":
    main()
