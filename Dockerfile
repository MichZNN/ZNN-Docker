# syntax=docker/dockerfile:1
#
# go-zenon (znnd) + producer-keygen, built from the official source at a git tag.
#
#   docker build --build-arg ZNN_VERSION=v0.0.9-alphanet -t go-zenon:v0.0.9-alphanet .
#
# Building from the tagged source (instead of downloading release binaries)
# works for both amd64 and arm64 and lets us compile producer-keygen against
# exactly the same go-zenon code as znnd.

ARG GO_VERSION=1.24
ARG DEBIAN_VERSION=bookworm

############################
# Build stage
############################
FROM golang:${GO_VERSION}-${DEBIAN_VERSION} AS build

ARG ZNN_VERSION
ARG ZNN_REPO=https://github.com/zenon-network/go-zenon.git
RUN test -n "${ZNN_VERSION}" || (echo "ZNN_VERSION build-arg is required" && exit 1)

WORKDIR /src
RUN git clone --depth 1 --branch "${ZNN_VERSION}" "${ZNN_REPO}" go-zenon \
 && git -C go-zenon rev-parse HEAD > /src/commit.txt

WORKDIR /src/go-zenon
COPY tools/producer-keygen/main.go cmd/producer-keygen/main.go

# znnd needs cgo (C compiler is included in the golang image).
ENV CGO_ENABLED=1
RUN go build -trimpath -ldflags "-s -w" -o /out/znnd ./cmd/znnd \
 && go build -trimpath -ldflags "-s -w" -o /out/producer-keygen ./cmd/producer-keygen \
 && /out/znnd version

############################
# Runtime stage
############################
FROM debian:${DEBIAN_VERSION}-slim

ARG ZNN_VERSION
ARG ZNN_UID=1000
ARG ZNN_GID=1000

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g "${ZNN_GID}" znn \
 && useradd -m -u "${ZNN_UID}" -g "${ZNN_GID}" -s /usr/sbin/nologin znn \
 && mkdir -p /home/znn/.znn \
 && chown -R znn:znn /home/znn

COPY --from=build /out/znnd /out/producer-keygen /usr/local/bin/
COPY --from=build /src/commit.txt /usr/local/share/go-zenon-commit.txt

LABEL org.opencontainers.image.title="go-zenon" \
      org.opencontainers.image.description="Zenon Network node (znnd) with producer-keygen" \
      org.opencontainers.image.source="https://github.com/zenon-network/go-zenon" \
      org.opencontainers.image.version="${ZNN_VERSION}"

USER znn
WORKDIR /home/znn
VOLUME ["/home/znn/.znn"]

# 35995 = p2p (tcp+udp), 35997 = HTTP-RPC, 35998 = WS-RPC (defaults)
EXPOSE 35995/tcp 35995/udp 35997/tcp 35998/tcp

ENTRYPOINT ["znnd", "--data", "/home/znn/.znn", "--wallet", "/home/znn/.znn/wallet"]
