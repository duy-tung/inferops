# inferops — llama.cpp engine image (IO-T005, GPU gate G6 CPU fallback).
#
# Packages an ALREADY-BUILT llama-server binary (upstream llama.cpp, no
# portfolio-component source involved) into a minimal runnable image. See
# scripts/build-llamacpp-image.sh (which assembles the build context this
# Dockerfile is run against: bin/llama-server + the exact shared libraries
# `ldd` reports it needs from its own build directory — no other files, no
# llama.cpp source).
#
# Base pinned by digest (docs/security.md §3 "deploy by digest only" —
# applied here too, not only to released component images): matches the
# glibc the binary was linked against (Ubuntu 24.04 host, glibc 2.39;
# verified via `ldd --version` at build time, docs/implementation-notes.md).
FROM ubuntu@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

RUN apt-get update && \
    apt-get install -y --no-install-recommends libgomp1 libssl3t64 ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

COPY bin/ /usr/local/lib/llama.cpp/
RUN ln -s /usr/local/lib/llama.cpp/llama-server /usr/local/bin/llama-server

ENV LD_LIBRARY_PATH=/usr/local/lib/llama.cpp

# Non-root, matching the released infergate images' own posture
# (docs/security.md; infergate's Dockerfile runs as a non-root user).
RUN useradd --system --no-create-home --uid 10001 llamacpp
USER 10001:10001

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/llama-server"]
