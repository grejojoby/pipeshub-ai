#!/usr/bin/env bash
# Deploy the app module onto the published image.
#
# Stable module (not rebuilt): pipeshubai/pipeshub-ai — Python packages,
# Hugging Face models, Playwright, NLTK, fastembed, LibreOffice, Node.
# App module: deployment/modules/Dockerfile.app. It only copies the Salesforce
# connector, the stats files, and the built frontend. Docker reuses the
# stable layers, so this build is a file copy rather than an 11GB rebuild.
#
# The repo's full Python tree is 400+ commits ahead of the published image
# and does not import against that image's libraries. Router and Neo4j are
# taken from the repo only when a smoke import succeeds; otherwise the copies
# already running on the server are baked into the app module.
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
BASE_IMAGE=pipeshubai/pipeshub-ai:latest
APP_IMAGE=pipeshub-app
STAGE="$ROOT/modules/app-context"
FRONTEND_MOD="$ROOT/modules/frontend"
STAMP="$FRONTEND_MOD/source.stamp"

if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "refusing sha that is not a full commit id: $SHA" >&2
  exit 1
fi

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "another deploy is already running" >&2
  exit 1
fi

mkdir -p "$(dirname "$SRC")" "$STAGE" "$FRONTEND_MOD"
if [ ! -d "$SRC/.git" ]; then
  GIT_TERMINAL_PROMPT=0 git clone --filter=blob:none https://github.com/grejojoby/pipeshub-ai.git "$SRC"
fi
GIT_TERMINAL_PROMPT=0 git -C "$SRC" fetch --depth 1 origin "$SHA"
git -C "$SRC" checkout --force --detach FETCH_HEAD
echo "checked out $(git -C "$SRC" rev-parse HEAD)"

frontend_tree=$(git -C "$SRC" rev-parse HEAD:frontend)
if [ ! -d "$ROOT/frontend-out-new/_next" ] || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$frontend_tree" ]; then
  if [ ! -d "$ROOT/frontend-out-new/_next" ] || [ -f "$STAMP" ]; then
    echo "building frontend module (stable node_modules cache)"
    mkdir -p "$FRONTEND_MOD/node_modules" "$ROOT/frontend-out-new"
    docker run --rm \
      -v "$SRC/frontend:/app/frontend" \
      -v "$FRONTEND_MOD/node_modules:/app/frontend/node_modules" \
      -w /app/frontend \
      -e ELECTRON_STATIC=1 \
      -e NODE_OPTIONS=--max-old-space-size=3072 \
      node:20-slim \
      bash -lc 'npm config set legacy-peer-deps true && if [ ! -x node_modules/.bin/next ]; then npm ci; fi && npm run build'
    rm -rf "$ROOT/frontend-out-new"
    mkdir -p "$ROOT/frontend-out-new"
    cp -a "$SRC/frontend/out/." "$ROOT/frontend-out-new/"
  fi
fi
printf '%s\n' "$frontend_tree" > "$STAMP"

if [ ! -d "$ROOT/frontend-out-new/_next" ]; then
  echo "frontend module is missing a build" >&2
  exit 1
fi

prepare_context() {
  local router_src="$1"
  local neo_src="$2"
  rm -rf "$STAGE"
  mkdir -p "$STAGE/public"
  cp "$SRC/deployment/modules/Dockerfile.app" "$STAGE/Dockerfile"
  cp "$SRC/backend/python/app/connectors/sources/salesforce/connector.py" "$STAGE/connector.py"
  cp "$router_src" "$STAGE/router.py"
  cp "$neo_src" "$STAGE/neo4j_provider.py"
  cp -a "$ROOT/frontend-out-new/." "$STAGE/public/"
}

build_app() {
  docker build --pull=false \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "GIT_COMMIT=${SHA}" \
    -t "${APP_IMAGE}:${SHA}" \
    -t "${APP_IMAGE}:main" \
    "$STAGE"
}

smoke() {
  docker run --rm --network none --entrypoint python3 \
    -e PYTHONPATH=/app/python "${APP_IMAGE}:${SHA}" \
    -c "import app.connectors.sources.salesforce.connector; import app.connectors.api.router; print('smoke-ok')"
}

echo "building app module from repo files"
prepare_context \
  "$SRC/backend/python/app/connectors/api/router.py" \
  "$SRC/backend/python/app/services/graph_db/neo4j/neo4j_provider.py"
build_app
if ! smoke; then
  echo "repo router does not import on the stable image; using the running stats files"
  if [ ! -f "$ROOT/salesforce-fix/router.py" ] || [ ! -f "$ROOT/salesforce-fix/neo4j_provider.py" ]; then
    echo "no known-good stats files to fall back to" >&2
    exit 1
  fi
  prepare_context "$ROOT/salesforce-fix/router.py" "$ROOT/salesforce-fix/neo4j_provider.py"
  build_app
  smoke
fi

BACKUP="$ROOT/.deploy-backups/$SHA"
mkdir -p "$BACKUP"
cp "$ENV_FILE" "$BACKUP/env"
cp "$COMPOSE" "$BACKUP/compose.yml"

rollback() {
  echo "rolling back to the previous compose" >&2
  cp "$BACKUP/env" "$ENV_FILE"
  cp "$BACKUP/compose.yml" "$COMPOSE"
  (
    cd "$ROOT"
    docker compose -p pipeshub-ai up -d --no-deps --force-recreate pipeshub-ai
  )
}

python3 - "$ENV_FILE" "$COMPOSE" "$APP_IMAGE" "$SHA" <<'PY'
import sys
from pathlib import Path

env_path, compose_path, image, tag = sys.argv[1:]

def upsert(text: str, key: str, value: str) -> str:
    lines = text.splitlines()
    prefix = key + "="
    found = False
    out = []
    for line in lines:
        if line.startswith(prefix):
            out.append(f"{key}={value}")
            found = True
        else:
            out.append(line)
    if not found:
        out.append(f"{key}={value}")
    return "\n".join(out) + "\n"

env = upsert(Path(env_path).read_text(), "PIPESHUB_IMAGE", image)
env = upsert(env, "IMAGE_TAG", tag)
Path(env_path).write_text(env)

drop = ("salesforce-fix/", "repo-overlay/", "frontend-out-new:")
compose = Path(compose_path).read_text().splitlines(keepends=True)
kept = [line for line in compose if not any(part in line for part in drop)]
Path(compose_path).write_text("".join(kept))
print(f"image {image}:{tag}; removed source bind mounts so the app module is what runs")
PY

echo "recreating pipeshub-ai from ${APP_IMAGE}:${SHA}"
if ! (
  cd "$ROOT"
  docker compose -p pipeshub-ai up -d --no-deps --force-recreate pipeshub-ai
); then
  rollback
  exit 1
fi

running=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")
if [ "$running" != "${APP_IMAGE}:${SHA}" ]; then
  echo "container is running ${running}, expected ${APP_IMAGE}:${SHA}" >&2
  rollback
  exit 1
fi

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
  echo "app module did not become healthy" >&2
  rollback
  exit 1
fi

if ! docker exec "$CONTAINER" grep -q "scrollable list" /app/python/app/connectors/sources/salesforce/connector.py; then
  echo "app module is missing the Salesforce connector" >&2
  rollback
  exit 1
fi

curl -sf -o /dev/null http://127.0.0.1:3000/
echo "deployed app module ${APP_IMAGE}:${SHA} on stable image ${BASE_IMAGE}"
