#!/usr/bin/env bash
# Upstream's buildapp.yml: theos-jailed build against the decrypted YouTube app, cyan
# injection with the Open in YouTube Safari extension, unresignable extensions stripped,
# alternate icons registered. Plus rootless/rootful jailbreak .debs.
source "$PIPELINE/lib/helpers.sh"

# Build settings (upstream's workflow inputs)
SDK=26.5 BUNDLE_ID=com.google.ios.youtube APP_NAME=YouTube YTUHD=0 SPONSORBLOCK=0

brew install wget jq meson ninja gnu-sed autoconf automake libtool pkgconf pngquant
setup_theos "$SDK" master aricloverALT/sdks
setup_theos_jailed qnblackcat/theos-jailed
# Theos broken pipe issue, as patched by upstream's workflow
grep -rlE '\| head' "$THEOS" --include='*.sh' --include='*.mk' | while read -r f; do
  sed -i '' 's/| head/2>\/dev\/null | head/g' "$f"
done
install_cyan
curl -fsSL https://github.com/inoahdev/tbd/releases/download/2.2/tbd-mac -o /usr/local/bin/tbd
chmod +x /usr/local/bin/tbd

export UYOU_VERSION=$(sed -nE 's/^UYOU_VERSION = (.+)/\1/p' Makefile | tr -d '\r')
unzip -q "$BASE_IPA"   # -> Payload/YouTube.app

[ -d modules/ffmpeg ] || bash Tools/fetch-ffmpegkit.sh   # restored from cache after the first build

log "Jailed build (YouTube $BASE_VERSION, uYou $UYOU_VERSION)"
sed -i '' "s/^BUNDLE_ID .*/BUNDLE_ID = $BUNDLE_ID/; s/^DISPLAY_NAME .*/DISPLAY_NAME = $APP_NAME/; s/^export TARGET .*/export TARGET = iphone:clang:$SDK:15.0/" Makefile
make package THEOS_PACKAGE_SCHEME=rootless IPA=Payload/YouTube.app FINALPACKAGE=1 \
  YTUHD_ENABLED=$YTUHD SPONSORBLOCK_ENABLED=$SPONSORBLOCK
PKG="packages/$(ls -t packages | head -n1)"

git clone --quiet -n --depth=1 --filter=tree:0 https://github.com/BillyCurtis/OpenYouTubeSafariExtension.git "$RUNNER_TEMP/ext"
git -C "$RUNNER_TEMP/ext" sparse-checkout set --no-cone OpenYouTubeSafariExtension.appex
git -C "$RUNNER_TEMP/ext" checkout --quiet

OUTNAME="$OUT/uYouEnhanced_${BASE_VERSION}_v$UYOU_VERSION.ipa"
tweaks=("$RUNNER_TEMP/ext/OpenYouTubeSafariExtension.appex")
for f in packages/*.deb; do [ -f "$f" ] && tweaks+=("$f"); done
cyan -i "$PKG" -o "$OUTNAME" -uwef "${tweaks[@]}" -n "$APP_NAME" -b "$BUNDLE_ID"

log "Stripping extensions SideStore can't re-sign"
{ unzip -Z1 "$OUTNAME" | grep '\.appex/' | sed 's|^\(.*\.appex\)/.*|\1|' | sort -u | grep -v '/PlugIns/' || true; } |
  while IFS= read -r d; do echo "Removing $d"; zip -q -d "$OUTNAME" "${d}/*" || true; done
if unzip -Z1 "$OUTNAME" | grep '/SC_Info/' >/dev/null; then
  zip -q -d "$OUTNAME" "Payload/*/SC_Info/*" "Payload/*/SC_Info" || true
fi

log "Registering alternate app icons"
W="$RUNNER_TEMP/iconwork"; rm -rf "$W"; mkdir -p "$W/icons"
PLIST="Payload/YouTube.app/Info.plist"
(cd "$W" && unzip -q "$OUTNAME" "$PLIST")
for f in Localizations/uYouPlus.bundle/AppIcons/*.png; do
  name="$(basename "$f")"
  pngquant --quality=80-95 --strip --skip-if-larger "$f" --output "$W/icons/$name" >/dev/null 2>&1 || true
  [ -f "$W/icons/$name" ] || cp -f "$f" "$W/icons/$name"
done
(
  cd "$W"
  for f in icons/*.png; do
    SPEC="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$f" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} /hasAlpha/{a=$2} END{print w"x"h" alpha="a}')"
    case "$SPEC" in
      "1024x1024 alpha=no"*) ;;
      *) echo "::error::$(basename "$f") is $SPEC; app icons must be 1024x1024 opaque PNGs"; exit 1 ;;
    esac
  done
  PB=/usr/libexec/PlistBuddy
  for ROOT in CFBundleIcons "CFBundleIcons~ipad"; do
    $PB -c "Add :$ROOT dict" "$PLIST" 2>/dev/null || true
    $PB -c "Add :$ROOT:CFBundleAlternateIcons dict" "$PLIST" 2>/dev/null || true
  done
  for f in icons/*.png; do
    NAME="$(basename "$f" .png)"
    cp -f "$f" "Payload/YouTube.app/$NAME.png"
    for ROOT in CFBundleIcons "CFBundleIcons~ipad"; do
      $PB -c "Add :$ROOT:CFBundleAlternateIcons:$NAME dict" "$PLIST" 2>/dev/null || true
      $PB -c "Add :$ROOT:CFBundleAlternateIcons:$NAME:CFBundleIconFiles array" "$PLIST" 2>/dev/null || true
      $PB -c "Add :$ROOT:CFBundleAlternateIcons:$NAME:CFBundleIconFiles:0 string $NAME" "$PLIST" 2>/dev/null || true
    done
  done
  zip -q "$OUTNAME" "$PLIST" Payload/YouTube.app/*.png
)

log "Jailbreak .debs"
rm -rf packages .theos
make package JAILBROKEN=1 THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
rm -rf .theos
make package JAILBROKEN=1 FINALPACKAGE=1
cp packages/*.deb "$OUT/"
