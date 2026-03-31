-module(password_ffi).
-export([pbkdf2/4]).

pbkdf2(Password, Salt, Iterations, KeyLength) ->
    crypto:pbkdf2_hmac(sha256, Password, Salt, Iterations, KeyLength).
