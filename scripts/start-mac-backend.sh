#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd -P)"
JAVA_HOME_PATH="${PELAGIVEX_JAVA_HOME:-/Applications/PyCharm.app/Contents/jbr/Contents/Home}"
JAVA="$JAVA_HOME_PATH/bin/java"
PORT="${PELAGIVEX_PORT:-8767}"
THREADS="${PELAGIVEX_THREADS:-6}"
PROVIDER="${PELAGIVEX_PROVIDER:-coreml}"
INFERENCE_SLOTS="${PELAGIVEX_INFERENCE_SLOTS:-1}"
if [[ ! "$INFERENCE_SLOTS" =~ ^[1-4]$ ]]; then
  echo "PELAGIVEX_INFERENCE_SLOTS must be an integer from 1 to 4." >&2; exit 1
fi
INSTANCE="${PELAGIVEX_INSTANCE:-mac-backend}"
if [[ ! "$INSTANCE" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Invalid instance name." >&2; exit 1
fi
PID_FILE="$PROJECT_DIR/.tmp/$INSTANCE.pid"
LOG_FILE="$PROJECT_DIR/.tmp/$INSTANCE.log"
mkdir -p "$PROJECT_DIR/.tmp"
if [ -f "$PID_FILE" ]; then
  OLD_PID="$(cat "$PID_FILE")"
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Backend already running (PID $OLD_PID)."
    exit 0
  fi
fi
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use." >&2
  exit 1
fi
JARS=(
  .cache/maven/org/apache/tomcat/embed/tomcat-embed-core/9.0.112/tomcat-embed-core-9.0.112.jar
  .cache/maven/org/apache/tomcat/tomcat-annotations-api/9.0.112/tomcat-annotations-api-9.0.112.jar
  .cache/maven/com/microsoft/onnxruntime/onnxruntime/1.20.0/onnxruntime-1.20.0.jar
  .cache/maven/com/fasterxml/jackson/core/jackson-annotations/2.18.2/jackson-annotations-2.18.2.jar
  .cache/maven/com/fasterxml/jackson/core/jackson-core/2.18.2/jackson-core-2.18.2.jar
  .cache/maven/com/fasterxml/jackson/core/jackson-databind/2.18.2/jackson-databind-2.18.2.jar
  .cache/maven/com/drewnoakes/metadata-extractor/2.19.0/metadata-extractor-2.19.0.jar
  .cache/maven/com/adobe/xmp/xmpcore/6.1.11/xmpcore-6.1.11.jar
)
CP="target/classes:target/test-classes"
for jar in "${JARS[@]}"; do
  test -f "$jar" || { echo "Missing dependency: $jar" >&2; exit 1; }
  CP="$CP:$jar"
done
test -x "$JAVA" || { echo "Java not found: $JAVA" >&2; exit 1; }
test -f model/gate-v2.onnx || { echo "Model not found." >&2; exit 1; }
echo "$$" >"$PID_FILE"
echo "Starting backend on 127.0.0.1:$PORT (PID $$, $THREADS inference threads)."
export TMPDIR="$PROJECT_DIR/.tmp"
exec "$JAVA" -Xmx1g \
  -Djava.io.tmpdir="$PROJECT_DIR/.tmp" \
  -Dpelagivex.model.path="$PROJECT_DIR/model/gate-v2.onnx" \
  -Dpelagivex.threads="$THREADS" \
  -Dpelagivex.provider="$PROVIDER" \
  -Dpelagivex.maxConcurrentInferences="$INFERENCE_SLOTS" \
  -cp "$CP" com.pelagivex.LocalServer "$PORT" >>"$LOG_FILE" 2>&1
