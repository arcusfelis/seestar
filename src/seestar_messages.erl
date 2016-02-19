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

%%% @private
-module(seestar_messages).

-export([encode/2, decode/3]).

-include("constants.hrl").
-include("seestar_messages.hrl").

%% requests.
-define(STARTUP, 16#01).
-define(CREDENTIALS, 16#04).
-define(OPTIONS, 16#05).
-define(QUERY, 16#07).
-define(PREPARE, 16#09).
-define(EXECUTE, 16#0A).
-define(REGISTER, 16#0B).
%% responses.
-define(ERROR, 16#00).
-define(READY, 16#02).
-define(AUTHENTICATE, 16#03).
-define(SUPPORTED, 16#06).
-define(RESULT, 16#08).
%% event.
-define(EVENT, 16#0C).

-define(TOPOLOGY_CHANGE, <<"TOPOLOGY_CHANGE">>).
-define(STATUS_CHANGE, <<"STATUS_CHANGE">>).
-define(SCHEMA_CHANGE, <<"SCHEMA_CHANGE">>).

-type outgoing() :: #startup{}
                  | #credentials{}
                  | #options{}
                  | #'query'{}
                  | #prepare{}
                  | #execute{}
                  | #register{}.

-type incoming() :: #error{}
                  | #ready{}
                  | #authenticate{}
                  | #supported{}
                  | #result{}
                  | #event{}.

-define(VERSION, <<"CQL_VERSION">>).
-define(COMPRESSION, <<"COMPRESSION">>).

%% -------------------------------------------------------------------------
%% encoding functions
%% -------------------------------------------------------------------------

-spec encode(integer(), outgoing()) -> {seestar_frame:opcode(), binary()}.
encode(_, #startup{version = Version, compression = Compression}) ->
    KVPairs =
        case Compression of
            undefined ->
                [{?VERSION, Version}];
            Value when is_binary(Value) ->
                [{?VERSION, Version}, {?COMPRESSION, Value}]
        end,
    {?STARTUP, seestar_types:encode_string_map(KVPairs)};

encode(_, #credentials{credentials = KVPairs}) ->
    {?CREDENTIALS, seestar_types:encode_string_map(KVPairs)};

encode(_, #options{}) ->
    {?OPTIONS, <<>>};

encode(_, #'query'{'query' = Query, consistency = Consistency}) ->
    {?QUERY, <<(seestar_types:encode_long_string(Query))/binary,
               (seestar_types:encode_consistency(Consistency))/binary,
               0>>}; % flags v4

encode(_, #prepare{'query' = Query}) ->
    {?PREPARE, seestar_types:encode_long_string(Query)};

encode(_, #execute{id = ID, types = Types, values = Values, consistency = Consistency}) ->
    Variables = [ seestar_cqltypes:encode_value_with_size(Type, Value) ||
                  {Type, Value} <- lists:zip(Types, Values) ],
    {?EXECUTE, list_to_binary([seestar_types:encode_short_bytes(ID),
                               seestar_types:encode_consistency(Consistency),
                               % flags v4 with values (1)
                               1,
                               seestar_types:encode_short(length(Variables)),
                               Variables])};

encode(_, #register{event_types = Types}) ->
    % assert validity of event types.
    Unique = lists:usort(Types),
    [] = Unique -- [topology_change, status_change, schema_change],
    Encoded = [ list_to_binary(string:to_upper(atom_to_list(Type))) || Type <- Types ],
    {?REGISTER, seestar_types:encode_string_list(Encoded)}.

%% -------------------------------------------------------------------------
%% decoding functions
%% -------------------------------------------------------------------------

-spec decode(integer(), seestar_frame:opcode(), binary()) -> incoming().
decode(_, ?ERROR, Body) ->
    {Code, Rest0} = seestar_types:decode_int(Body),
    {Message, Rest1} = seestar_types:decode_string(Rest0),
    #error{code = Code,
           message = Message,
           details = case Code of
                         ?UNAVAILABLE    -> decode_unavailable(Rest1);
                         ?WRITE_TIMEOUT  -> decode_write_timeout(Rest1);
                         ?READ_TIMEOUT   -> decode_read_timeout(Rest1);
                         ?ALREADY_EXISTS -> decode_already_exists(Rest1);
                         ?UNPREPARED     -> decode_unprepared(Rest1);
                         ?READ_FAILURE   -> decode_read_failure(Rest1);
                         ?FUNCTION_FAILURE -> decode_function_failure(Rest1);
                         ?WRITE_FAILURE  -> decode_write_failure(Rest1);
                         _               -> undefined
                     end};

decode(_, ?READY, _Body) ->
    #ready{};

decode(_, ?AUTHENTICATE, Body) ->
    {Class, _} = seestar_types:decode_string(Body),
    #authenticate{class = Class};

decode(_, ?SUPPORTED, Body) ->
    {KVPairs, _} = seestar_types:decode_string_multimap(Body),
    #supported{versions = proplists:get_value(?VERSION, KVPairs),
               compression = proplists:get_value(?COMPRESSION, KVPairs)};

decode(_, ?EVENT, Body) ->
    {EventType, Rest} = seestar_types:decode_string(Body),
    #event{event = case EventType of
                       ?TOPOLOGY_CHANGE -> decode_topology_change(Rest);
                       ?STATUS_CHANGE -> decode_status_change(Rest);
                       ?SCHEMA_CHANGE -> decode_schema_change(Rest)
                   end};

decode(Proto, ?RESULT, Body) ->
    {Kind, Rest} = seestar_types:decode_int(Body),
    #result{result = case Kind of
                         16#01 -> void;
                         16#02 -> decode_rows(Rest);
                         16#03 -> decode_set_keyspace(Rest);
                         16#04 -> decode_prepared(Proto, Rest);
                         16#05 -> decode_schema_change(Rest)
                     end}.

%% -------------------------------------------------------------------------
%% error details
%% -------------------------------------------------------------------------

decode_unavailable(Data) ->
    {Consistency, Rest0} = seestar_types:decode_consistency(Data),
    {Required, Rest1} = seestar_types:decode_int(Rest0),
    {Alive, _} = seestar_types:decode_int(Rest1),
    #unavailable{consistency = Consistency, required = Required, alive = Alive}.

decode_write_timeout(Data) ->
    {Consistency, Rest0} = seestar_types:decode_consistency(Data),
    {Received, Rest1} = seestar_types:decode_int(Rest0),
    {Required, Rest2} = seestar_types:decode_int(Rest1),
    {WriteType, _} = seestar_types:decode_string(Rest2),
    #write_timeout{consistency = Consistency,
                   received = Received,
                   required = Required,
                   write_type = list_to_atom(string:to_lower(binary_to_list(WriteType)))}.

decode_read_timeout(Data) ->
    {Consistency, Rest0} = seestar_types:decode_consistency(Data),
    {Received, Rest1} = seestar_types:decode_int(Rest0),
    {Required, Rest2} = seestar_types:decode_int(Rest1),
    <<DataPresent, _/binary>> = Rest2,
    #read_timeout{consistency = Consistency,
                  received = Received,
                  required = Required,
                  data_present = DataPresent =/= 0}.

decode_already_exists(Data) ->
    {{Keyspace, Table}, _} = decode_table_spec(Data),
    #already_exists{keyspace = Keyspace,
                    table = case Table of
                                 <<>> -> undefined;
                                 _    -> Table
                            end}.

decode_unprepared(Data) ->
    {ID, _} = seestar_types:decode_short_bytes(Data),
    #unprepared{id = ID}.

decode_read_failure(_Data) ->
    ok.

decode_function_failure(_Data) ->
    ok.

decode_write_failure(_Data) ->
    ok.

%% -------------------------------------------------------------------------
%% different result types
%% -------------------------------------------------------------------------

decode_rows(Body) ->
    {Meta, Rest0} = decode_metadata(Body),
    {Count, Rest1} = seestar_types:decode_int(Rest0),
    #rows{metadata = Meta, rows = decode_rows(Meta, Rest1, Count)}.

decode_rows(Meta, Data, Count) ->
    decode_rows(Meta, Data, Count, []).

decode_rows(_, _, 0, Acc) ->
    lists:reverse(Acc);
decode_rows(Meta, Data, Count, Acc) ->
    {Row, Rest} = decode_row(Meta, Data),
    decode_rows(Meta, Rest, Count - 1, [Row|Acc]).

decode_row(Meta, Data) ->
    decode_row(Meta, Data, []).

decode_row([], Data, Row) ->
    {lists:reverse(Row), Data};
decode_row([#column{type = Type}|Meta], Data, Row) ->
    {Value, Rest} = seestar_cqltypes:decode_value_with_size(Type, Data),
    decode_row(Meta, Rest, [Value|Row]).

decode_metadata_pk(Data) ->
    {Flags, Rest0} = seestar_types:decode_int(Data),
    {Count, Rest1} = seestar_types:decode_int(Rest0),
    {PkCount, Rest2} = seestar_types:decode_int(Rest1),
    {_PkIndexes, Rest3} = decode_shorts(PkCount, Rest2),
    Global_table_spec = Flags band 16#01,
    Has_more_pages    = Flags band 16#02,
    No_metadata       = Flags band 16#04,
    {_PagingState, Rest4} = case Has_more_pages of
                               0 -> {undefined, Rest3};
                               1 -> seestar_types:decode_string(Rest3)
                           end,
    {TableSpec, Rest5} = case {Global_table_spec, No_metadata} of
                             {1, 0} -> decode_table_spec(Rest4);
                             _ -> {undefined, Rest4}
                         end,
    case No_metadata of
        0 ->
            decode_column_specs(TableSpec, Rest5, Count);
        1 ->
            {[], Rest5}
    end.

decode_metadata(Data) ->
    {Flags, Rest0} = seestar_types:decode_int(Data),
    {Count, Rest1} = seestar_types:decode_int(Rest0),
    Global_table_spec = Flags band 16#01,
    Has_more_pages    = Flags band 16#02,
    No_metadata       = Flags band 16#04,
    {_PagingState, Rest2} = case Has_more_pages of
                               0 -> {undefined, Rest1};
                               1 -> seestar_types:decode_string(Rest1)
                           end,
    {TableSpec, Rest3} = case {Global_table_spec, No_metadata} of
                             {1, 0} -> decode_table_spec(Rest2);
                             _ -> {undefined, Rest2}
                         end,
    case No_metadata of
        0 ->
            decode_column_specs(TableSpec, Rest3, Count);
        1 ->
            {[], Rest3}
    end.

decode_column_specs(TableSpec, Data, Count) ->
    decode_column_specs(TableSpec, Data, Count, []).

decode_column_specs(_, Data, 0, Meta) ->
    {lists:reverse(Meta), Data};
decode_column_specs(TableSpec, Data, Count, Meta) ->
    {Column, Rest} = decode_column_spec(TableSpec, Data),
    decode_column_specs(TableSpec, Rest, Count - 1, [Column|Meta]).

decode_column_spec(undefined, Data) ->
    {TableSpec, Rest} = decode_table_spec(Data),
    decode_column_spec(TableSpec, Rest);
decode_column_spec({Keyspace, Table}, Data) ->
    {Name, Rest0} = seestar_types:decode_string(Data),
    {Type, Rest1} = seestar_cqltypes:decode_type(Rest0),
    {#column{keyspace = Keyspace, table = Table, name = Name, type = Type}, Rest1}.

decode_table_spec(Data) ->
    {Keyspace, Rest1} = seestar_types:decode_string(Data),
    {TableName, Rest2} = seestar_types:decode_string(Rest1),
    {{Keyspace, TableName}, Rest2}.

decode_target(Data) ->
    {Target, Rest0} = seestar_types:decode_string(Data),
    decode_target_options(Target, Rest0).

decode_target_options(<<"KEYSPACE">>, Rest0) ->
    {Keyspace, Rest1} = seestar_types:decode_string(Rest0),
    {{Keyspace, undefined}, Rest1};
decode_target_options(<<"TABLE">>, Rest0) ->
    {Keyspace, Rest1} = seestar_types:decode_string(Rest0),
    {TableName, Rest2} = seestar_types:decode_string(Rest1),
    {{Keyspace, TableName}, Rest2};
decode_target_options(<<"TYPE">>, Rest0) ->
    {Keyspace, Rest1} = seestar_types:decode_string(Rest0),
    {TypeName, Rest2} = seestar_types:decode_string(Rest1),
    {{Keyspace, TypeName}, Rest2};
decode_target_options(<<"FUNCTION">>, Rest0) ->
    {Keyspace, Rest1} = seestar_types:decode_string(Rest0),
    {Name, Rest2} = seestar_types:decode_string(Rest1),
    {Types, Rest3} = seestar_types:decode_string_list(Rest2),
    {{Keyspace, Name, Types}, Rest3};
decode_target_options(<<"AGGREGATE">>, Rest0) ->
    {Keyspace, Rest1} = seestar_types:decode_string(Rest0),
    {Name, Rest2} = seestar_types:decode_string(Rest1),
    {Types, Rest3} = seestar_types:decode_string_list(Rest2),
    {{Keyspace, Name, Types}, Rest3}.

decode_set_keyspace(Body) ->
    {Keyspace, _} = seestar_types:decode_string(Body),
    #set_keyspace{keyspace = Keyspace}.

decode_prepared(4, Body) ->
    {ID, Rest} = seestar_types:decode_short_bytes(Body),
    {Meta, _} = decode_metadata_pk(Rest),
    #prepared{id = ID, metadata = Meta};
decode_prepared(3, Body) ->
    {ID, Rest} = seestar_types:decode_short_bytes(Body),
    {Meta, _} = decode_metadata(Rest),
    #prepared{id = ID, metadata = Meta}.

decode_topology_change(Body) ->
    {Change, Rest} = seestar_types:decode_string(Body),
    {{Address, Port}, _} = seestar_types:decode_inet(Rest),
    #topology_change{change = list_to_atom(string:to_lower(binary_to_list(Change))),
                     ip = Address,
                     port = Port}.

decode_status_change(Body) ->
    {Change, Rest} = seestar_types:decode_string(Body),
    {{Address, Port}, _} = seestar_types:decode_inet(Rest),
    #status_change{change = list_to_atom(string:to_lower(binary_to_list(Change))),
                   ip = Address,
                   port = Port}.

decode_schema_change(Body) ->
    {Change, Rest} = seestar_types:decode_string(Body),
    {{Keyspace, Table}, _} = decode_target(Rest),
    #schema_change{change = list_to_atom(string:to_lower(binary_to_list(Change))),
                   keyspace = Keyspace,
                   table = case Table of
                               <<>> -> undefined;
                               _    -> Table
                           end}.

decode_shorts(N, Data) ->
    decode_shorts(N, Data, []).

decode_shorts(0, Data, Shorts) ->
    {lists:reverse(Shorts), Data};
decode_shorts(N, Data, Shorts) when N > 0 ->
    {Short, Rest0} = seestar_types:decode_short(Data),
    decode_shorts(N-1, Rest0, [Short|Shorts]).
