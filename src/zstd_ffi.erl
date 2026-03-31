-module(zstd_ffi).
-export([compress/1, decompress/1]).

compress(Data) ->
    run(Data, "zstd -f -q --no-progress").

decompress(Data) ->
    run(Data, "zstd -d -f -q --no-progress").

run(Data, Cmd) ->
    Id = integer_to_list(erlang:unique_integer([positive, monotonic])),
    In = "/tmp/acopy_z_" ++ Id,
    Out = In ++ ".out",
    ok = file:write_file(In, Data),
    os:cmd(Cmd ++ " " ++ In ++ " -o " ++ Out),
    {ok, Result} = file:read_file(Out),
    file:delete(In),
    file:delete(Out),
    Result.
