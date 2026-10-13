#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$project_root"
windows_root="${CAOCODE_WINDOWS_DIR:-/mnt/c/Users/11914/Documents/Caocode}"
mode='Release'
sync_only=false
doctor=false
installer=false
for argument in "$@"; do
    case "$argument" in
        --debug) mode='Debug' ;;
        --sync-only) sync_only=true ;;
        --doctor) doctor=true ;;
        --installer) installer=true ;;
        --help|-h)
            printf '用法：./build.sh [--debug | --sync-only | --doctor | --installer]\n'
            exit 0 ;;
        *) printf '未知选项：%s\n' "$argument" >&2; exit 2 ;;
    esac
done
if [[ "$sync_only" == false && "$doctor" == false ]]; then
    ./flutterw analyze --no-fatal-infos --no-fatal-warnings lib packages test tool
fi
python3 tool/caocode/sync_windows.py --target "$windows_root"
if [[ "$sync_only" == true ]]; then
    exit 0
fi
build_arguments=(-Mode "$mode")
if [[ "$doctor" == true ]]; then
    build_arguments+=(-DoctorOnly)
fi
if [[ "$installer" == true ]]; then
    if [[ "$mode" != 'Release' || "$doctor" == true ]]; then
        printf '安装包仅支持 Release 编译\n' >&2
        exit 2
    fi
    build_arguments+=(-Installer)
fi
pwsh -NoLogo -NoProfile -NonInteractive -File \
    "$(wslpath -w "$windows_root/tool/caocode/build-windows.ps1")" \
    "${build_arguments[@]}"
