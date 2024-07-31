# syntax=docker/dockerfile:1.4

# Build the manager binary
ARG builder_image

# Build architecture
ARG ARCH

# Loader flags
ARG ldflags

FROM ${builder_image} as builder

WORKDIR /workspace
COPY . .

RUN go mod vendor

# Build the manager using the compiler cache folder
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${ARCH} \
    go build -trimpath -ldflags "${ldflags} -extldflags '-static'"\
    -o /workspace/manager .

FROM gcr.io/distroless/static:nonroot-${ARCH}
WORKDIR /
COPY --from=builder /workspace/manager .
# Use uid of nonroot user (65532) because kubernetes expects numeric user when applying pod security policies
USER 65532
LABEL org.opencontainers.image.source=https://github.com/capi-samples/cluster-api-provider-meta
ENTRYPOINT  ["/manager"]