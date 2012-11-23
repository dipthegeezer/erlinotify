-module(erlinotify_tests).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    %% Suppress so we can have some peace.
    error_logger:tty(false),
    Path = "/tmp/test/",
    ok = filelib:ensure_dir(Path),
    application:start(ets_manager),
    application:start(erlinotify),
    Path.

cleanup(_Arg) ->
    application:stop(erlinotify),
    application:stop(ets_manager),
    error_logger:tty(true).

basic_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(Path) -> erlinotify:assign_callback(
                fun(Var) ->
                        ?_assertMatch({Path,file,_Event,0,"monkey"}, Var)
                end ),
              erlinotify:watch(Path),
              ok = file:write_file(Path++"monkey", "testing123", [write]),
              ?_assertMatch(ok,ok)
              end
    }.
