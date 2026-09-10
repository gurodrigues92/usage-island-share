#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
# Montado FORA do projeto de proposito. Enquanto o bundle ficava em ./dist, o
# LaunchServices indexava as duas copias e o app aparecia duplicado no Launchpad,
# no Spotlight e no seletor de Itens de Inicio. Alem disso ./dist mora no iCloud,
# de onde o codesign reclama de FinderInfo a cada empacotamento.
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/usage-island-XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
output_dir="${stage_dir}/Usage Island.app/Contents"

cd "$project_dir"
swift build -c release

mkdir -p "$output_dir/MacOS" "$output_dir/Resources"
cp ".build/release/UsageIsland" "$output_dir/MacOS/UsageIsland"
cp "App/Info.plist" "$output_dir/Info.plist"
# O icone vem de Scripts/gerar-icone.sh; sem ele o Finder mostra o bundle generico.
cp "App/AppIcon.icns" "$output_dir/Resources/AppIcon.icns"
# SwiftPM places processed images in this bundle. Keep it beside the executable so
# Bundle.module can load the provider marks in the packaged .app, not only in `swift run`.
rm -rf "$output_dir/Resources/UsageIsland_UsageIsland.bundle"
cp -R ".build/release/UsageIsland_UsageIsland.bundle" "$output_dir/Resources/"
chmod +x "$output_dir/MacOS/UsageIsland"
# Replacing the binary inside an existing bundle invalidates its signature and launchd
# refuses to spawn it ("Launch failed", POSIX 162). Re-sign every time.
# The copy picks up com.apple.FinderInfo from the iCloud-backed source tree, which codesign
# rejects outright ("resource fork, Finder information, or similar detritus not allowed"),
# so clear the extended attributes first.
xattr -cr "${output_dir:h}"

# Configure USAGE_ISLAND_SIGN_IDENTITY with your own Developer ID to retain
# Keychain authorization across builds. Without it, use ad hoc signing.
identidade="${USAGE_ISLAND_SIGN_IDENTITY:-}"
if [[ -n "$identidade" ]]; then
  codesign --force --deep --sign "$identidade" --options runtime "${output_dir:h}"
else
  print -u2 "aviso: identidade de assinatura nao encontrada; assinando ad hoc (o dialogo do keychain voltara a cada build)"
  codesign --force --deep --sign - "${output_dir:h}"
fi

# Install outside ~/Documents (iCloud): launched by launchd/`open` from there the app
# hangs on a TCC check for the Documents folder before its first window appears.
install_dir="$HOME/Applications"
mkdir -p "$install_dir"
rm -rf "$install_dir/Usage Island.app"
cp -R "${output_dir:h}" "$install_dir/"

# Restos de versoes antigas empacotadas dentro do projeto: desregistrar antes de
# apagar, senao o LaunchServices continua anunciando um caminho que nao existe.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -d "${project_dir}/dist" ]]; then
  [[ -x "$lsregister" ]] && "$lsregister" -u "${project_dir}/dist/Usage Island.app" 2>/dev/null || true
  rm -rf "${project_dir}/dist"
  print "Removida a copia duplicada em ./dist"
fi

print "Installed: $install_dir/Usage Island.app"
