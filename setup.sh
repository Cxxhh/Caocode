#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$project_root"
flutter_sdk="${CAOCODE_FLUTTER_SDK:-${XDG_DATA_HOME:-$HOME/.local/share}/caocode/flutter-3.47.5}"
windows_root="${CAOCODE_WINDOWS_DIR:-/mnt/c/Users/11914/Documents/Caocode}"
command -v git >/dev/null
command -v python3 >/dev/null
command -v pwsh >/dev/null
if [[ ! -d "$flutter_sdk" ]]; then
    mkdir -p "$(dirname -- "$flutter_sdk")"
    git clone --depth 1 --branch 3.47.5 https://github.com/flutter/flutter.git "$flutter_sdk"
fi
actual_revision="$(git -C "$flutter_sdk" rev-parse HEAD)"
if [[ "$actual_revision" != '6a19cca56475dbfba1478ee68d7bd0c2ef891da1' ]]; then
    printf 'Flutter SDK 版本不匹配：%s\n' "$actual_revision" >&2
    exit 1
fi
if ! git -C "$flutter_sdk" symbolic-ref -q HEAD >/dev/null; then
    git -C "$flutter_sdk" switch -c stable
fi
./flutterw config --no-analytics
./flutterw pub get
python3 tool/caocode/sync_windows.py --target "$windows_root"
pwsh -NoLogo -NoProfile -NonInteractive -File \
    "$(wslpath -w "$windows_root/tool/caocode/setup-windows.ps1")"
printf '\n环境就绪。运行 ./build.sh 完成增量同步和 Windows 编译。\n'
