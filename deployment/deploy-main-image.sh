#!/usr/bin/env bash
# Keep the published pipeshubai/pipeshub-ai image and mount this repo's app
# diffs over it. The published image is about 11GB of Python packages, ML
# models, browsers, and Office libraries. Rebuilding it does not carry user
# data (that lives in Neo4j, Mongo, Qdrant, and Redis) and is the wrong thing
# to do on every push.
#
# Usage: deploy-main-image.sh <git-sha>
set -euo pipefail

SHA="${1:?commit sha required}"
ROOT=/root/pipeshub
SRC=/root/pipeshub/src/pipeshub-ai
LOCK=/var/lock/pipeshub-deploy-main.lock
CONTAINER=pipeshub-ai-pipeshub-ai-1
ENV_FILE="$ROOT/.env"
COMPOSE="$ROOT/docker-compose.yml"
OVERLAY="$ROOT/repo-overlay"
BASE_IMAGE=pipeshubai/pipeshub-ai
BASE_TAG=latest

if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "refusing sha that is not a full commit id: $SHA" >&2
  exit 1
fi

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "another deploy is already running" >&2
  exit 1
fi

mkdir -p "$(dirname "$SRC")" "$OVERLAY"
if [ ! -d "$SRC/.git" ]; then
  GIT_TERMINAL_PROMPT=0 git clone --filter=blob:none https://github.com/grejojoby/pipeshub-ai.git "$SRC"
fi
GIT_TERMINAL_PROMPT=0 git -C "$SRC" fetch --depth 1 origin "$SHA"
git -C "$SRC" checkout --force --detach FETCH_HEAD
echo "checked out $(git -C "$SRC" rev-parse HEAD)"

install -m 644 \
  "$SRC/backend/python/app/connectors/sources/salesforce/connector.py" \
  "$OVERLAY/connector.py"
install -m 644 \
  "$SRC/backend/python/app/connectors/api/router.py" \
  "$OVERLAY/router.py"
install -m 644 \
  "$SRC/backend/python/app/services/graph_db/neo4j/neo4j_provider.py" \
  "$OVERLAY/neo4j_provider.py"
install -m 644 \
  "$SRC/backend/python/app/connectors/core/base/data_processor/data_source_entities_processor.py" \
  "$OVERLAY/data_source_entities_processor.py"

if [ ! -d "$ROOT/frontend-out-new/_next" ]; then
  echo "missing $ROOT/frontend-out-new (built frontend). Refusing to drop the UI." >&2
  exit 1
fi

BACKUP="$ROOT/.deploy-backups/$SHA"
mkdir -p "$BACKUP"
cp "$ENV_FILE" "$BACKUP/env"
cp "$COMPOSE" "$BACKUP/compose.yml"

rollback() {
  echo "rolling back compose and image settings" >&2
  cp "$BACKUP/env" "$ENV_FILE"
  cp "$BACKUP/compose.yml" "$COMPOSE"
  (
    cd "$ROOT"
    docker compose -p pipeshub-ai up -d --no-deps --force-recreate pipeshub-ai
  )
  if [ -d "$ROOT/frontend-out-new/_next" ]; then
    docker exec "$CONTAINER" bash -lc 'rm -rf /app/backend/dist/public/*' || true
    docker cp "$ROOT/frontend-out-new/." "$CONTAINER:/app/backend/dist/public/" || true
  fi
}

python3 - "$ENV_FILE" "$COMPOSE" "$BASE_IMAGE" "$BASE_TAG" <<'PY'
import sys
from pathlib import Path

env_path, compose_path, image, tag = sys.argv[1:]

def upsert(text: str, key: str, value: str) -> str:
    lines = text.splitlines(keepends=True)
    prefix = key + "="
    found = False
    out = []
    for line in lines:
        body = line[:-1] if line.endswith("\n") else line
        if body.startswith(prefix):
            out.append(f"{key}={value}\n")
            found = True
        else:
            out.append(body + "\n")
    if not found:
        out.append(f"{key}={value}\n")
    return "".join(out)

env = Path(env_path).read_text()
env = upsert(env, "PIPESHUB_IMAGE", image)
env = upsert(env, "IMAGE_TAG", tag)
Path(env_path).write_text(env)

drop = ("salesforce-fix/", "repo-overlay/", "frontend-out-new:")
compose = Path(compose_path).read_text().splitlines(keepends=True)
kept = [line for line in compose if not any(part in line for part in drop)]
mounts = [
    "      - ./repo-overlay/connector.py:/app/python/app/connectors/sources/salesforce/connector.py:ro\n",
    "      - ./repo-overlay/router.py:/app/python/app/connectors/api/router.py:ro\n",
    "      - ./repo-overlay/neo4j_provider.py:/app/python/app/services/graph_db/neo4j/neo4j_provider.py:ro\n",
    "      - ./repo-overlay/data_source_entities_processor.py:/app/python/app/connectors/core/base/data_processor/data_source_entities_processor.py:ro\n",
    "      - ./frontend-out-new:/app/backend/dist/public:ro\n",
]
inserted = False
out = []
for line in kept:
    out.append(line)
    if "pipeshub_hf_cache:/root/.cache/huggingface" in line and not inserted:
        out.extend(mounts)
        inserted = True
if not inserted:
    raise SystemExit("could not find the huggingface volume line to attach overlays")
Path(compose_path).write_text("".join(out))
print(f"image {image}:{tag}; mounted {len(mounts)} overlay paths")
PY

echo "recreating pipeshub-ai on ${BASE_IMAGE}:${BASE_TAG} with repo overlays"
if ! (
  cd "$ROOT"
  docker compose -p pipeshub-ai up -d --no-deps --force-recreate pipeshub-ai
); then
  rollback
  exit 1
fi

running=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")
case "$running" in
  "${BASE_IMAGE}:${BASE_TAG}"|*"${BASE_IMAGE}"*) ;;
  *)
    echo "container is running ${running}, expected ${BASE_IMAGE}" >&2
    rollback
    exit 1
    ;;
esac

healthy=0
for _ in $(seq 1 40); do
  status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || echo missing)
  echo "health=${status}"
  if [ "$status" = healthy ]; then
    healthy=1
    break
  fi
  if [ "$status" = unhealthy ] || [ "$status" = missing ]; then
    break
  fi
  sleep 15
done

if [ "$healthy" != 1 ]; then
  echo "overlay deploy did not become healthy" >&2
  rollback
  exit 1
fi

if ! docker exec "$CONTAINER" grep -q "scrollable list" /app/python/app/connectors/sources/salesforce/connector.py; then
  echo "Salesforce connector overlay is not the file from the repo" >&2
  rollback
  exit 1
fi

curl -sf -o /dev/null http://127.0.0.1:3000/
echo "deployed ${BASE_IMAGE}:${BASE_TAG} with overlays from ${SHA}"
