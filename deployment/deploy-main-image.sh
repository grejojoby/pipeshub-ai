#!/usr/bin/env bash
# Build the app image from one commit of grejojoby/pipeshub-ai and recreate
# only the pipeshub-ai service from that image.
#
# The published upstream image is about 11GB and the release workflow builds it
# on a 200GB runner this fork does not have, so the build runs on the server
# (the machine that will run the image). Source bind mounts under
# salesforce-fix/ are removed on success: they pin older files over the image
# and are how a recreate drops code that was only copied into the container.
#
# Usage: deploy-main-image.sh <git-sha>
set -euo pipefail

SHA="${1:?commit sha required}"
ROOT=/root/pipeshub
SRC=/root/pipeshub/src/pipeshub-ai
LOCK=/var/lock/pipeshub-deploy-main.lock
IMAGE_REPO=pipeshub-main
CONTAINER=pipeshub-ai-pipeshub-ai-1
ENV_FILE="$ROOT/.env"
COMPOSE="$ROOT/docker-compose.yml"

if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "refusing sha that is not a full commit id: $SHA" >&2
  exit 1
fi

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "another main-image deploy is already running" >&2
  exit 1
fi

avail_kb=$(df -Pk / | awk 'NR==2 {print $4}')
need_kb=$((40 * 1024 * 1024))
if [ "$avail_kb" -lt "$need_kb" ]; then
  echo "need 40G free on /, have $((avail_kb / 1024 / 1024))G" >&2
  exit 1
fi

mkdir -p "$(dirname "$SRC")"
if [ ! -d "$SRC/.git" ]; then
  GIT_TERMINAL_PROMPT=0 git clone --filter=blob:none https://github.com/grejojoby/pipeshub-ai.git "$SRC"
fi
GIT_TERMINAL_PROMPT=0 git -C "$SRC" fetch --depth 1 origin "$SHA"
git -C "$SRC" checkout --force --detach FETCH_HEAD
echo "checked out $(git -C "$SRC" rev-parse HEAD)"

BACKUP="$ROOT/.deploy-backups/$SHA"
mkdir -p "$BACKUP"
cp "$ENV_FILE" "$BACKUP/env"
cp "$COMPOSE" "$BACKUP/compose.yml"

prev_image=$(grep -E '^PIPESHUB_IMAGE=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)
prev_tag=$(grep -E '^IMAGE_TAG=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)
prev_image=${prev_image:-pipeshubai/pipeshub-ai}
prev_tag=${prev_tag:-latest}
printf '%s\n' "$prev_image" > "$BACKUP/prev_image"
printf '%s\n' "$prev_tag" > "$BACKUP/prev_tag"
echo "current image is ${prev_image}:${prev_tag}"

echo "building ${IMAGE_REPO}:${SHA}"
ionice -c 3 nice -n 19 docker build \
  --progress=plain \
  --build-arg PYTHON_DEPS_IMAGE=pipeshubai/pipeshub-ai-base:python-deps \
  --build-arg RUNTIME_BASE_IMAGE=pipeshubai/pipeshub-ai-base:runtime \
  --build-arg GIT_COMMIT="$SHA" \
  -t "${IMAGE_REPO}:${SHA}" \
  -t "${IMAGE_REPO}:main" \
  "$SRC"

restore_frontend_overlay() {
  # The upstream image does not contain the fork frontend. If we have to go
  # back to it, put the last built static export back into the container.
  if [ "$prev_image" != "pipeshubai/pipeshub-ai" ] || [ ! -d "$ROOT/frontend-out-new" ]; then
    return 0
  fi
  docker exec "$CONTAINER" bash -lc 'rm -rf /app/backend/dist/public/*'
  docker cp "$ROOT/frontend-out-new/." "$CONTAINER:/app/backend/dist/public/"
}

rollback() {
  echo "rolling back to ${prev_image}:${prev_tag}" >&2
  cp "$BACKUP/env" "$ENV_FILE"
  cp "$BACKUP/compose.yml" "$COMPOSE"
  (
    cd "$ROOT"
    docker compose -p pipeshub-ai up -d --no-deps --force-recreate pipeshub-ai
  )
  restore_frontend_overlay || echo "frontend overlay restore failed" >&2
}

switch_to_built_image() {
  python3 - "$ENV_FILE" "$COMPOSE" "$IMAGE_REPO" "$SHA" <<'PY'
import sys
from pathlib import Path

env_path, compose_path, image_repo, sha = sys.argv[1:]

def upsert(text: str, key: str, value: str) -> str:
    lines = text.splitlines(keepends=True)
    prefix = key + "="
    found = False
    out = []
    for line in lines:
        body = line[:-1] if line.endswith("\n") else line
        nl = "\n" if line.endswith("\n") else ""
        if body.startswith(prefix):
            out.append(f"{key}={value}\n")
            found = True
        else:
            out.append(body + (nl or "\n"))
    if not found:
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append(f"{key}={value}\n")
    return "".join(out)

env = Path(env_path).read_text()
env = upsert(env, "PIPESHUB_IMAGE", image_repo)
env = upsert(env, "IMAGE_TAG", sha)
Path(env_path).write_text(env)

drop = (
    "salesforce-fix/connector.py:",
    "salesforce-fix/neo4j_provider.py:",
    "salesforce-fix/router.py:",
)
compose_lines = Path(compose_path).read_text().splitlines(keepends=True)
kept = [line for line in compose_lines if not any(part in line for part in drop)]
removed = len(compose_lines) - len(kept)
Path(compose_path).write_text("".join(kept))
print(f"removed {removed} source bind mount(s)")
PY
}

echo "switching compose to ${IMAGE_REPO}:${SHA}"
switch_to_built_image

if ! (
  cd "$ROOT"
  docker compose -p pipeshub-ai up -d --no-deps --force-recreate pipeshub-ai
); then
  rollback
  exit 1
fi

running_image=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")
if [ "$running_image" != "${IMAGE_REPO}:${SHA}" ]; then
  echo "container is running ${running_image}, expected ${IMAGE_REPO}:${SHA}" >&2
  rollback
  exit 1
fi

if docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$CONTAINER" | grep -q 'salesforce-fix/'; then
  echo "source bind mounts are still attached; the image is not what is running" >&2
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
  echo "new image did not become healthy" >&2
  rollback
  exit 1
fi

if ! docker exec "$CONTAINER" python3 -c '
import glob, sys
found = False
for path in glob.glob("/app/backend/dist/public/_next/static/chunks/*.js"):
    if "sobject_names" in open(path, errors="ignore").read():
        found = True
        break
sys.exit(0 if found else 1)
'; then
  echo "built frontend is missing the Salesforce object picker" >&2
  rollback
  exit 1
fi

if ! docker exec "$CONTAINER" grep -q "scrollable list" /app/python/app/connectors/sources/salesforce/connector.py; then
  echo "built image is missing the Salesforce connector description" >&2
  rollback
  exit 1
fi

curl -sf -o /dev/null http://127.0.0.1:3000/
echo "deployed ${IMAGE_REPO}:${SHA}"
