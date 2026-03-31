import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

/// MessagePack value types (subset needed for acopy protocol)
pub type Value {
  Str(String)
  Bin(BitArray)
  Int(Int)
  Bool(Bool)
  Map(List(#(Value, Value)))
  MpNil
}

// --- Encoding ---

pub fn encode(value: Value) -> BitArray {
  case value {
    MpNil -> <<0xC0>>
    Bool(True) -> <<0xC3>>
    Bool(False) -> <<0xC2>>
    Int(n) -> encode_int(n)
    Str(s) -> encode_str(s)
    Bin(b) -> encode_bin(b)
    Map(entries) -> encode_map(entries)
  }
}

fn encode_int(n: Int) -> BitArray {
  case n {
    _ if n >= 0 && n <= 127 -> <<n>>
    _ if n >= 0 && n <= 255 -> <<0xCC, n>>
    _ if n >= 0 && n <= 65_535 -> <<0xCD, n:size(16)>>
    _ if n >= 0 && n <= 4_294_967_295 -> <<0xCE, n:size(32)>>
    _ if n >= 0 -> <<0xCF, n:size(64)>>
    _ if n >= -32 -> <<{ n + 256 }>>
    _ if n >= -128 -> <<0xD0, { n + 256 }>>
    _ if n >= -32_768 -> <<0xD1, { n + 65_536 }:size(16)>>
    _ -> <<0xD2, { n + 4_294_967_296 }:size(32)>>
  }
}

fn encode_str(s: String) -> BitArray {
  let bytes = bit_array.from_string(s)
  let len = bit_array.byte_size(bytes)
  case len {
    _ if len <= 31 -> <<{ 0xA0 + len }, bytes:bits>>
    _ if len <= 255 -> <<0xD9, len, bytes:bits>>
    _ if len <= 65_535 -> <<0xDA, len:size(16), bytes:bits>>
    _ -> <<0xDB, len:size(32), bytes:bits>>
  }
}

fn encode_bin(b: BitArray) -> BitArray {
  let len = bit_array.byte_size(b)
  case len {
    _ if len <= 255 -> <<0xC4, len, b:bits>>
    _ if len <= 65_535 -> <<0xC5, len:size(16), b:bits>>
    _ -> <<0xC6, len:size(32), b:bits>>
  }
}

fn encode_map(entries: List(#(Value, Value))) -> BitArray {
  let len = list.length(entries)
  let header = case len {
    _ if len <= 15 -> <<{ 0x80 + len }>>
    _ if len <= 65_535 -> <<0xDE, len:size(16)>>
    _ -> <<0xDF, len:size(32)>>
  }
  let body =
    list.fold(entries, <<>>, fn(acc, entry) {
      let #(k, v) = entry
      <<acc:bits, { encode(k) }:bits, { encode(v) }:bits>>
    })
  <<header:bits, body:bits>>
}

// --- Decoding ---

pub fn decode(data: BitArray) -> Result(#(Value, BitArray), String) {
  case data {
    <<>> -> Error("Unexpected end of input")
    <<0xC0, rest:bytes>> -> Ok(#(MpNil, rest))
    <<0xC2, rest:bytes>> -> Ok(#(Bool(False), rest))
    <<0xC3, rest:bytes>> -> Ok(#(Bool(True), rest))
    // Positive fixint (0x00-0x7F)
    <<tag, rest:bytes>> if tag <= 0x7F -> Ok(#(Int(tag), rest))
    // Negative fixint (0xE0-0xFF)
    <<tag, rest:bytes>> if tag >= 0xE0 -> Ok(#(Int(tag - 256), rest))
    // uint 8
    <<0xCC, val, rest:bytes>> -> Ok(#(Int(val), rest))
    // uint 16
    <<0xCD, val:size(16), rest:bytes>> -> Ok(#(Int(val), rest))
    // uint 32
    <<0xCE, val:size(32), rest:bytes>> -> Ok(#(Int(val), rest))
    // uint 64
    <<0xCF, val:size(64), rest:bytes>> -> Ok(#(Int(val), rest))
    // int 8
    <<0xD0, val, rest:bytes>> -> Ok(#(Int(val - 256), rest))
    // int 16
    <<0xD1, val:size(16), rest:bytes>> -> Ok(#(Int(val - 65_536), rest))
    // int 32
    <<0xD2, val:size(32), rest:bytes>> -> Ok(#(Int(val - 4_294_967_296), rest))
    // fixstr (0xA0-0xBF)
    <<tag, rest:bytes>> if tag >= 0xA0 && tag <= 0xBF ->
      decode_str_bytes(rest, tag - 0xA0)
    // str 8
    <<0xD9, len, rest:bytes>> -> decode_str_bytes(rest, len)
    // str 16
    <<0xDA, len:size(16), rest:bytes>> -> decode_str_bytes(rest, len)
    // str 32
    <<0xDB, len:size(32), rest:bytes>> -> decode_str_bytes(rest, len)
    // bin 8
    <<0xC4, len, rest:bytes>> -> decode_bin_bytes(rest, len)
    // bin 16
    <<0xC5, len:size(16), rest:bytes>> -> decode_bin_bytes(rest, len)
    // bin 32
    <<0xC6, len:size(32), rest:bytes>> -> decode_bin_bytes(rest, len)
    // fixmap (0x80-0x8F)
    <<tag, rest:bytes>> if tag >= 0x80 && tag <= 0x8F ->
      decode_map_entries(rest, tag - 0x80, [])
    // map 16
    <<0xDE, len:size(16), rest:bytes>> -> decode_map_entries(rest, len, [])
    // map 32
    <<0xDF, len:size(32), rest:bytes>> -> decode_map_entries(rest, len, [])
    _ -> Error("Unknown msgpack tag")
  }
}

fn decode_str_bytes(
  data: BitArray,
  len: Int,
) -> Result(#(Value, BitArray), String) {
  case len {
    0 -> Ok(#(Str(""), data))
    _ -> {
      use #(bytes, rest) <- result.try(take_bytes(data, len))
      case bit_array.to_string(bytes) {
        Ok(s) -> Ok(#(Str(s), rest))
        Error(_) -> Error("Invalid UTF-8 in string")
      }
    }
  }
}

fn decode_bin_bytes(
  data: BitArray,
  len: Int,
) -> Result(#(Value, BitArray), String) {
  case len {
    0 -> Ok(#(Bin(<<>>), data))
    _ -> {
      use #(bytes, rest) <- result.try(take_bytes(data, len))
      Ok(#(Bin(bytes), rest))
    }
  }
}

fn decode_map_entries(
  data: BitArray,
  remaining: Int,
  acc: List(#(Value, Value)),
) -> Result(#(Value, BitArray), String) {
  case remaining {
    0 -> Ok(#(Map(list.reverse(acc)), data))
    _ -> {
      use #(key, rest1) <- result.try(decode(data))
      use #(val, rest2) <- result.try(decode(rest1))
      decode_map_entries(rest2, remaining - 1, [#(key, val), ..acc])
    }
  }
}

fn take_bytes(
  data: BitArray,
  len: Int,
) -> Result(#(BitArray, BitArray), String) {
  let total = bit_array.byte_size(data)
  case total >= len {
    True -> {
      let taken = bit_array.slice(data, 0, len)
      let rest = bit_array.slice(data, len, total - len)
      case taken, rest {
        Ok(t), Ok(r) -> Ok(#(t, r))
        _, _ -> Error("Failed to slice bytes")
      }
    }
    False ->
      Error(
        "Not enough bytes: need "
        <> string.inspect(len)
        <> " have "
        <> string.inspect(total),
      )
  }
}

// --- Map helpers ---

pub fn get_string(entries: List(#(Value, Value)), key: String) -> Result(String, Nil) {
  case list.key_find(entries, Str(key)) {
    Ok(Str(s)) -> Ok(s)
    _ -> Error(Nil)
  }
}

pub fn get_bin(entries: List(#(Value, Value)), key: String) -> Result(BitArray, Nil) {
  case list.key_find(entries, Str(key)) {
    Ok(Bin(b)) -> Ok(b)
    Ok(Str(s)) -> Ok(bit_array.from_string(s))
    _ -> Error(Nil)
  }
}

pub fn get_int(entries: List(#(Value, Value)), key: String) -> Result(Int, Nil) {
  case list.key_find(entries, Str(key)) {
    Ok(Int(n)) -> Ok(n)
    _ -> Error(Nil)
  }
}
