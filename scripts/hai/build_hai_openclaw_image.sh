#!/bin/bash
set -euo pipefail

# 切换到仓库根目录（脚本位于 scripts/hai/）
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

### --- 1. 从源码提取版本号 --- ###
VERSION_FILE="package.json"

if [[ -f "version" ]]; then
    RAW_VERSION=$(sed 's/["{}]//g' version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
elif [[ -f "$VERSION_FILE" ]]; then
    if command -v jq >/dev/null 2>&1; then
        RAW_VERSION=$(jq -r '.version // empty' "$VERSION_FILE")
    else
        RAW_VERSION=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_FILE")
    fi
else
    echo "Error: Neither package.json nor version file found!" >&2
    exit 1
fi

RAW_VERSION=$(echo "$RAW_VERSION" | tr -d '[:space:]')

if [[ -z "$RAW_VERSION" ]]; then
    echo "Error: Failed to extract version!" >&2
    exit 1
fi

echo "Version: $RAW_VERSION"

### --- 2. 构建基础镜像 openclaw:local --- ###
echo "Step 1/2: Building openclaw:local from root Dockerfile..."
docker build -t openclaw:local -f Dockerfile .

### --- 3. 构建 hai-openclaw 镜像 --- ###
IMAGE_NAME="hepai/hai-openclaw:$RAW_VERSION"
echo "Step 2/2: Building $IMAGE_NAME from Dockerfile.hepai..."
docker build -t "$IMAGE_NAME" -f scripts/hai/Dockerfile.hepai .

echo "Done: $IMAGE_NAME"
