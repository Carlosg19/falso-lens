#!/usr/bin/env bash
# Builds a self-contained whisper-cli (no homebrew dylibs) into BundledResources/Bin/.
# Idempotent: regenerates only when version-pin changes or output is missing.

set -euo pipefail

WHISPER_VERSION="${WHISPER_VERSION:-v1.8.4}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build/whisper.cpp"
DEST="$REPO_ROOT/BundledResources/Bin/whisper-cli"

mkdir -p "$REPO_ROOT/BundledResources/Bin"

if [ ! -d "$BUILD_DIR" ]; then
    git clone --depth 1 --branch "$WHISPER_VERSION" \
        https://github.com/ggerganov/whisper.cpp.git "$BUILD_DIR"
fi

cmake -S "$BUILD_DIR" -B "$BUILD_DIR/build" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR/build" --config Release --target whisper-cli -j

cp "$BUILD_DIR/build/bin/whisper-cli" "$DEST"
chmod +x "$DEST"

if otool -L "$DEST" | grep -E "@rpath|/opt/" >/dev/null; then
    echo "ERROR: non-system dylib deps remain in $DEST" >&2
    otool -L "$DEST" >&2
    exit 1
fi

echo "✅ Built $DEST ($(du -h "$DEST" | cut -f1))"
