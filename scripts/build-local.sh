#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLEID_DEFAULT='com.zqbb.Dopamine-roothide'
BUNDLEID="${BUNDLEID:-$BUNDLEID_DEFAULT}"

# Always use the roothide Theos checkout.
# (This repo requires the 'roothide' package scheme.)
THEOS="$HOME/theos-roothide"
export THEOS

need_bin() {
  local b="$1"
  if ! command -v "$b" >/dev/null 2>&1; then
    echo "ERROR: missing required tool: $b" >&2
    return 1
  fi
}

echo "== Environment =="
need_bin git
need_bin gmake
need_bin ldid
need_bin plutil
need_bin xcodebuild
need_bin xcrun

echo "BUNDLEID=$BUNDLEID"
echo "THEOS=$THEOS"

echo "== Submodules =="
git submodule update --init --recursive

echo "== Pre trustcache =="
if command -v trustcache >/dev/null 2>&1; then
  echo "Using existing trustcache: $(command -v trustcache)"
else
  rm -rf trustcache
  git clone https://github.com/CRKatri/trustcache
  pushd trustcache >/dev/null

  gmake OPENSSL=1 \
  CFLAGS="-I$(brew --prefix openssl)/include" \
  LDFLAGS="-L$(brew --prefix openssl)/lib" \
  PKG_CONFIG_PATH="$(brew --prefix openssl)/lib/pkgconfig"

  # build.yml installs to /opt/procursus/bin, but avoid sudo prompts locally.
  if [ -d /opt/procursus/bin ] && [ -w /opt/procursus/bin ]; then
    install -m 0755 trustcache /opt/procursus/bin/trustcache
    export PATH="/opt/procursus/bin:$PATH"
  elif command -v brew >/dev/null 2>&1; then
    install -m 0755 trustcache "$(brew --prefix)/bin/trustcache"
  else
    install -m 0755 trustcache "./trustcache"
    export PATH="$PWD:$PATH"
  fi

  popd >/dev/null
  need_bin trustcache
fi

echo "== Pre env =="
sT=$(TZ=UTC-8 date +'%S')
msT=$(TZ=UTC-8 date -j -f "%Y-%m-%d %H:%M:%S" "$(TZ=UTC-8 date +'%Y-%m-%d %H:%M'):${sT}" +%s)
shT=$(TZ=UTC-8 date +'%Y.%m.%d/%H.%M').${sT}
logT=$(TZ=UTC-8 date +'%Y年%m月%d %H:%M'):${sT}
SHASH=$(git rev-parse --short HEAD)

export msT shT logT SHASH

echo "msT=$msT"
echo "shT=$shT"
echo "logT=$logT"
echo "SHASH=$SHASH"

echo "== Pre Version =="
orig_version=$(cat ./BaseBin/_external/basebin/.version)
commitCount="${COMMIT_COUNT:-}"
if [ -z "$commitCount" ]; then
  # Faster than cloning an external repo; uses the current repo's history.
  commitCount=$(git rev-list --count HEAD)
fi

if [ -z "$commitCount" ]; then
  echo "ERROR: commitCount empty" >&2
  exit 1
fi

echo "$orig_version.$commitCount.${msT}" > ./BaseBin/_external/basebin/.version
newVERSION=$(cat ./BaseBin/_external/basebin/.version)
export newVERSION

echo "newVERSION=$newVERSION"

echo "== Pre theos =="
if [ ! -d "$THEOS" ] || [ ! -d "$THEOS/makefiles" ]; then
  echo "ERROR: THEOS not found (expected at: $THEOS)" >&2
  echo "Please install Theos (roothide) to $THEOS, or set THEOS=/path/to/theos." >&2
  exit 1
fi

SDK_DIR="$THEOS/sdks/iPhoneOS16.5.sdk"
if [ ! -d "$SDK_DIR" ]; then
  echo "ERROR: missing Theos SDK: $SDK_DIR" >&2
  echo "Please install iPhoneOS16.5.sdk under $THEOS/sdks/" >&2
  exit 1
fi

echo "Using THEOS=$THEOS"

echo "== Build tipa =="
export THEOS

gmake NIGHTLY=0

OUT="Dopamine_roothide_whitelist_${newVERSION}_${SHASH}.tipa"
rm -f "$OUT"
mv Application/Dopamine.tipa "$OUT"

echo "== DONE =="
echo "Built: $OUT"
