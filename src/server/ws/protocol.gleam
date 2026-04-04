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

const msg_copy_intent = 0x08

const msg_copy_cancel = 0x09

const msg_device_renamed = 0x0A

const msg_device_deleted = 0x0B

// Flag bits
const flag_zstd = 1

pub type WsMsg {
  AuthMsg(token: String, device: String)
  ClipboardPushMsg(content: BitArray, device: String, content_type: String)
  ClipboardBroadcastMsg(id: String, content: BitArray, device: String, content_type: String, ts: Int)
  AckMsg
  ErrorMsg(code: Int, msg: String)
  PingMsg
  PongMsg
  CopyIntentMsg(device: String)
  CopyCancelMsg
  DeviceRenamedMsg(device_id: String, old_name: String, new_name: String)
  DeviceDeletedMsg(device_id: String)
  AckWithProcessingMsg(processing_ms: Int)
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
              let decompressed = case is_compressed {
                True -> zstd_decompress(payload)
                False -> payload
              }
              decode_payload(msg_type, decompressed)
            }
          }
        }
      }
    }
    _ -> Error("Frame too short")
  }
}

/// Encode a protocol message into a binary WebSocket frame (with compression).
pub fn encode(msg: WsMsg) -> BitArray {
  let #(msg_type, payload) = encode_payload(msg)
  let #(flags, final_payload) = maybe_compress(payload)
  let length = bit_array.byte_size(final_payload)
  <<protocol_version, msg_type, flags, length:size(32), final_payload:bits>>
}

/// Encode without compression (for browser clients that don't support zstd).
pub fn encode_no_compress(msg: WsMsg) -> BitArray {
  let #(msg_type, payload) = encode_payload(msg)
  let length = bit_array.byte_size(payload)
  <<protocol_version, msg_type, 0, length:size(32), payload:bits>>
}

fn decode_payload(msg_type: Int, payload: BitArray) -> Result(WsMsg, String) {
  case msg_type {
    t if t == msg_auth -> {
      case msgpack.decode(payload) {
        Ok(#(msgpack.Map(entries), _)) ->
          case msgpack.get_string(entries, "token") {
            Ok(token) -> {
              let device = case msgpack.get_string(entries, "device") {
                Ok(d) -> d
                Error(_) -> ""
              }
              Ok(AuthMsg(token:, device:))
            }
            Error(_) -> Error("Missing 'token' in Auth message")
          }
        _ -> Error("Invalid Auth payload")
      }
    }
    t if t == msg_clipboard_push -> {
      case msgpack.decode(payload) {
        Ok(#(msgpack.Map(entries), _)) ->
          case msgpack.get_bin(entries, "content"), msgpack.get_string(entries, "device") {
            Ok(content), Ok(device) -> {
              let content_type = case msgpack.get_string(entries, "content_type") {
                Ok(ct) -> ct
                Error(_) -> "text/plain"
              }
              Ok(ClipboardPushMsg(content:, device:, content_type:))
            }
            _, _ -> Error("Missing fields in ClipboardPush")
          }
        _ -> Error("Invalid ClipboardPush payload")
      }
    }
    t if t == msg_clipboard_broadcast -> {
      case msgpack.decode(payload) {
        Ok(#(msgpack.Map(entries), _)) ->
          case
            msgpack.get_string(entries, "id"),
            msgpack.get_bin(entries, "content"),
            msgpack.get_string(entries, "device"),
            msgpack.get_int(entries, "ts")
          {
            Ok(id), Ok(content), Ok(device), Ok(ts) -> {
              let content_type = case msgpack.get_string(entries, "content_type") {
                Ok(ct) -> ct
                Error(_) -> "text/plain"
              }
              Ok(ClipboardBroadcastMsg(id:, content:, device:, content_type:, ts:))
            }
            _, _, _, _ -> Error("Missing fields in ClipboardBroadcast")
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
    t if t == msg_copy_intent -> {
      case msgpack.decode(payload) {
        Ok(#(msgpack.Map(entries), _)) ->
          case msgpack.get_string(entries, "device") {
            Ok(device) -> Ok(CopyIntentMsg(device:))
            Error(_) -> Error("Missing 'device' in CopyIntent message")
          }
        _ -> Error("Invalid CopyIntent payload")
      }
    }
    t if t == msg_copy_cancel -> Ok(CopyCancelMsg)
    t if t == msg_device_renamed -> {
      case msgpack.decode(payload) {
        Ok(#(msgpack.Map(entries), _)) ->
          case
            msgpack.get_string(entries, "device_id"),
            msgpack.get_string(entries, "old_name"),
            msgpack.get_string(entries, "new_name")
          {
            Ok(device_id), Ok(old_name), Ok(new_name) ->
              Ok(DeviceRenamedMsg(device_id:, old_name:, new_name:))
            _, _, _ -> Error("Missing fields in DeviceRenamed")
          }
        _ -> Error("Invalid DeviceRenamed payload")
      }
    }
    t if t == msg_device_deleted -> {
      case msgpack.decode(payload) {
        Ok(#(msgpack.Map(entries), _)) ->
          case msgpack.get_string(entries, "device_id") {
            Ok(device_id) -> Ok(DeviceDeletedMsg(device_id:))
            Error(_) -> Error("Missing fields in DeviceDeleted")
          }
        _ -> Error("Invalid DeviceDeleted payload")
      }
    }
    _ -> Error("Unknown message type")
  }
}

fn encode_payload(msg: WsMsg) -> #(Int, BitArray) {
  case msg {
    AuthMsg(token:, device:) -> #(
      msg_auth,
      msgpack.encode(msgpack.Map([
        #(msgpack.Str("token"), msgpack.Str(token)),
        #(msgpack.Str("device"), msgpack.Str(device)),
      ])),
    )
    ClipboardPushMsg(content:, device:, content_type:) -> #(
      msg_clipboard_push,
      msgpack.encode(msgpack.Map([
        #(msgpack.Str("content"), msgpack.Bin(content)),
        #(msgpack.Str("device"), msgpack.Str(device)),
        #(msgpack.Str("content_type"), msgpack.Str(content_type)),
      ])),
    )
    ClipboardBroadcastMsg(id:, content:, device:, content_type:, ts:) -> #(
      msg_clipboard_broadcast,
      msgpack.encode(msgpack.Map([
        #(msgpack.Str("id"), msgpack.Str(id)),
        #(msgpack.Str("content"), msgpack.Bin(content)),
        #(msgpack.Str("device"), msgpack.Str(device)),
        #(msgpack.Str("content_type"), msgpack.Str(content_type)),
        #(msgpack.Str("ts"), msgpack.Int(ts)),
      ])),
    )
    AckMsg -> #(
      msg_ack,
      msgpack.encode(msgpack.Map([#(msgpack.Str("ok"), msgpack.Bool(True))])),
    )
    AckWithProcessingMsg(processing_ms:) -> #(
      msg_ack,
      msgpack.encode(msgpack.Map([
        #(msgpack.Str("ok"), msgpack.Bool(True)),
        #(msgpack.Str("processing_ms"), msgpack.Int(processing_ms)),
      ])),
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
    CopyIntentMsg(device:) -> #(
      msg_copy_intent,
      msgpack.encode(msgpack.Map([
        #(msgpack.Str("device"), msgpack.Str(device)),
      ])),
    )
    CopyCancelMsg -> #(msg_copy_cancel, <<>>)
    DeviceRenamedMsg(device_id:, old_name:, new_name:) -> #(
      msg_device_renamed,
      msgpack.encode(msgpack.Map([
        #(msgpack.Str("device_id"), msgpack.Str(device_id)),
        #(msgpack.Str("old_name"), msgpack.Str(old_name)),
        #(msgpack.Str("new_name"), msgpack.Str(new_name)),
      ])),
    )
    DeviceDeletedMsg(device_id:) -> #(
      msg_device_deleted,
      msgpack.encode(msgpack.Map([
        #(msgpack.Str("device_id"), msgpack.Str(device_id)),
      ])),
    )
  }
}

fn maybe_compress(payload: BitArray) -> #(Int, BitArray) {
  let size = bit_array.byte_size(payload)
  case size > 1024 {
    True -> {
      let compressed = zstd_compress(payload)
      let compressed_size = bit_array.byte_size(compressed)
      case compressed_size < size {
        True -> #(flag_zstd, compressed)
        False -> #(0, payload)
      }
    }
    False -> #(0, payload)
  }
}

@external(erlang, "zstd_ffi", "compress")
fn zstd_compress(data: BitArray) -> BitArray

@external(erlang, "zstd_ffi", "decompress")
fn zstd_decompress(data: BitArray) -> BitArray

@external(erlang, "erlang", "band")
fn int_and(a: Int, b: Int) -> Int
