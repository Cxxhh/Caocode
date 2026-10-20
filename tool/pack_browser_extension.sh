#!/usr/bin/env bash
# Packs browser_extension/ (Caocode's extension, see its background.js) in
# two zips, in build/browser_extension/:
#
#   Caocode-browser-<version>.zip         to load unpacked (developer mode):
#                                         its manifest keeps "key", so it
#                                         has the store's id, the one
#                                         Caocode lets in
#   Caocode-browser-<version>-store.zip   for the Chrome Web Store, which
#                                         takes no "key"
#
#   tool/pack_browser_extension.sh
#   tool/pack_browser_extension.sh --first-upload
#                                         the store's zip with key.pem too,
#                                         the private key the id comes from
#                                         (~/.caocode-signing/
#                                         browser-extension.pem): the store
#                                         keeps the id of the first upload's
#                                         key.pem. Never for another upload,
#                                         never published.
#
# Prints the zips' paths. Needs zip and jq.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
source="$root/browser_extension"
out="$root/build/browser_extension"
first_upload=false
for arg in "$@"; do
  case $arg in
    --first-upload) first_upload=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

version=$(jq -r .version "$source/manifest.json")
[[ "$version" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] || { echo "manifest.json: version $version" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out/unpacked" "$out/store"
# What the extension is made of, nothing else beside it.
files=(manifest.json background.js icons _locales)
for dir in unpacked store; do
  (cd "$source" && cp -R "${files[@]}" "$out/$dir/")
done
jq 'del(.key)' "$source/manifest.json" > "$out/store/manifest.json"
if $first_upload; then
  key=${CAOCODE_EXTENSION_KEY:-$HOME/.caocode-signing/browser-extension.pem}
  # PKCS#8, as Chrome writes it (BEGIN PRIVATE KEY): the store cannot read
  # an RSA one (BEGIN RSA PRIVATE KEY). The same key, the id the same.
  openssl pkcs8 -topk8 -nocrypt -in "$key" -out "$out/store/key.pem"
fi

# The same bytes for the same files: no times, sorted.
pack() {
  local dir=$1 zip=$2
  find "$dir" -exec touch -t 202001010000 {} +
  (cd "$dir" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | zip -qX -@ "$zip")
}
pack "$out/unpacked" "$out/Caocode-browser-$version.zip"
pack "$out/store" "$out/Caocode-browser-$version-store.zip"
rm -rf "$out/unpacked" "$out/store"

echo "$out/Caocode-browser-$version.zip"
echo "$out/Caocode-browser-$version-store.zip"
