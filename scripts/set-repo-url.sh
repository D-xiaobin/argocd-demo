#!/usr/bin/env bash
# 把仓库里所有 YOUR_GITHUB_USER 占位符替换成你的 GitHub 用户名（或完整仓库地址）
# 用法:
#   ./scripts/set-repo-url.sh yourname
#   ./scripts/set-repo-url.sh https://github.com/yourname/argocd-demo.git
set -euo pipefail

INPUT="${1:-}"
PLACEHOLDER="https://github.com/YOUR_GITHUB_USER/argocd-demo.git"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "$INPUT" ]]; then
  echo "用法: $0 <github用户名 | 完整仓库地址>" >&2
  exit 1
fi

if [[ "$INPUT" == http* ]]; then
  NEW_URL="$INPUT"
else
  NEW_URL="https://github.com/${INPUT}/argocd-demo.git"
fi

echo "仓库根目录: $ROOT"
echo "替换为: $NEW_URL"
echo

mapfile -t FILES < <(grep -rl "$PLACEHOLDER" "$ROOT" --include='*.yaml' --include='*.yml' --include='*.md' || true)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "没有找到占位符（可能已经替换过）"
  exit 0
fi

printf '  %s\n' "${FILES[@]#$ROOT/}"
echo
read -r -p "确认替换 ${#FILES[@]} 个文件？[y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

for f in "${FILES[@]}"; do
  sed -i.bak "s|${PLACEHOLDER}|${NEW_URL}|g" "$f"
  rm -f "${f}.bak"
done

echo "✅ 完成，检查一下:"
grep -rn "repoURL" "$ROOT" --include='*.yaml' | grep -v YOUR_GITHUB_USER | head -10
