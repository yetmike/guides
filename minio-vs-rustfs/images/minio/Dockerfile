# MinIO community edition, built from the last community tag. MinIO stopped
# publishing images and binaries on 2025-10-15 ("source only"), so this is the
# only way to run that release. Nothing is patched: clone the tag, check the
# commit, build the way the upstream Makefile does (`make build`), with the
# release tag stamped in the way upstream's release build did.
FROM golang:1.24.8 AS build
ARG MINIO_TAG=RELEASE.2025-10-15T17-29-55Z
ARG MINIO_COMMIT=9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a
RUN git clone --depth 1 --branch "$MINIO_TAG" https://github.com/minio/minio /src
WORKDIR /src
RUN test "$(git rev-parse HEAD)" = "$MINIO_COMMIT"
# gen-ldflags.go wants the tag's time as 2025-10-15T17:29:55Z.
RUN v=$(echo "$MINIO_TAG" | sed -E 's/^RELEASE\.(.*T[0-9]+)-([0-9]+)-([0-9]+Z)$/\1:\2:\3/') \
 && CGO_ENABLED=0 go build -tags kqueue -trimpath \
      --ldflags "$(MINIO_RELEASE=RELEASE go run buildscripts/gen-ldflags.go "$v")" -o /minio . \
 && /minio --version

FROM gcr.io/distroless/static-debian12
COPY --from=build /minio /usr/bin/minio
COPY --from=build /src/LICENSE /src/NOTICE /src/CREDITS /licenses/
ENTRYPOINT ["/usr/bin/minio"]
