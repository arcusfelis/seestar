#!/usr/bin/env bash
erl -eval 'try lists:map(fun(N) -> case gen_tcp:connect("127.0.0.1", 9042, [], 1000) of {error,econnrefused} -> io:format("Retry, n=~p~n", [N]), timer:sleep(1000); _ -> init:stop(0) end end, lists:seq(1,60)) after init:stop(1) end.'
