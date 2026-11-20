#!/bin/zsh
set -euo pipefail

usage() {
  print "Uso: Scripts/package-app.sh [--archive caminho.zip [--universal]]"
  print "O modo --archive gera um ZIP sem instalar ou abrir o app."
}

archive=""
universal=0
while (( $# )); do
  case "$1" in
    --archive)
      if (( $# < 2 )) || [[ "$2" != *.zip || -n "$archive" ]]; then usage >&2; exit 2; fi
      archive="${2:a}"
      shift 2 ;;
    --universal) universal=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if (( universal )) && [[ -z "$archive" ]]; then usage >&2; exit 2; fi

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
mkdir -p "$output_dir/MacOS" "$output_dir/Resources"
executable="$output_dir/MacOS/UsageIsland"
if (( universal )); then
  binaries=()
  for arch in arm64 x86_64; do
    swift build -c release --arch "$arch" --product UsageIsland
    bin_dir="$(swift build -c release --arch "$arch" --show-bin-path)"
    # SwiftPM can reuse the same output path for both builds.
    cp "$bin_dir/UsageIsland" "$stage_dir/UsageIsland-$arch"
    xcrun lipo "$stage_dir/UsageIsland-$arch" -verify_arch "$arch"
    binaries+=("$stage_dir/UsageIsland-$arch")
  done
  xcrun lipo -create "${binaries[@]}" -output "$executable"
  for arch in arm64 x86_64; do
    xcrun lipo "$executable" -verify_arch "$arch"
  done
else
  swift build -c release --product UsageIsland
  bin_dir="$(swift build -c release --show-bin-path)"
  cp "$bin_dir/UsageIsland" "$executable"
fi
cp "App/Info.plist" "$output_dir/Info.plist"
cp THIRD_PARTY_NOTICES.md "$output_dir/Resources/"
# O icone vem de Scripts/gerar-icone.sh; sem ele o Finder mostra o bundle generico.
cp "App/AppIcon.icns" "$output_dir/Resources/AppIcon.icns"
# SwiftPM places processed images in this bundle. Keep it beside the executable so
# Bundle.module can load the provider marks in the packaged .app, not only in `swift run`.
rm -rf "$output_dir/Resources/UsageIsland_UsageIsland.bundle"
cp -R "$bin_dir/UsageIsland_UsageIsland.bundle" "$output_dir/Resources/"
chmod +x "$output_dir/MacOS/UsageIsland"
if [[ -n "$archive" ]]; then
  xcrun strip -S "$executable"
fi
# Replacing the binary inside an existing bundle invalidates its signature and launchd
# refuses to spawn it ("Launch failed", POSIX 162). Re-sign every time.
# The copy picks up com.apple.FinderInfo from the iCloud-backed source tree, which codesign
# rejects outright ("resource fork, Finder information, or similar detritus not allowed"),
# so clear the extended attributes first.
xattr -cr "${output_dir:h}"

# Assinar com Developer ID faz a permissão do Keychain sobreviver ao rebuild
# (ACL casa pelo requisito designado, não pelo cdhash). A identidade pode vir
# de USAGE_ISLAND_SIGN_IDENTITY; se a variável estiver vazia, usa a primeira
# "Developer ID Application" do keychain. Sem nenhuma, cai no ad hoc.
identidade="${USAGE_ISLAND_SIGN_IDENTITY:-}"
if [[ -z "$identidade" ]]; then
  identidade="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi
if [[ -n "$identidade" ]]; then
  print "assinando com: $identidade"
  sign_options=(--options runtime)
  if [[ -n "$archive" ]]; then sign_options+=(--timestamp); fi
  codesign --force --deep --sign "$identidade" "${sign_options[@]}" "${output_dir:h}"
else
  print -u2 "aviso: identidade de assinatura nao encontrada; assinando ad hoc (o dialogo do keychain voltara a cada build)"
  codesign --force --deep --sign - "${output_dir:h}"
fi

codesign --verify --deep --strict "${output_dir:h}"

if [[ -n "$archive" ]]; then
  app="${output_dir:h}"
  zip="$stage_dir/release.zip"
  notary_args=()
  if [[ -n "${USAGE_ISLAND_NOTARY_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$USAGE_ISLAND_NOTARY_PROFILE")
  elif [[ -n "${USAGE_ISLAND_NOTARY_KEY_FILE:-}" || -n "${USAGE_ISLAND_NOTARY_KEY_ID:-}" || -n "${USAGE_ISLAND_NOTARY_ISSUER:-}" ]]; then
    : "${USAGE_ISLAND_NOTARY_KEY_FILE:?Informe o arquivo da chave do App Store Connect}"
    : "${USAGE_ISLAND_NOTARY_KEY_ID:?Informe o identificador da chave do App Store Connect}"
    notary_args=(--key "$USAGE_ISLAND_NOTARY_KEY_FILE" --key-id "$USAGE_ISLAND_NOTARY_KEY_ID")
    if [[ -n "${USAGE_ISLAND_NOTARY_ISSUER:-}" ]]; then notary_args+=(--issuer "$USAGE_ISLAND_NOTARY_ISSUER"); fi
  elif [[ -e "$project_dir/.git" ]]; then
    profile="$(git -C "$project_dir" config --local --get usageisland.notaryProfile || true)"
    if [[ -n "$profile" ]]; then notary_args=(--keychain-profile "$profile"); fi
  fi
  pack_zip() {
    /usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn "$app" "$zip"
  }
  pack_zip
  if (( ${#notary_args} )); then
    xcrun notarytool submit "$zip" "${notary_args[@]}" --wait --output-format json > "$stage_dir/notarization.json"
    if [[ "$(plutil -extract status raw "$stage_dir/notarization.json")" != Accepted ]]; then
      cat "$stage_dir/notarization.json" >&2
      exit 1
    fi
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    rm "$zip"
    pack_zip
  else
    print -u2 "Notarização não solicitada. Use USAGE_ISLAND_NOTARY_PROFILE ou as variáveis da chave do App Store Connect para notarizar."
  fi
  mkdir -p "${archive:h}"
  mv "$zip" "$archive"
  print "Arquivo: $archive"
  exit 0
fi

# Install outside ~/Documents (iCloud): launched by launchd/`open` from there the app
# hangs on a TCC check for the Documents folder before its first window appears.
install_dir="$HOME/Applications"
mkdir -p "$install_dir"
backup_dir="${USAGE_ISLAND_BACKUP_DIR:-$HOME/.local/share/usage-island-backups}"
mkdir -p "$backup_dir"
backup_app="$backup_dir/Usage Island-$(date +%Y%m%d-%H%M%S)-$$.app"
if [[ -d "$install_dir/Usage Island.app" ]]; then
  mv "$install_dir/Usage Island.app" "$backup_app"
fi
if ! mv "${output_dir:h}" "$install_dir/Usage Island.app"; then
  [[ -d "$backup_app" ]] && mv "$backup_app" "$install_dir/Usage Island.app"
  exit 1
fi

# Restos de versoes antigas empacotadas dentro do projeto: desregistrar antes de
# apagar, senao o LaunchServices continua anunciando um caminho que nao existe.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -d "${project_dir}/dist" ]]; then
  [[ -x "$lsregister" ]] && "$lsregister" -u "${project_dir}/dist/Usage Island.app" 2>/dev/null || true
  rm -rf "${project_dir}/dist"
  print "Removida a copia duplicada em ./dist"
fi

print "Installed: $install_dir/Usage Island.app"
