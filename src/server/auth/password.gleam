import gleam/bit_array
import gleam/crypto
import gleam/string

const iterations = 100_000

const key_length = 32

/// Hash a password using PBKDF2-SHA256.
/// Returns a string in the format "salt$hash" (both hex-encoded).
pub fn hash(password: String) -> String {
  let salt = crypto.strong_random_bytes(16)
  let derived =
    pbkdf2_hmac(bit_array.from_string(password), salt, iterations, key_length)
  to_hex(salt) <> "$" <> to_hex(derived)
}

/// Verify a password against a stored hash string.
pub fn verify(password: String, stored: String) -> Bool {
  case string.split(stored, "$") {
    [salt_hex, hash_hex] ->
      case from_hex(salt_hex), from_hex(hash_hex) {
        Ok(salt), Ok(expected_hash) -> {
          let derived =
            pbkdf2_hmac(
              bit_array.from_string(password),
              salt,
              iterations,
              key_length,
            )
          crypto.secure_compare(derived, expected_hash)
        }
        _, _ -> False
      }
    _ -> False
  }
}

@external(erlang, "password_ffi", "pbkdf2")
fn pbkdf2_hmac(
  password: BitArray,
  salt: BitArray,
  iterations: Int,
  key_length: Int,
) -> BitArray

fn to_hex(data: BitArray) -> String {
  do_to_hex(data, "")
}

fn do_to_hex(data: BitArray, acc: String) -> String {
  case data {
    <<byte, rest:bytes>> -> {
      let hi = nibble(byte / 16)
      let lo = nibble(byte % 16)
      do_to_hex(rest, acc <> hi <> lo)
    }
    _ -> acc
  }
}

fn nibble(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    10 -> "a"
    11 -> "b"
    12 -> "c"
    13 -> "d"
    14 -> "e"
    _ -> "f"
  }
}

fn from_hex(hex: String) -> Result(BitArray, Nil) {
  do_from_hex(hex, <<>>)
}

fn do_from_hex(hex: String, acc: BitArray) -> Result(BitArray, Nil) {
  case hex {
    "" -> Ok(acc)
    _ -> {
      case string.pop_grapheme(hex) {
        Ok(#(hi_char, rest1)) ->
          case string.pop_grapheme(rest1) {
            Ok(#(lo_char, rest2)) ->
              case hex_digit(hi_char), hex_digit(lo_char) {
                Ok(hi), Ok(lo) -> do_from_hex(rest2, <<acc:bits, { hi * 16 + lo }>>)
                _, _ -> Error(Nil)
              }
            Error(_) -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    }
  }
}

fn hex_digit(c: String) -> Result(Int, Nil) {
  case c {
    "0" -> Ok(0)
    "1" -> Ok(1)
    "2" -> Ok(2)
    "3" -> Ok(3)
    "4" -> Ok(4)
    "5" -> Ok(5)
    "6" -> Ok(6)
    "7" -> Ok(7)
    "8" -> Ok(8)
    "9" -> Ok(9)
    "a" | "A" -> Ok(10)
    "b" | "B" -> Ok(11)
    "c" | "C" -> Ok(12)
    "d" | "D" -> Ok(13)
    "e" | "E" -> Ok(14)
    "f" | "F" -> Ok(15)
    _ -> Error(Nil)
  }
}
