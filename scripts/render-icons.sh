#!/bin/bash
# Regenerates the app's icon assets from Branding/*.svg.
# Needs rsvg-convert (brew install librsvg). The PNGs are committed, so normal
# builds don't need this; run it only after editing the SVGs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/Sources/App/Assets.xcassets"
command -v rsvg-convert >/dev/null || { echo "error: rsvg-convert required (brew install librsvg)" >&2; exit 1; }

ICONSET="$ASSETS/AppIcon.appiconset"
mkdir -p "$ICONSET"
entries=()
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        px=$((size * scale))
        name="icon_${size}x${size}@${scale}x.png"
        rsvg-convert -w $px -h $px "$ROOT/Branding/app-icon.svg" -o "$ICONSET/$name"
        entries+=("    { \"idiom\" : \"mac\", \"size\" : \"${size}x${size}\", \"scale\" : \"${scale}x\", \"filename\" : \"$name\" }")
    done
done
joined=$(printf '%s,\n' "${entries[@]}")
cat > "$ICONSET/Contents.json" <<EOF
{
  "images" : [
${joined%,}
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

MENUBAR="$ASSETS/MenuBarIcon.imageset"
mkdir -p "$MENUBAR"
cp "$ROOT/Branding/menubar.svg" "$MENUBAR/menubar.svg"
cat > "$MENUBAR/Contents.json" <<'EOF'
{
  "images" : [ { "idiom" : "universal", "filename" : "menubar.svg" } ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : {
    "template-rendering-intent" : "template",
    "preserves-vector-representation" : true
  }
}
EOF

cat > "$ASSETS/Contents.json" <<'EOF'
{ "info" : { "author" : "xcode", "version" : 1 } }
EOF

rsvg-convert -w 512 "$ROOT/Branding/logo.svg" -o "$ROOT/Branding/logo-512.png"
echo "Icons written to $ASSETS"
