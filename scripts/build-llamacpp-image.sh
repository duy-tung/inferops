#!/usr/bin/env bash
# IO-T005 (GPU gate G6, CPU fallback): builds the llama.cpp engine compose
# image from an ALREADY-BUILT llama-server binary — no llama.cpp source is
# read or vendored into this repo or the image; only the binary + its
# shared-library dependencies (identified via `ldd`, copied byte-for-byte)
# are packaged. This is not a "component source checkout" under
# docs/scope.md's forbidden-edges rule: that rule concerns portfolio
# components (infergate/vLLM/inferbench); llama.cpp is the third-party OSS
# CPU-path engine docs/architecture.md §2.3 names, consumed here as a
# pre-built artifact exactly as this repo consumes infergate's released
# images elsewhere.
#
# Pin: llama.cpp commit 8f114a9b573b69035299f9b924047f53c1e22c7e (recorded
# in docs/implementation-notes.md and the llamacpp Contract-4 capability
# descriptor infergate already ships,
# internal/backend/llamacpp/llamacpp.backend-capability.json). This script
# refuses to build against any other commit so the image tag always names
# the exact engine build it contains.
set -euo pipefail

LLAMACPP_REPO="${LLAMACPP_REPO:-/home/user/tools/llama.cpp}"
EXPECT_COMMIT="8f114a9b573b69035299f9b924047f53c1e22c7e"
BIN_DIR="$LLAMACPP_REPO/build/bin"
IMAGE_TAG="${IMAGE_TAG:-infergate-llamacpp-engine:8f114a9}"
# IO-T010 upgrade/rollback mechanics (scripts/upgrade.sh): set to build a
# second, genuinely distinct digest of the same binary+libs (a label-only
# rebuild — content-identical otherwise) so the upgrade/rollback procedure
# has a REAL digest to move to and back from, rather than infergate's own
# single-released-digest limitation (docs/testing.md's rolling-update-test.sh
# note). Empty by default (normal build, no extra label).
EXTRA_LABEL="${EXTRA_LABEL:-}"
COMPOSE_DIR="$(cd "$(dirname "$0")/../compose" && pwd)"
DOCKERFILE_DIR="$COMPOSE_DIR/llama-cpp"

echo "== 1/5: verifying llama.cpp pinned commit =="
ACTUAL_COMMIT="$(git -C "$LLAMACPP_REPO" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$EXPECT_COMMIT" ]]; then
  echo "FATAL: $LLAMACPP_REPO is at $ACTUAL_COMMIT, expected pinned $EXPECT_COMMIT" >&2
  exit 2
fi
echo "llama.cpp commit: $ACTUAL_COMMIT (matches pin)"

if [[ ! -x "$BIN_DIR/llama-server" ]]; then
  echo "FATAL: $BIN_DIR/llama-server not found or not executable — build llama.cpp first" >&2
  exit 2
fi

echo
echo "== 2/6: assembling build context (binary + ldd-identified shared libs only) =="
WORKDIR="$(mktemp -d)"
REG_NAME=""
cleanup() {
  rm -rf "$WORKDIR"
  [[ -n "$REG_NAME" ]] && docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
mkdir -p "$WORKDIR/bin"

cp -a "$BIN_DIR/llama-server" "$WORKDIR/bin/"
# Every shared-object dependency ldd resolves inside $BIN_DIR (i.e. not a
# system library already present in the base image) — copied with -a to
# preserve the SONAME symlink chain (libX.so -> libX.so.N -> libX.so.N.n.n).
for lib in $(ldd "$BIN_DIR/llama-server" | awk -v d="$BIN_DIR" '$3 ~ "^"d {print $1}'); do
  # Resolve the symlink chain from $BIN_DIR/$lib and copy every hop.
  target="$lib"
  while [[ -e "$BIN_DIR/$target" ]]; do
    cp -a "$BIN_DIR/$target" "$WORKDIR/bin/" 2>/dev/null || true
    [[ -L "$BIN_DIR/$target" ]] || break
    target="$(readlink "$BIN_DIR/$target")"
  done
done
echo "build context contents:"
ls -la "$WORKDIR/bin"

cp "$DOCKERFILE_DIR/Dockerfile" "$WORKDIR/Dockerfile"

echo
echo "== 3/6: docker build =="
# --provenance=false: an EARLIER run of this script (recorded honestly in
# docs/implementation-notes.md's IO-T005 entry) found that BuildKit's
# default provenance attestation embeds non-deterministic build metadata
# into the image's manifest LIST, changing `docker inspect .Id` on every
# rebuild of byte-identical inputs (verified: two back-to-back builds from
# the same context produced two different digests without this flag, and
# the SAME digest with it, twice in a row). Digest-pinning (docs/security.md
# §3) requires a reproducible digest, so this flag is not optional.
BUILD_ARGS=(--provenance=false)
if [[ -n "$EXTRA_LABEL" ]]; then
  BUILD_ARGS+=(--label "$EXTRA_LABEL")
  echo "(building with extra label: $EXTRA_LABEL — upgrade/rollback mechanics test build)"
fi
docker build "${BUILD_ARGS[@]}" -t "$IMAGE_TAG" "$WORKDIR"

echo
echo "== 4/6: recording image digest (docker inspect .Id) =="
IMAGE_ID="$(docker inspect --format='{{.Id}}' "$IMAGE_TAG")"
echo "image: $IMAGE_TAG"
echo "image id: $IMAGE_ID"

echo
echo "== 5/6: confirming the content-addressable digest via a throwaway local registry =="
# Same method docs/implementation-notes.md records for infergate's own
# images ("Digest verified by pushing to a local OCI registry and reading
# back the manifest digest"): push, then read RepoDigests back — proves
# $IMAGE_ID above really is the manifest digest, not just the local image
# ID (the two coincide for single-platform builds on this Docker version,
# but this step makes that a checked fact rather than an assumption).
REG_NAME="temp-registry-build-$$"
docker run -d --name "$REG_NAME" -p 5000:5000 registry:2 >/dev/null
sleep 2
REPO_LOCAL="localhost:5000/duy-tung/$(echo "$IMAGE_TAG" | cut -d: -f1)"
TAG_LOCAL="$(echo "$IMAGE_TAG" | cut -d: -f2)"
docker tag "$IMAGE_TAG" "$REPO_LOCAL:$TAG_LOCAL"
docker push "$REPO_LOCAL:$TAG_LOCAL" >/dev/null
CONFIRMED_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE_TAG" | sed -E 's#.*(sha256:[0-9a-f]+)#\1#')"
docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
REG_NAME=""
if [[ "$CONFIRMED_DIGEST" != "$IMAGE_ID" ]]; then
  echo "FATAL: registry-confirmed digest ($CONFIRMED_DIGEST) != docker inspect .Id ($IMAGE_ID)" >&2
  exit 2
fi
echo "confirmed content digest: $CONFIRMED_DIGEST"

echo
echo "== 6/6: recording model checksum =="
MODEL_PATH="${MODEL_PATH:-/home/user/tools/models/qwen2.5-1.5b-instruct-q4_k_m.gguf}"
MODEL_SHA="$(sha256sum "$MODEL_PATH" | awk '{print $1}')"
echo "model: $MODEL_PATH"
echo "model sha256: $MODEL_SHA"

echo
echo "== smoke: container starts and reports its own version =="
docker run --rm "$IMAGE_TAG" --version

cat <<SUMMARY

== SUMMARY (record these in docs/implementation-notes.md) ==
llama.cpp commit:      $ACTUAL_COMMIT
image tag:             $IMAGE_TAG
image id:              $IMAGE_ID
model path:            $MODEL_PATH
model sha256:          $MODEL_SHA
SUMMARY
