#!/bin/bash
# Builds Resources/VexIME.apk (the Android input method) without Gradle.
# Needs: JAVA_HOME (JDK 17+), BUILD_TOOLS (Android build-tools dir), ANDROID_JAR (platforms/android-36/android.jar).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${JAVA_HOME:?set JAVA_HOME}" "${BUILD_TOOLS:?set BUILD_TOOLS}" "${ANDROID_JAR:?set ANDROID_JAR}"
export PATH="$JAVA_HOME/bin:$PATH"

SRC=android/vexime
OUT=build/vexime
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/res" "$OUT/dex"

"$BUILD_TOOLS/aapt2" compile --dir "$SRC/res" -o "$OUT/res/compiled.zip"
"$BUILD_TOOLS/aapt2" link -o "$OUT/unsigned.apk" -I "$ANDROID_JAR" \
  --manifest "$SRC/AndroidManifest.xml" "$OUT/res/compiled.zip"

javac --release 11 -nowarn -classpath "$ANDROID_JAR" -d "$OUT/classes" $(find "$SRC/src" -name '*.java')
"$BUILD_TOOLS/d8" --release --min-api 26 --lib "$ANDROID_JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
(cd "$OUT/dex" && zip -q -u ../unsigned.apk classes.dex)

"$BUILD_TOOLS/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

KEY=build/vexime-debug.keystore
[ -f "$KEY" ] || keytool -genkeypair -keystore "$KEY" -storepass vexplayer -keypass vexplayer \
  -alias vexime -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=VexPlayer IME" >/dev/null 2>&1
# Forks sign with their own key; the app reinstalls VexIME when signatures differ.
"$BUILD_TOOLS/apksigner" sign --ks "$KEY" --ks-pass pass:vexplayer --key-pass pass:vexplayer \
  --v4-signing-enabled false --out Resources/VexIME.apk "$OUT/aligned.apk"
"$BUILD_TOOLS/apksigner" verify Resources/VexIME.apk
echo "Built Resources/VexIME.apk ($(wc -c < Resources/VexIME.apk) bytes)"
