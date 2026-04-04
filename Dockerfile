FROM ghcr.io/gleam-lang/gleam:v1.14.0-erlang-alpine AS build

COPY gleam.toml manifest.toml /app/
WORKDIR /app
RUN gleam deps download

COPY src/ /app/src/
COPY test/ /app/test/
COPY priv/ /app/priv/
RUN gleam export erlang-shipment

# --- Runtime ---
FROM erlang:28-alpine

RUN apk add --no-cache zstd curl

COPY --from=build /app/build/erlang-shipment /app
COPY priv/ /app/priv/

WORKDIR /app

ENV PORT=80

EXPOSE 80

HEALTHCHECK --interval=15s --timeout=5s --retries=3 \
  CMD curl -sf http://localhost:80/ || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
