FROM ghcr.io/gleam-lang/gleam:v1.14.0-erlang-alpine AS build

COPY gleam.toml manifest.toml /app/
WORKDIR /app
RUN gleam deps download

COPY src/ /app/src/
COPY test/ /app/test/
RUN gleam export erlang-shipment

# --- Runtime ---
FROM erlang:28-alpine

RUN apk add --no-cache zstd

COPY --from=build /app/build/erlang-shipment /app

WORKDIR /app

ENV PORT=80

EXPOSE 80

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
