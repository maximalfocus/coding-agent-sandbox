#!/usr/bin/env bash
# Build architecture-native gh, Buildx, and Compose binaries from immutable upstream commits.
set -euo pipefail

OUT="${1:-/out}"
TARGET_OS="${TARGETOS:-linux}"
TARGET_ARCH="${TARGETARCH:-$(go env GOARCH)}"
: "${GH_SOURCE_COMMIT:?GH_SOURCE_COMMIT is required}"
: "${BUILDX_SOURCE_COMMIT:?BUILDX_SOURCE_COMMIT is required}"
: "${COMPOSE_SOURCE_COMMIT:?COMPOSE_SOURCE_COMMIT is required}"

[ "$(go version | awk '{print $3}')" = go1.26.5 ] || {
  echo "build-pinned-go-clis: exact Go 1.26.5 toolchain required" >&2; exit 1; }
case "$TARGET_ARCH" in amd64|arm64) ;; *) echo "unsupported TARGETARCH: $TARGET_ARCH" >&2; exit 1 ;; esac
mkdir -p "$OUT"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch_commit() {
  local repo="$1" commit="$2" dest="$3"
  git init -q "$dest"
  git -C "$dest" remote add origin "https://github.com/${repo}.git"
  git -C "$dest" fetch -q --depth 1 origin "$commit"
  git -C "$dest" checkout -q --detach FETCH_HEAD
  [ "$(git -C "$dest" rev-parse HEAD)" = "$commit" ] || {
    echo "commit verification failed for $repo" >&2; exit 1; }
}

fetch_commit cli/cli "$GH_SOURCE_COMMIT" "$work/gh"
(
  cd "$work/gh"
  CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" \
    go build -trimpath -ldflags "-s -w -X github.com/cli/cli/v2/internal/build.Version=2.96.1-source.${GH_SOURCE_COMMIT:0:12}" \
    -o "$OUT/gh" ./cmd/gh
)

fetch_commit docker/buildx "$BUILDX_SOURCE_COMMIT" "$work/buildx"
(
  cd "$work/buildx"
  # Upstream links docker/docker only for this frozen, non-security-sensitive name list.
  # Internalizing that package removes the vulnerable module from Go build metadata while
  # preserving Buildx behavior byte-for-byte at this seam.
  go mod download github.com/docker/docker
  docker_mod="$(go env GOPATH)/pkg/mod/github.com/docker/docker@v28.5.2+incompatible"
  mkdir -p internal/namesgenerator
  cp "$docker_mod/pkg/namesgenerator/names-generator.go" internal/namesgenerator/
  sed -i 's#github.com/docker/docker/pkg/namesgenerator#github.com/docker/buildx/internal/namesgenerator#' store/util.go
  go mod edit -droprequire github.com/docker/docker
  CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" \
    go build -mod=mod -trimpath \
    -ldflags "-s -w -X github.com/docker/buildx/version.Version=v0.36.0-rc1-source.${BUILDX_SOURCE_COMMIT:0:12} -X github.com/docker/buildx/version.Revision=$BUILDX_SOURCE_COMMIT" \
    -o "$OUT/docker-buildx" ./cmd/buildx
)

fetch_commit docker/compose "$COMPOSE_SOURCE_COMMIT" "$work/compose"
(
  cd "$work/compose"
  go mod edit -replace="github.com/docker/buildx=$work/buildx"
  CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" \
    go build -mod=mod -trimpath -tags=e2e \
    -ldflags "-s -w -X github.com/docker/compose/v5/internal.Version=v5.3.2-source.${COMPOSE_SOURCE_COMMIT:0:12}" \
    -o "$OUT/docker-compose" ./cmd
)

chmod 0755 "$OUT/gh" "$OUT/docker-buildx" "$OUT/docker-compose"

# Fail the build before binaries enter the runtime image if dependency/toolchain floors regress.
check_build_info() {
  local binary="$1" info
  info="$(go version -m "$binary")"
  grep -Fq $'\tbuild\tGOOS=linux' <<<"$info"
  grep -Fq "go1.26.5" <<<"$info"
  if grep -Fq $'\tdep\tgithub.com/docker/docker\t' <<<"$info"; then
    echo "build-pinned-go-clis: docker/docker remains linked in $binary" >&2; exit 1
  fi
}
check_build_info "$OUT/gh"
check_build_info "$OUT/docker-buildx"
check_build_info "$OUT/docker-compose"
grep -Fq $'\tdep\tgoogle.golang.org/grpc\tv1.82.1' < <(go version -m "$OUT/gh")
for binary in "$OUT/docker-buildx" "$OUT/docker-compose"; do
  grep -Fq $'\tdep\tgoogle.golang.org/grpc\tv1.82.1' < <(go version -m "$binary")
  grep -Eq $'\tdep\tgithub.com/containerd/containerd/v2\tv2\.(2\.5|[3-9]\.)' < <(go version -m "$binary")
done
