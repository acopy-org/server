# acopy server

Backend server for acopy, a cross-platform clipboard sync service. Built with Gleam, targeting the Erlang/OTP runtime.

Handles user account management over HTTP and real-time clipboard synchronization over WebSocket using a custom binary protocol.

## Architecture

```mermaid
sequenceDiagram
    participant A as Client A
    participant S as Server
    participant B as Client B

    A->>S: POST /api/users/register
    S-->>A: 201 user created
    A->>S: POST /api/users/login
    S-->>A: 200 {token, user}

    A->>S: WS /ws
    A->>S: Auth (0x01, jwt)
    S-->>A: Ack (0x04)

    B->>S: WS /ws
    B->>S: Auth (0x01, jwt)
    S-->>B: Ack (0x04)

    A->>S: ClipboardPush (0x02)
    S-->>A: Ack (0x04)
    S->>B: ClipboardBroadcast (0x03)

    A->>S: Ping (0x06)
    S-->>A: Pong (0x07)
```

## HTTP API

| Method | Path                   | Auth | Description                |
|--------|------------------------|------|----------------------------|
| POST   | `/api/users/register`  | No   | Create account (email/password) |
| POST   | `/api/users/login`     | No   | Authenticate, returns JWT  |
| GET    | `/api/users/me`        | JWT  | Get current user profile   |

All request and response bodies are JSON. Authentication uses Bearer tokens in the `Authorization` header.

Register and login accept `{"email": "...", "password": "..."}`. Login returns `{"token": "...", "user": {...}}`. The user object contains `id`, `email`, and `created_at` — password hashes are never exposed.

## WebSocket Protocol

Clipboard sync happens over a single persistent WebSocket connection at `/ws` using binary frames.

### Wire Format

Every message is a binary frame with this layout:

```
+--------+--------+--------+----------+---------+
| ver    | type   | flags  | length   | payload |
| 1 byte | 1 byte | 1 byte | 4 bytes  | N bytes |
+--------+--------+--------+----------+---------+
                            (big-endian uint32)
```

- **ver**: Protocol version, currently `0x01`
- **type**: Message type (see below)
- **flags**: Bit 0 = zstd compressed, bits 1–7 reserved
- **length**: Payload byte count, big-endian
- **payload**: MessagePack-encoded map

### Message Types

| Type               | Hex    | Direction        | Payload                                        |
|--------------------|--------|------------------|------------------------------------------------|
| Auth               | `0x01` | client → server  | `{"token": "<jwt>"}`                           |
| ClipboardPush      | `0x02` | client → server  | `{"content": <bytes>, "device": "<name>"}`     |
| ClipboardBroadcast | `0x03` | server → client  | `{"content": <bytes>, "device": "<name>", "ts": <unix>}` |
| Ack                | `0x04` | server → client  | `{"ok": true}`                                 |
| Error              | `0x05` | server → client  | `{"code": <int>, "msg": "<reason>"}`           |
| Ping               | `0x06` | either           | empty                                          |
| Pong               | `0x07` | either           | empty                                          |

### Connection Lifecycle

1. Client opens WebSocket to `/ws`
2. Client sends Auth message with JWT
3. Server verifies token, responds with Ack (or Error + disconnect)
4. Client sends ClipboardPush when user copies something
5. Server stores the entry, sends Ack to sender, broadcasts ClipboardBroadcast to all other connections for that user
6. Ping/Pong every 30s for keepalive

The server maintains a registry mapping each user to their active connections. When broadcasting, the pushing connection is excluded to prevent echo loops. Maximum clipboard payload size is 10 MB.

## Database

PostgreSQL with two tables:

**users** — `id` (text, PK), `email` (text, unique), `password_hash` (text), `created_at` (text ISO 8601)

**clipboard_entries** — `id` (text, PK), `user_id` (text, FK → users), `content` (bytea), `device_name` (text), `created_at` (text ISO 8601)

Tables are created automatically on startup if they don't exist.

## Project Structure

```
src/
  server.gleam                        Entry point — config, DB pool, registry, HTTP/WS routing
  password_ffi.erl                    Erlang FFI for PBKDF2-SHA256 via OTP crypto module
  server/
    router.gleam                      Top-level HTTP path dispatch
    web.gleam                         Context type (DB pool, JWT secret, registry), middleware
    db/
      db.gleam                        Schema migrations (CREATE TABLE IF NOT EXISTS)
    auth/
      auth.gleam                      JWT creation/verification (HS256), auth middleware
      password.gleam                  Password hashing (PBKDF2-SHA256, 100k iterations)
    user/
      user.gleam                      User type, JSON encoders, DB/request decoders
      user_service.gleam              Register, login, get-by-id business logic
      user_routes.gleam               HTTP handlers for /api/users/*
    clipboard/
      clipboard_service.gleam         Stores clipboard entries in PostgreSQL
    ws/
      msgpack.gleam                   Minimal MessagePack encoder/decoder
      protocol.gleam                  Binary wire protocol — frame encode/decode
      registry.gleam                  OTP actor tracking user_id → [connections]
      handler.gleam                   WebSocket lifecycle — auth, push, broadcast, ping
```

## Implementation Details

### Password Hashing

PBKDF2-SHA256 with 100,000 iterations and 32-byte output, using a 16-byte random salt from OTP's `crypto:strong_rand_bytes`. The stored format is `<salt_hex>$<hash_hex>`. Verification uses constant-time comparison via `gleam_crypto.secure_compare`. No C dependencies — uses OTP's built-in `crypto:pbkdf2_hmac/5`.

### JWT

Hand-rolled HS256 implementation using `gleam_crypto.hmac` (HMAC-SHA256). Tokens contain `sub` (user ID), `iat`, and `exp` (24-hour expiry) claims. Base64url encoding/decoding handles padding normalization. Signature verification uses constant-time comparison. The `gwt` hex package was not used due to dependency conflicts with current `birl`/`gleam_json` versions.

### MessagePack

Custom minimal encoder/decoder supporting the subset needed by the protocol: maps, strings, binary, integers, and booleans. Handles fixmap, fixstr, str 8/16/32, bin 8/16/32, fixint, uint 8/16/32/64, int 8/16/32, and nil. No external msgpack library — keeps the dependency tree pure Gleam/OTP.

### Connection Registry

An OTP actor (via `gleam_otp/actor`) that maintains two dictionaries: `conn_id → (user_id, subject)` and `user_id → [conn_id]`. WebSocket connections register on auth and unregister on close. Broadcasting iterates all connections for a user, excludes the sender, and sends an `OutboundBroadcast` message to each connection's `Subject`. Each WebSocket actor receives these via an OTP selector and encodes/sends the binary frame from its own process (required by mist — frames can only be sent from the owning process).

### HTTP/WebSocket Routing

Mist handles both HTTP and WebSocket at the transport level. The main handler pattern-matches on path segments: `/ws` upgrades to WebSocket via `mist.websocket`, everything else delegates to the Wisp HTTP handler via `wisp_mist.handler`. This avoids needing a reverse proxy to split traffic.

### Compression

The protocol supports zstd compression (flag bit 0). Currently the server sends all payloads uncompressed and rejects compressed incoming payloads. The zstd hex package requires C compilation, which conflicts with the pure-Gleam deployment goal. Compression can be added later by vendoring or fixing the zstd NIF build.

## Dependencies

All pure Gleam/Erlang — no C compilation required:

- **wisp** + **mist** — HTTP framework and server
- **pog** — PostgreSQL client (pure Erlang PG wire protocol)
- **gleam_json** — JSON encoding/decoding
- **gleam_crypto** — HMAC, secure compare, random bytes
- **birl** — Timestamps
- **youid** — UUID v4 generation
- **envoy** — Environment variable reading
- **gleam_otp** — Actor (registry)

## Running

### Prerequisites

- **Gleam** >= 1.4.0
- **Erlang/OTP** >= 27
- **PostgreSQL** >= 12

### Local Development

1. **Set up the database:**
   ```sh
   createdb acopy
   ```

2. **Configure environment variables:**
   ```sh
   export DATABASE_URL="postgres://user:pass@localhost:5432/acopy"
   export JWT_SECRET="your-secret-here-change-in-production"
   export PORT=8000
   ```

3. **Run the server:**
   ```sh
   gleam run
   ```

The server will start on `http://localhost:8000` and automatically create the required database tables on first run.

### Docker

1. **Build the image:**
   ```sh
   docker build -t acopy-server .
   ```

2. **Run the container:**
   ```sh
   docker run -d \
     -e DATABASE_URL="postgres://user:pass@db-host:5432/acopy" \
     -e JWT_SECRET="your-secret-here" \
     -p 80:80 \
     acopy-server
   ```

The container listens on port 80 by default and binds to `0.0.0.0`. The ~90 MB image contains only the Erlang runtime and compiled BEAM bytecode — no compiler toolchain.

## Environment Variables

| Variable       | Default                                      | Description            |
|----------------|----------------------------------------------|------------------------|
| `DATABASE_URL` | `postgres://postgres:postgres@localhost:5432/acopy` | PostgreSQL connection URI |
| `JWT_SECRET`   | `dev-secret-change-in-production`            | HMAC signing key       |
| `PORT`         | `8000`                                       | HTTP/WS listen port    |

## License

MIT
