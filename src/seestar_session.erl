%%% Copyright 2014 Aleksey Yeschenko
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.

-module(seestar_session).

-behaviour(gen_server).

-include("seestar_messages.hrl").
-include("builtin_types.hrl").
-include_lib("seestar/include/constants.hrl").

%% API exports.
-export([start_link/2, start_link/3, start_link/4, stop/1]).
-export([set_event_listener/2]).
-export([perform/3, perform_async/3]).
-export([prepare/2, execute/5, execute_async/5]).

%% gen_server exports.
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3]).

-type host() :: string() | inet:ip_address().
-type credentials() :: [{string() | binary(), string() | binary()}].
-type events() :: [topology_change | status_change | schema_change].
-type client_option() :: {keyspace, string() | binary()}
                       | {credentials, credentials()}
                       | {events, events()}.

-type connect_option() :: gen_tcp:connect_option() | {connect_timeout, timeout()}
                         | {ssl, [ssl:connect_option()]}.

-type 'query'() :: binary() | string().
-type query_id() :: binary().
-type protocol_version() :: 3 | 4.
-record(client_handle, {pid, proto}).
-type client() :: #client_handle{pid :: pid(), proto :: protocol_version()}.

-define(b2l(Term), case is_binary(Term) of true -> binary_to_list(Term); false -> Term end).
-define(l2b(Term), case is_list(Term) of true -> list_to_binary(Term); false -> Term end).

-record(req,
        {op :: seestar_frame:opcode(),
         body :: binary(),
         from :: {pid(), reference()},
         sync = true :: boolean()}).

-record(st,
        {host :: host(),
         transport :: tcp | ssl,
         proto :: protocol_version(),
         sock :: inet:socket() | ssl:sslsocket(),
         buffer :: seestar_buffer:buffer(),
         free_ids :: [seestar_frame:stream_id()],
         backlog = queue:new() :: queue_t(),
         reqs :: ets:tid(),
         event_listener :: pid() | undefined}).

%% -------------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------------

%% @equiv start_link(Host, Post, [])
-spec start_link(host(), inet:port_number()) ->
    any().
start_link(Host, Port) ->
    start_link(Host, Port, []).

%% @equiv start_link(Host, Post, ClientOptions, [])
-spec start_link(host(), inet:port_number(), [client_option()]) ->
    any().
start_link(Host, Port, ClientOptions) ->
    start_link(Host, Port, ClientOptions, []).

%% @doc
%% Starts a new connection to a cassandra node on Host:Port.
%% By default it will connect on plain tcp. If you want to connect using ssl, pass
%% {ssl, [ssl_option()]} in the ConnectOptions
%% @end
-spec start_link(host(), inet:port_number(), [client_option()], [connect_option()]) ->
    {ok, pid(), client()} | {error, any()}.
start_link(Host, Port, ClientOptions, ConnectOptions) ->
    case start_link(4, Host, Port, ClientOptions, ConnectOptions) of
        protocol_error ->
            %% Downgrade version
            start_link(3, Host, Port, ClientOptions, ConnectOptions);
        Result ->
            Result
    end.

start_link(ProtoVsn, Host, Port, ClientOptions, ConnectOptions) ->
     case gen_server:start_link(?MODULE, [Host, Port, ConnectOptions], []) of
        {ok, Pid} ->
            Client = #client_handle{pid=Pid, proto=ProtoVsn},
            case setup(Client, ClientOptions, 2000) of
                ok    -> {ok, Pid, Client};
                Error -> stop(Pid), Error
            end;
        Error ->
            Error
    end.

setup(Client, Options, Timeout) ->
    set_protocol_version(Client),
    case authenticate(Client, Options, Timeout) of
        false ->
            {error, invalid_credentials};
        true ->
            case set_keyspace(Client, Options) of
                false ->
                    {error, invalid_keyspace};
                true ->
                    case subscribe(Client, Options) of
                        false -> {error, invalid_events};
                        true  -> ok
                    end
            end;
        protocol_error ->
            protocol_error
    end.

set_protocol_version(#client_handle{pid=Pid, proto=ProtoVsn}) ->
    gen_server:cast(Pid, {set_protocol_version, ProtoVsn}).

authenticate(Client, Options, Timeout) ->
    Credentials = proplists:get_value(credentials, Options),
    case request(Client, #startup{}, true, Timeout) of
        #ready{} ->
            true;
        #authenticate{} when Credentials =:= undefined ->
            false;
        #authenticate{} ->
            KVPairs = [ {?l2b(K), ?l2b(V)} || {K, V} <- Credentials ],
            case request(Client, #credentials{credentials = KVPairs}, true, Timeout) of
                #ready{} -> true;
                #error{} -> false
            end;
        #error{code = ?PROTOCOL_ERROR} ->
            protocol_error
    end.

set_keyspace(Client, Options) ->
    case proplists:get_value(keyspace, Options) of
        undefined ->
            true;
        Keyspace ->
            case perform(Client, "USE " ++ ?b2l(Keyspace), one) of
                {ok, _Result}    -> true;
                {error, _Reason} -> false
            end
    end.

subscribe(Client, Options) ->
    case proplists:get_value(events, Options, []) of
        [] ->
            true;
        Events ->
            case request(Client, #register{event_types = Events}, true) of
                #ready{} -> true;
                #error{} -> false
            end
    end.

%% @doc Set the client's event listener. If the client is subscribed to events,
%% they will be sent to the identified process.
-spec set_event_listener(pid(), pid() | undefined) -> ok.
set_event_listener(Client, Listener) ->
    gen_server:cast(Client, {event_listener, Listener}).

%% @doc Stop the client.
%% Closes the socket and terminates the process normally.
-spec stop(client()|pid()) -> ok.
stop(#client_handle{pid=Pid}) ->
    stop(Pid);
stop(Pid) ->
    gen_server:cast(Pid, stop).

%% @doc Synchoronously perform a CQL query using the specified consistency level.
%% Returns a result of an appropriate type (void, rows, set_keyspace, schema_change).
%% Use {@link seestar_result} module functions to work with the result.
-spec perform(pid(), 'query'(), seestar:consistency()) ->
    {ok, Result :: seestar_result:result()} | {error, Error :: seestar_error:error()}.
perform(Client, Query, Consistency) ->
    case request(Client, #'query'{'query' = ?l2b(Query), consistency = Consistency}, true) of
        #result{result = Result} ->
            {ok, Result};
        #error{} = Error ->
            {error, Error}
    end.

%% TODO doc
%% @doc Asynchronously perform a CQL query using the specified consistency level.
-spec perform_async(pid(), 'query'(), seestar:consistency()) -> ok.
perform_async(Client, Query, Consistency) ->
    Req = #'query'{'query' = ?l2b(Query), consistency = Consistency},
    request(Client, Req, false).

%% @doc Prepare a query for later execution. The response will contain the prepared
%% query id and column metadata for all the variables (if any).
%% @see execute/3.
%% @see execute/4.
-spec prepare(pid(), 'query'()) ->
    {ok, Result :: seestar_result:prepared_result()} | {error, Error :: seestar_error:error()}.
prepare(Client, Query) ->
    case request(Client, #prepare{'query' = ?l2b(Query)}, true) of
        #result{result = Result} ->
            {ok, Result};
        #error{} = Error ->
            {error, Error}
    end.

%% @doc Synchronously execute a prepared query using the specified consistency level.
%% Use {@link seestar_result} module functions to work with the result.
%% @see prepare/2.
%% @see perform/3.
-spec execute(pid(),
              query_id(),
              [seestar_cqltypes:type()], [seestar_cqltypes:value()],
              seestar:consistency()) ->
        {ok, Result :: seestar_result:result()} | {error, Error :: seestar_error:error()}.
execute(Client, QueryID, Types, Values, Consistency) ->
    Req = #execute{id = QueryID, types = Types, values = Values, consistency = Consistency},
    case request(Client, Req, true) of
        #result{result = Result} ->
            {ok, Result};
        #error{} = Error ->
            {error, Error}
    end.

execute_async(Client, QueryID, Types, Values, Consistency) ->
    Req = #execute{id = QueryID, types = Types, values = Values, consistency = Consistency},
    request(Client, Req, false).

request(Client, Request, Sync) ->
    request(Client, Request, Sync, 30000).

request(#client_handle{pid=Pid, proto=ProtoVsn}, Request, Sync, Timeout) ->
    {ReqOp, ReqBody} = seestar_messages:encode(ProtoVsn, Request),
    case gen_server:call(Pid, {request, ReqOp, ReqBody, Sync}, Timeout) of
        {RespOp, RespBody} ->
            seestar_messages:decode(ProtoVsn, RespOp, RespBody);
        Ref ->
            Ref
    end.

%% -------------------------------------------------------------------------
%% gen_server callback functions
%% -------------------------------------------------------------------------

%% @private
init([Host, Port, ConnectOptions0]) ->
    {Timeout, ConnectOptions1} = get_timeout(ConnectOptions0),
    {Transport , ConnectOptions} = get_transport(ConnectOptions1),
    case create_socket(Host, Port, Transport, ConnectOptions, Timeout) of
        {ok, Sock} ->
            ok = socket_setopts(Sock, Transport, [binary, {packet, 0}, {active, true}]),
            {ok, #st{host = Host, sock = Sock, transport = Transport, buffer = seestar_buffer:new(),
                     free_ids = lists:seq(0, 127), reqs = ets:new(seestar_reqs, [])}};
        {error, Reason} ->
            {stop, {connection_error, Reason}}
    end.

%% @doc
%% Extracts the protocol from the connect options. Returns a tuple where the first element
%% is the transport, and the second is a proplist of the remaining options
-spec get_transport([connect_option()]) -> {ssl|tcp, [connect_option()]}.
get_transport(ConnectOptions0) ->
    case proplists:get_value(ssl, ConnectOptions0) of
        undefined ->
            {tcp, ConnectOptions0};
        SslOptions ->
            NewConnectOptions = proplists:delete(ssl, ConnectOptions0) ++ SslOptions,
            {ssl, NewConnectOptions}
    end.

%% @doc
%% Extracts the timeout from the conenct options. Returns a tuple with the first element
%% being the timeout, and the second a proplist of the remaining options
-spec get_timeout([connect_option()]) -> {ssl|tcp, [connect_option()]}.
get_timeout(ConnectOptions0) ->
    Timeout = proplists:get_value(connect_timeout, ConnectOptions0, infinity),
    NewConnectOptions = proplists:delete(connect_timeout, ConnectOptions0),
    {Timeout, NewConnectOptions}.

create_socket(Host, Port, ssl, SockOpts, Timeout) ->
    ssl:connect(Host, Port, SockOpts, Timeout);
create_socket(Host, Port, tcp, SockOpts, Timeout) ->
    gen_tcp:connect(Host, Port, SockOpts, Timeout).

socket_setopts(Sock, tcp, Options)->
    inet:setopts(Sock, Options);
socket_setopts(Sock, ssl, Options)->
    ssl:setopts(Sock, Options).

%% @private
terminate(_Reason, _St) ->
    ok.

%% @private
handle_call({request, Op, Body, Sync}, From, #st{free_ids = []} = St) ->
    Req = #req{op = Op, body = Body, from = From, sync = Sync},
    {noreply, St#st{backlog = queue:in(Req, St#st.backlog)}};

handle_call({request, Op, Body, Sync}, {_Pid, Ref} = From, St) ->
    case Sync of
        true  -> ok;
        false -> gen_server:reply(From, Ref)
    end,
    case send_request(#req{op = Op, body = Body, from = From, sync = Sync}, St) of
        {ok, St1}       -> {noreply, St1};
        {error, Reason} -> {stop, {socket_error, Reason}, St}
    end;

handle_call(Request, _From, St) ->
    {stop, {unexpected_call, Request}, St}.

send_request(#req{op = Op, body = Body, from = From, sync = Sync},
             #st{proto = ProtoVsn, sock = Sock, transport = Transport} = St) ->
    ID = hd(St#st.free_ids),
    Frame = seestar_frame:new(ProtoVsn, ID, [], Op, Body),
    case send_on_wire(Sock, Transport, seestar_frame:encode(Frame)) of
        ok ->
            ets:insert(St#st.reqs, {ID, From, Sync}),
            {ok, St#st{free_ids = tl(St#st.free_ids)}};
        {error, _Reason} = Error ->
            Error
    end.

send_on_wire(Sock, tcp, Data) ->
    gen_tcp:send(Sock, Data);
send_on_wire(Sock, ssl, Data) ->
    ssl:send(Sock, Data).

%% @private
handle_cast(stop, #st{sock = Sock, transport = tcp} = St) ->
    gen_tcp:close(Sock),
    {stop, normal, St};

handle_cast(stop, #st{sock = Sock, transport = ssl} = St) ->
    ssl:close(Sock),
    {stop, normal, St};

handle_cast({event_listener, Listener}, St) ->
    {noreply, St#st{event_listener = Listener}};

handle_cast({set_protocol_version, ProtoVsn}, St) ->
    {noreply, St#st{proto=ProtoVsn}};
handle_cast(Request, St) ->
    {stop, {unexpected_cast, Request}, St}.

%% @private
handle_info({Transport, Sock, Data}, #st{sock = Sock, transport = Transport} = St) ->
    {Frames, Buffer} = seestar_buffer:decode(St#st.buffer, Data),
    {noreply, process_frames(Frames, St#st{buffer = Buffer})};

handle_info({tcp_closed, Sock}, #st{sock = Sock, transport = tcp} = St) ->
    {stop, socket_closed, St};

handle_info({tcp_error, Sock, Reason}, #st{sock = Sock, transport = tcp} = St) ->
    {stop, {socket_error, Reason}, St};

handle_info({ssl_closed, Sock}, #st{sock = Sock, transport = ssl} = St) ->
    {stop, socket_closed, St};

handle_info({ssl_error, Sock, Reason}, #st{sock = Sock, transport = ssl} = St) ->
    {stop, {socket_error, Reason}, St};

handle_info(Info, St) ->
    {stop, {unexpected_info, Info}, St}.

process_frames([Frame|Frames], St) ->
    process_frames(Frames,
                   case seestar_frame:id(Frame) of
                       -1 -> handle_event(Frame, St);
                       _  -> handle_response(Frame, St)
                   end);
process_frames([], St) ->
    process_backlog(St).

handle_event(_Frame, #st{event_listener = undefined} = St) ->
    St;
handle_event(Frame, #st{event_listener = Pid, proto=ProtoVsn} = St) ->
    Op = seestar_frame:opcode(Frame),
    Body = seestar_frame:body(Frame),
    F = fun() ->
            case seestar_messages:decode(ProtoVsn, Op, Body) of
                #event{event = Event} ->
                    {ok, Event};
                #error{} = Error ->
                    {error, Error}
            end
        end,
    Pid ! {seestar_event, F},
    St.

handle_response(Frame, St) ->
    ID = seestar_frame:id(Frame),
    [{ID, From, Sync}] = ets:lookup(St#st.reqs, ID),
    ets:delete(St#st.reqs, ID),
    Op = seestar_frame:opcode(Frame),
    Body = seestar_frame:body(Frame),
    case Sync of
        true  -> gen_server:reply(From, {Op, Body});
        false -> reply_async(St#st.proto, From, Op, Body)
    end,
    St#st{free_ids = [ID|St#st.free_ids]}.

reply_async(ProtoVsn, {Pid, Ref}, Op, Body) ->
    F = fun() ->
            case seestar_messages:decode(ProtoVsn, Op, Body) of
                #result{result = Result} ->
                    {ok, Result};
                #error{} = Error ->
                    {error, Error}
            end
        end,
    Pid ! {seestar_response, Ref, F}.

process_backlog(#st{backlog = Backlog, free_ids = FreeIDs} = St) ->
    case queue:is_empty(Backlog) orelse FreeIDs =:= [] of
        true ->
            St;
        false ->
            {{value, Req}, Backlog1} = queue:out(Backlog),
            #req{from = {_Pid, Ref} = From, sync = Sync} = Req,
            case Sync of
                true  -> ok;
                false -> gen_server:reply(From, Ref)
            end,
            case send_request(Req, St#st{backlog = Backlog1}) of
                {ok, St1}       -> process_backlog(St1);
                {error, Reason} -> {stop, {socket_error, Reason}, St}
            end
    end.

%% @private
code_change(_OldVsn, St, _Extra) ->
    {ok, St}.
