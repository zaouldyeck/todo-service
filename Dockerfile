# Dockerfile
FROM golang:1.24.4-alpine AS builder
ENV CGO_ENABLED=0
ENV GOOS=linux
ARG BUILD_REF

WORKDIR /app
COPY go.mod go.sum ./
COPY . .
RUN go build -ldflags="-s -w -X main.build=${BUILD_REF}" -o todo-api

FROM scratch
ARG BUILD_DATE
ARG BUILD_REF
COPY --from=builder /app/todo-api /todo-api
ENTRYPOINT ["/todo-api"]

LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.title="todo-service" \
      org.opencontainers.image.authors="Paul Ohrt <paul.ohrt@internetstiftelsen.se>" \
      org.opencontainers.image.revision="${BUILD_REF}" \
