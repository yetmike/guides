FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
# The scheduler and verify self-check gates the image.
RUN CGO_ENABLED=0 go vet . && CGO_ENABLED=0 go test . && CGO_ENABLED=0 go build -trimpath -o /loadgen .

FROM gcr.io/distroless/static
COPY --from=build /loadgen /loadgen
ENTRYPOINT ["/loadgen"]
