#!/usr/bin/env bash
# CI 用：把 GitHub secrets 裡的 keystore 寫成 android/key.properties（android/app/build.gradle 會讀取）
# 需要的 secrets：ANDROID_KEYSTORE_BASE64、ANDROID_KEYSTORE_PASSWORD、ANDROID_KEY_ALIAS，
# 選用 ANDROID_KEY_PASSWORD（沒設定時與 ANDROID_KEYSTORE_PASSWORD 相同）
set -euo pipefail
: "${ANDROID_KEYSTORE_BASE64:?}" "${ANDROID_KEYSTORE_PASSWORD:?缺少 ANDROID_KEYSTORE_PASSWORD}" "${ANDROID_KEY_ALIAS:?缺少 ANDROID_KEY_ALIAS}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$ROOT/android/app/opview-release.jks"
cat > "$ROOT/android/key.properties" <<PROPS
storeFile=opview-release.jks
storePassword=${ANDROID_KEYSTORE_PASSWORD}
keyAlias=${ANDROID_KEY_ALIAS}
keyPassword=${ANDROID_KEY_PASSWORD:-$ANDROID_KEYSTORE_PASSWORD}
PROPS
echo "已設定固定簽章（alias：${ANDROID_KEY_ALIAS}）"
