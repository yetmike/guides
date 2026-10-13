# warp v1.8.2 (the Docker Hub image is stuck at v1.3.1) plus fio for the disk
# baseline. Built like upstream's goreleaser config.
FROM golang:1.26 AS build
ARG WARP_TAG=v1.8.2
ARG WARP_COMMIT=d9f7173e8c9bebfcde20b36760883f3fb79055dc
RUN git clone --depth 1 --branch "$WARP_TAG" https://github.com/minio/warp /src
WORKDIR /src
RUN test "$(git rev-parse HEAD)" = "$WARP_COMMIT"
RUN CGO_ENABLED=0 go build -trimpath -tags kqueue -ldflags "-s -w \
      -X github.com/minio/warp/pkg.ReleaseTag=$WARP_TAG -X github.com/minio/warp/pkg.Version=${WARP_TAG#v} \
      -X github.com/minio/warp/pkg.CommitID=$WARP_COMMIT" -o /warp . \
 && /warp --version

FROM alpine:3.22
RUN apk add --no-cache fio && fio --version
COPY --from=build /warp /usr/local/bin/warp
