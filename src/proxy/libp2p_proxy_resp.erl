%%%-------------------------------------------------------------------
%% @doc
%% == Libp2p2 Proxy Resp ==
%% Libp2p2 Proxy Resp API
%% @end
%%%-------------------------------------------------------------------
-module(libp2p_proxy_resp).

-export([
    create/1
    ,address/1
]).

-include("pb/libp2p_proxy_pb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type proxy_resp() :: #libp2p_proxy_resp_pb{}.

-export_type([proxy_resp/0]).

%%--------------------------------------------------------------------
%% @doc
%% Create an proxy respuest
%% @end
%%--------------------------------------------------------------------
-spec create(string()) -> proxy_resp().
create(Address) ->
    #libp2p_proxy_resp_pb{address=Address}.

%%--------------------------------------------------------------------
%% @doc
%% Getter
%% @end
%%--------------------------------------------------------------------
-spec address(proxy_resp()) -> string().
address(Req) ->
    Req#libp2p_proxy_resp_pb.address.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

create_test() ->
    ?assertEqual(#libp2p_proxy_resp_pb{address="456"}, create("456")).

get_test() ->
    Req = create("456"),
    ?assertEqual("456", address(Req)).

-endif.
