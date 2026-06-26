#!/bin/bash
# setup-metallib.sh - 将 MLX metallib 复制到 SPM 构建产物目录
# 用法：bash Scripts/setup-metallib.sh [--build debug/release]
#
# MLX 运行时会在二进制同目录查找 mlx.metallib，SPM 不自动编译 metal shaders
# 此脚本从系统查找预编译的 metallib 并复制到位

set -euo pipefail

BUILD_TYPE="${1:--build}"
# 解析 --build 参数
if [ "${#}" -ge 2 ]; then
    BUILD_TYPE="$2"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBUG_DIR="$REPO_ROOT/.build/arm64-apple-macosx/debug"
RELEASE_DIR="$REPO_ROOT/.build/arm64-apple-macosx/release"

echo "🔧 MLX metallib setup..."

# 查找系统可用的 prebuilt metallib
METALLIB_PATH=""
CANDIDATES=(
    "/opt/homebrew/lib/python3.11/site-packages/mlx/lib/mlx.metallib"
    "/opt/homebrew/Cellar/*/libexec/lib/python3.11/site-packages/mlx/lib/mlx.metallib"
    "$HOME/Library/Caches/pypoetry/virtualenvs/*/lib/python3.11/site-packages/mlx/lib/mlx.metallib"
)

for candidate in "${CANDIDATES[@]}"; do
    if [ -f "$candidate" ]; then
        METALLIB_PATH="$candidate"
        break
    fi
done

if [ -z "$METALLIB_PATH" ]; then
    echo "❌ 未找到 mlx.metallib。请安装 MLX Python 包: pip install mlx"
    exit 1
fi

echo "   源路径: $METALLIB_PATH"

copy_to() {
    local target_dir="$1"
    if [ -d "$target_dir" ]; then
        src_mtime="$(stat -f '%m' "$METALLIB_PATH" 2>/dev/null || stat -c '%Y' "$METALLIB_PATH" 2>/dev/null)"
        dst_mtime="$(stat -f '%m' "$target_dir/mlx.metallib" 2>/dev/null || echo "0")"
        if [ "$dst_mtime" -lt "$src_mtime" ]; then
            cp "$METALLIB_PATH" "$target_dir/mlx.metallib"
            echo "   ✅ 复制到 $target_dir"
        else
            echo "   ⏭️  $target_dir 已是最新"
        fi
    fi
}

# 根据参数或默认处理 debug + release
case "$BUILD_TYPE" in
    debug)
        copy_to "$DEBUG_DIR"
        ;;
    release)
        copy_to "$RELEASE_DIR"
        ;;
    *)
        copy_to "$DEBUG_DIR"
        copy_to "$RELEASE_DIR"
        ;;
esac

echo "✅ Metallib setup complete"
