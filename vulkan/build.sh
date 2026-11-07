#!/bin/sh
# Build the optional Vulkan analogue (needs the Vulkan loader + MoltenVK, e.g. Homebrew
# vulkan-loader, molten-vk and shaderc). Outputs go to ../build (gitignored).
#   ./build.sh [NUM_FS]
set -eu
unset SDKROOT
cd "$(dirname "$0")"
NFS=${1:-256}
OUT=../build
SH=$OUT/vk-shaders
mkdir -p "$SH"
PREFIX=${VULKAN_PREFIX:-/opt/homebrew}
xcrun clang -O2 -g -Wall -I"$PREFIX/include" -L"$PREFIX/lib" -Wl,-rpath,"$PREFIX/lib" \
    -o "$OUT/vk_cache_race" vk_cache_race.c -lvulkan

# One heavy vertex shader (pulling-style: gl_VertexIndex, no vertex input) and NFS
# distinct fragment shaders.
cat > "$SH/vs.vert" <<'EOF'
#version 450
layout(location = 0) out vec4 v[8];
void main() {
    vec4 acc = vec4(float(gl_VertexIndex));
    for (int i = 0; i < 64; i++) acc = sin(acc * 1.37 + vec4(i)) * cos(acc.yzwx);
    for (int j = 0; j < 8; j++) v[j] = fract(acc * float(j + 1));
    gl_Position = acc;
}
EOF
glslc -o "$SH/vs.spv" "$SH/vs.vert"
i=0
while [ $i -lt "$NFS" ]; do
    cat > "$SH/fs_$i.frag" <<EOF
#version 450
layout(location = 0) in vec4 v[8];
layout(location = 0) out vec4 o;
void main() {
    vec4 c = vec4($i.0 / 997.0);
    for (int k = 0; k < $((8 + i % 24)); k++) c = fract(c * v[k & 7] + vec4($i.0 * 0.01));
    o = c;
}
EOF
    i=$((i+1))
done
ls "$SH"/fs_*.frag | xargs -P "$(sysctl -n hw.ncpu)" -I{} sh -c 'f="{}"; glslc -o "${f%.frag}.spv" "$f"'
echo "built $OUT/vk_cache_race; shaders in $SH"
