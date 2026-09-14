#!/usr/bin/env bash
# Publica una versión nueva de El Furbo en GitHub Releases.
#
#   tool/release.sh 0.2.0 [--notes "Qué cambió"]
#
# 1. Sube `version:` en pubspec.yaml (versionName X.Y.Z, versionCode +1).
# 2. Compila los APK de release con --split-per-abi (firmados con la clave de
#    debug de esta PC, cuyo SHA-1 está registrado en Firebase).
# 3. Commitea el bump, crea el tag vX.Y.Z y la release con los APK adjuntos.
#
# La app consulta /releases/latest y ofrece el APK de su ABI, así que con esto
# alcanza para que los teléfonos se enteren (en primer o segundo plano).
set -euo pipefail

cd "$(dirname "$0")/.."

NEW_VERSION="${1:-}"
NOTES=""
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    *) echo "Argumento desconocido: $1" >&2; exit 1 ;;
  esac
done

if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Uso: tool/release.sh X.Y.Z [--notes \"texto\"]" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Hay cambios sin commitear. Commitea o descarta antes de publicar." >&2
  exit 1
fi

# El repo es de la cuenta personal; gh (y el push, que usa su credencial)
# pueden tener otra cuenta activa. Se cambia ahora y se restaura al salir.
ORIGINAL_ACCOUNT="$(gh api user -q .login 2>/dev/null || true)"
if [[ "$ORIGINAL_ACCOUNT" != "yt-kevincarrera" ]]; then
  gh auth switch --user yt-kevincarrera
fi
trap '[[ -n "$ORIGINAL_ACCOUNT" && "$ORIGINAL_ACCOUNT" != "yt-kevincarrera" ]] && gh auth switch --user "$ORIGINAL_ACCOUNT" >/dev/null 2>&1 || true' EXIT

CURRENT_LINE="$(grep -E '^version:' pubspec.yaml)"
CURRENT_BUILD="$(echo "$CURRENT_LINE" | sed -nE 's/.*\+([0-9]+).*/\1/p')"
NEW_BUILD=$(( ${CURRENT_BUILD:-0} + 1 ))
sed -i -E "s/^version:.*/version: ${NEW_VERSION}+${NEW_BUILD}/" pubspec.yaml
echo "pubspec.yaml -> version: ${NEW_VERSION}+${NEW_BUILD}"

flutter pub get
flutter build apk --release --split-per-abi

OUT=build/app/outputs/flutter-apk
ls -1 "$OUT"/app-*-release.apk

git add pubspec.yaml
git commit -m "Versión ${NEW_VERSION} (build ${NEW_BUILD})"
git tag "v${NEW_VERSION}"
git push origin HEAD "v${NEW_VERSION}"

NOTES_ARGS=(--generate-notes)
if [[ -n "$NOTES" ]]; then
  NOTES_ARGS=(--notes "$NOTES")
fi
gh release create "v${NEW_VERSION}" \
  --repo yt-kevincarrera/elfurbo \
  --title "El Furbo ${NEW_VERSION}" \
  "${NOTES_ARGS[@]}" \
  "$OUT"/app-*-release.apk

echo "Listo: https://github.com/yt-kevincarrera/elfurbo/releases/tag/v${NEW_VERSION}"
