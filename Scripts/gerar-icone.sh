#!/bin/zsh
# Unica fonte do icone: tudo (iconset, .icns, previews) sai daqui — nao editar PNG na mao.
#
# O desenho e derivado do proprio app, nao inventado: a barra preta com pontas em capsula e a
# silhueta da ilha, o trilho e o mesmo #2E2E2E dos aneis, e as tres cores sao os limiares
# semanticos (verde < 45, amarelo 45-69, vermelho >= 70). As tres porcentagens desenhadas
# (21 / 52 / 73) são valores ilustrativos para os anéis do ícone.
#
# Duas armadilhas do ImageMagick medidas aqui:
#   - `-strokelinecap` nao existe como opcao de linha de comando; e primitiva MVG, tem que ir
#     DENTRO do -draw ("stroke-linecap round");
#   - `-annotate` sem `-font` explicito falha com "unable to read font ''" nesta instalacao.
set -euo pipefail

variante="${1:-ilha}"          # ilha | anel
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
work="$(mktemp -d "${TMPDIR:-/tmp}/usage-island-icone-XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Fundo comum: squircle aproximado (raio 22,4% do lado, como o grid da Apple) em preto
# levantado, com uma borda de 12% de branco pra ilha nao sumir em Dock escuro.
fundo=(
  -size 1024x1024 xc:none
  -fill '#111111' -stroke none -draw "roundrectangle 0,0 1023,1023 230,230"
  -fill none -stroke 'rgba(255,255,255,0.12)' -strokewidth 6 -draw "roundrectangle 3,3 1020,1020 228,228"
)

case "$variante" in
  ilha)
    magick "${fundo[@]}" \
      -fill '#000000' -stroke 'rgba(255,255,255,0.06)' -strokewidth 3 \
      -draw "roundrectangle 352,96 672,928 160,160" \
      -draw "stroke-linecap round
             fill none stroke #262626 stroke-width 30
             ellipse 512,282 104,104 0,360
             ellipse 512,512 104,104 0,360
             ellipse 512,742 104,104 0,360
             stroke #00FF8B ellipse 512,282 104,104 -90,-14
             stroke #F3FD00 ellipse 512,512 104,104 -90,97
             stroke #FF4001 ellipse 512,742 104,104 -90,173" \
      "$work/1024.png"
    ;;
  anel)
    magick "${fundo[@]}" \
      -draw "stroke-linecap round
             fill none stroke #262626 stroke-width 92
             ellipse 512,512 300,300 0,360
             stroke #FF4001 ellipse 512,512 300,300 118,186
             stroke #F3FD00 ellipse 512,512 300,300 26,118
             stroke #00FF8B ellipse 512,512 300,300 -90,26" \
      "$work/1024.png"
    ;;
  *) print -u2 "Variante desconhecida: $variante (use ilha ou anel)"; exit 1 ;;
esac

iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for par in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
           "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  px="${par%% *}"; nome="${par##* }"
  magick "$work/1024.png" -resize ${px}x${px} "$iconset/icon_${nome}.png"
done

iconutil -c icns "$iconset" -o "$project_dir/App/AppIcon.icns"
cp "$work/1024.png" "$project_dir/App/AppIcon-1024.png"
print "Gerado ($variante): App/AppIcon.icns e App/AppIcon-1024.png"
