-module(file_ffi).
-export([read/1]).

read(Path) ->
    case file:read_file(Path) of
        {ok, Content} -> {ok, Content};
        {error, Reason} -> {error, Reason}
    end.
