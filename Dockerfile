# Builder image, rebuilt by build.sh on every run (layer-cached).
FROM docker.io/library/debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
# gnupg2 is needed on the BUILDER (mmdebstrap cannot infer signed-by without
# it); curl fetches third-party apt keys before mmdebstrap runs.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential crossbuild-essential-arm64 debhelper bc bison flex rsync \
    kmod cpio libssl-dev libgnutls28-dev uuid-dev libdw-dev libelf-dev \
    libpython3-dev python3-pyelftools python3-setuptools swig \
    device-tree-compiler git ca-certificates curl gnupg2 mmdebstrap arch-test \
    e2fsprogs fdisk util-linux pigz \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 build-inner.sh /usr/local/bin/build-inner
WORKDIR /build
ENTRYPOINT ["/usr/local/bin/build-inner"]
