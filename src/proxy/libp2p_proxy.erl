%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p Proxy ==
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy).

-export([
    address/1, port/1
    ,version/0
    ,add_stream_handler/1
    ,dial_framed_stream/3
]).

-define(PROXY_VERSION, "proxy/1.0.0").

-type opt() :: {address, string()} | {port, integer()}.
-export_type([opt/0]).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec address(ets:tab() | list()) -> string() | undefined.
address(Opts) when is_list(Opts) ->
    libp2p_config:get_opt(Opts, [?MODULE, address], undefined);
address(TID) ->
    Opts = libp2p_swarm:opts(TID),
    libp2p_config:get_opt(Opts, [?MODULE, address], undefined).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec port(ets:tab() | list()) -> integer() | undefined.
port(Opts) when is_list(Opts) ->
    libp2p_config:get_opt(Opts, [?MODULE, port], undefined);
port(TID) ->
    Opts = libp2p_swarm:opts(TID),
    libp2p_config:get_opt(Opts, [?MODULE, port], undefined).

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec version() -> string().
version() ->
    ?PROXY_VERSION.

%%--------------------------------------------------------------------
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec add_stream_handler(ets:tab()) -> ok.
add_stream_handler(TID) ->
    libp2p_swarm:add_stream_handler(
        TID
        ,?PROXY_VERSION
        ,{libp2p_framed_stream, server, [libp2p_stream_proxy, self(), TID]}
    ).

%%--------------------------------------------------------------------
%% @doc
%% Dial proxy stream
%% @end
%%--------------------------------------------------------------------
-spec dial_framed_stream(pid(), string(), list()) -> {ok, pid()} | {error, any()} | ignore.
dial_framed_stream(Swarm, Address, Args) ->
    libp2p_swarm:dial_framed_stream(
        Swarm
        ,Address
        ,?PROXY_VERSION
        ,libp2p_stream_proxy
        ,Args
    ).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------