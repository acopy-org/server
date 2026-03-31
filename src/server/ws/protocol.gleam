import gleam/bit_array
import server/ws/msgpack

const protocol_version = 1

// Message type bytes
const msg_auth = 0x01

const msg_clipboard_push = 0x02

const msg_clipboard_broadcast = 0x03

const msg_ack = 0x04

const msg_error = 0x05

const msg_ping = 0x06

const msg_pong = 0x07

// Flag bits
const flag_zstd = 1

pub type WsMsg {
  AuthMsg(token: String)
  ClipboardPushMsg(content: BitArray, device: String)
  ClipboardBroadcastMsg(content: BitArray, device: String, ts: Int)
  AckMsg
  ErrorMsg(code: Int, msg: String)
  PingMsg
  PongMsg
}

/// Decode a binary WebSocket frame into a protocol message.
pub fn decode(data: BitArray) -> Result(WsMsg, String) {
  // Header: ver(1) + type(1) + flags(1) + length(4) = 7 bytes
  case data {
    <<ver, msg_type, flags, length:size(32), rest:bytes>> -> {
      case ver == protocol_version {
        False -> Error("Unsupported protocol version")
        True -> {
          let payload_size = bit_array.byte_size(rest)
          case payload_size >= length {
            False -> Error("Incomplete payload")
            True -> {
              let assert Ok(payload) = bit_array.slice(rest, 0, length)
              let is_compressed = int_and(flags, flag_zstd) == flag_zstd
              case is_compressed {
                True -> Error("Compressed payloads not yet supported")
                False -> decode_payload(msg_type, payload)
              }
            }
          }
        }
      }
    }
    _ -> Error("Frame too short")
  }
}

/// Encode a protocol message into a binary WebSocket frame.
pub fn encode(msg: WsMsg) -> BitArray {
  let #(msg_type, payload) = encode_payload(msg)
  let #(flags, final_payload) = maybe_compress(payload)
  let length = bit_array.byte_size(final_payload)
  <<protocol_version, msg_type, flags, length:size(32), final_payload:bits>>
}

fn decode_payload(msg_type: Int, payload: BitArray) -> Result(WsMsg, String) {
  case msg_type {
    t if t == msg_auth -> {
      case msgpack.decode(payload) {
        Ok(#(msgpack.Map(entries), _)) ->
          case msgpack.get_string(entries, "token") {
            Ok(token) -> Ok(AuthMsg(token:))
            Error(_) -> Error("Missing 'token' in Auth message")
          }
        _ -> Error("Invalid Auth payload")
      }
    }
    t if t == msg_clipboard_push -> {
      case msgpack.decode(payload) {
        Ok(#(msgpack.Map(entries), _)) ->
          case msgpack.get_bin(entries, "content"), msgpack.get_string(entries, "device") {
            Ok(content), Ok(device) -> Ok(ClipboardPushMsg(content:, device:))
            _, _ -> Error("Missing fields in ClipboardPush")
          }
        _ -> Error("Invalid ClipboardPush payload")
      }
    }
    t if t == msg_clipboard_broadcast -> {
      case msgpack.decode(payload) {
        Ok(#(msgpack.Map(entries), _)) ->
          case
            msgpack.get_bin(entries, "content"),
            msgpack.get_string(entries, "device"),
            msgpack.get_int(entries, "ts")
          {
            Ok(content), Ok(device), Ok(ts) ->
              Ok(ClipboardBroadcastMsg(content:, device:, ts:))
            _, _, _ -> Error("Missing fields in ClipboardBroadcast")
          }
        _ -> Error("Invalid ClipboardBroadcast payload")
      }
    }
    t if t == msg_ack -> Ok(AckMsg)
    t if t == msg_error -> {
      case msgpack.decode(payload) {
        Ok(#(msgpack.Map(entries), _)) ->
          case msgpack.get_int(entries, "code"), msgpack.get_string(entries, "msg") {
            Ok(code), Ok(msg) -> Ok(ErrorMsg(code:, msg:))
            _, _ -> Error("Missing fields in Error message")
          }
        _ -> Error("Invalid Error payload")
      }
    }
    t if t == msg_ping -> Ok(PingMsg)
    t if t == msg_pong -> Ok(PongMsg)
    _ -> Error("Unknown message type")
  }
}

fn encode_payload(msg: WsMsg) -> #(Int, BitArray) {
  case msg {
    AuthMsg(token:) -> #(
      msg_auth,
      msgpack.encode(msgpack.Map([
        #(msgpack.Str("token"), msgpack.Str(token)),
      ])),
    )
    ClipboardPushMsg(content:, device:) -> #(
      msg_clipboard_push,
      msgpack.encode(msgpack.Map([
        #(msgpack.Str("content"), msgpack.Bin(content)),
        #(msgpack.Str("device"), msgpack.Str(device)),
      ])),
    )
    ClipboardBroadcastMsg(content:, device:, ts:) -> #(
      msg_clipboard_broadcast,
      msgpack.encode(msgpack.Map([
        #(msgpack.Str("content"), msgpack.Bin(content)),
        #(msgpack.Str("device"), msgpack.Str(device)),
        #(msgpack.Str("ts"), msgpack.Int(ts)),
      ])),
    )
    AckMsg -> #(
      msg_ack,
      msgpack.encode(msgpack.Map([#(msgpack.Str("ok"), msgpack.Bool(True))])),
    )
    ErrorMsg(code:, msg:) -> #(
      msg_error,
      msgpack.encode(msgpack.Map([
        #(msgpack.Str("code"), msgpack.Int(code)),
        #(msgpack.Str("msg"), msgpack.Str(msg)),
      ])),
    )
    PingMsg -> #(msg_ping, <<>>)
    PongMsg -> #(msg_pong, <<>>)
  }
}

fn maybe_compress(payload: BitArray) -> #(Int, BitArray) {
  // Compression not yet supported — send uncompressed
  #(0, payload)
}

@external(erlang, "erlang", "band")
fn int_and(a: Int, b: Int) -> Int
