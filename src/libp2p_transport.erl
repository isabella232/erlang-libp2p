-module(libp2p_transport).

-type connection_handler() :: {atom(), atom()}.

-callback start_link(ets:tab()) -> {ok, pid()} | ignore | {error, term()}.
-callback start_listener(pid(), string()) -> {ok, [string()], pid()} | {error, term()} | {error, term()}.
-callback connect(pid(), string(), libp2p_swarm:connect_opts(), pos_integer(), ets:tab()) -> {ok, pid()} | {error, term()}.
-callback match_addr(string(), ets:tab()) -> {ok, string()} | false.
-callback sort_addrs([string()]) -> [{integer(), string()}].


-export_type([connection_handler/0]).
-export([start_link/2, for_addr/2, sort_addrs/2, sort_addrs_with_keys/2, connect_to/4, find_session/3,
         start_client_session/3, start_server_session/3]).


start_link(TransportMod, TID) ->
    case TransportMod:start_link(TID) of
        {ok, TransportPid} ->
            libp2p_config:insert_transport(TID, TransportMod, TransportPid),
            %% on bootup we're blocking the top level supervisor's init, so we need to
            %% call back asynchronously
            spawn(fun() ->
                          Server = libp2p_swarm_sup:server(libp2p_swarm:swarm(TID)),
                          gen_server:cast(Server, {register, libp2p_config:transport(), TransportPid})
                  end),
            {ok, TransportPid};
        ignore ->
            %% for some reason we register these transports as `undefined`
            libp2p_config:insert_transport(TID, TransportMod, undefined),
            ignore;
        Other ->
            Other
    end.

-spec for_addr(ets:tab(), string()) -> {ok, string(), {atom(), pid()}} | {error, term()}.
for_addr(TID, Addr) ->
    Matches = lists:foldl(
        fun({Transport, Pid}, Acc) ->
            case Transport:match_addr(Addr, TID) of
                false ->
                    Acc;
                {ok, Matched} ->
                    [{Matched, {Transport, Pid}}|Acc]
            end
        end,
        [],
        libp2p_config:lookup_transports(TID)
    ),
    case Matches of
        [] ->
            {error, {unsupported_address, Addr}};
        [{Matched, {Transport, Pid}}] ->
            {ok, Matched, {Transport, Pid}};
        [{_Matched, {_Transport, _Pid}}|_] ->
            {error, {multiple_match_address, Addr}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% Addresses are sorted by priority ranking from 1 to 5 (1 highest and 5 lowest priority)
%% 1 = NON rfc1918 IP (public IPs), 2 = P2P circuit address (relay), 3 = P2P address,
%% 4 = rfc1918 IPs (private/local IPs), 5 = Proxy transport
%% @end
%%--------------------------------------------------------------------
-spec sort_addrs_with_keys(ets:tab(), [string()]) -> [{non_neg_integer(), string()}].
sort_addrs_with_keys(TID, Addrs) ->
    TransportAddrsFun = fun(Transport) ->
        Matched = lists:filter(fun(Addr) ->
            case Transport:match_addr(Addr, TID) of
                false -> false;
                {ok, _} -> true
            end
        end, Addrs),
        Transport:sort_addrs(Matched)
    end,
    Transports = lists:foldl(
        fun({Transport, _}, Acc) ->
            TransportAddrsFun(Transport) ++ Acc
        end,
        [],
        libp2p_config:lookup_transports(TID)
    ),
    lists:keysort(1, Transports).

-spec sort_addrs(ets:tab(), [string()]) -> [string()].
sort_addrs(TID, Addrs) ->
    {_, SortedAddrLists} = lists:unzip(sort_addrs_with_keys(TID, Addrs)),
    SortedAddrLists.

%% @doc Connect through a transport service. This is a convenience
%% function that verifies the given multiaddr, finds the right
%% transport, and checks if a session already exists for the given
%% multiaddr. The existing session is returned if it already exists,
%% or a `connect' call is made to transport service to perform the
%% actual connect.
-spec connect_to(string(), libp2p_swarm:connect_opts(), pos_integer(), ets:tab())
                -> {ok, pid()} | {error, term()}.
connect_to(Addr, Options, Timeout, TID) ->
    case libp2p_swarm:is_stopping(TID) of
        true -> {error, stopping};
        false ->
            ListenAddrs = libp2p_swarm:listen_addrs(TID),
            case lists:member(Addr, ListenAddrs) of
                true ->
                    {error, dialing_self};
                false ->
                    % TODO: maybe we should add an option to pick a specific session
                    case find_session([Addr], Options, TID) of
                        {ok, _, SessionPid} -> {ok, SessionPid};
                        {error, not_found} ->
                            case for_addr(TID, Addr) of
                                {ok, ConnAddr, {Transport, TransportPid}} ->
                                    lager:debug("~p connecting to ~p", [Transport, ConnAddr]),
                                    try Transport:connect(TransportPid, ConnAddr, Options, Timeout, TID) of
                                        {error, Error} -> {error, Error};
                                        {ok, SessionPid} -> {ok, SessionPid}
                                    catch
                                        What:Why -> {error, {What, Why}}
                                    end
                            end;
                        {error, Error} ->
                            {error, Error}
                    end
            end
    end.

%% @doc Find a existing session for one of a given list of
%% multiaddrs. Returns `{error not_found}' if no session is found.
-spec find_session([string()], libp2p_config:opts(), ets:tab())
                  -> {ok, string(), pid()} | {error, term()}.
find_session([], _Options, _TID) ->
    {error, not_found};
find_session([Addr | Tail], Options, TID) ->
    case for_addr(TID, Addr) of
        {ok, ConnAddr, _} ->
            case libp2p_config:lookup_session(TID, ConnAddr, Options) of
                {ok, Pid} -> {ok, ConnAddr, Pid};
                false -> find_session(Tail, Options, TID)
            end;
        {error, Error} -> {error, Error}
    end.


%%
%% Session negotiation
%%

-spec start_client_session(ets:tab(), string(), libp2p_connection:connection())
                          -> {ok, pid()} | {error, term()}.
start_client_session(TID, Addr, Connection) ->
    Handlers = libp2p_config:lookup_connection_handlers(TID),
    case libp2p_multistream_client:negotiate_handler(Handlers, Addr, Connection) of
        {error, Error} -> {error, Error};
        server_switch ->
            ChildSpec = #{ id => make_ref(),
                           start => {libp2p_multistream_server, start_link, [Connection, Handlers, TID]},
                           restart => temporary,
                           shutdown => 5000,
                           type => worker },
            SessionSup = libp2p_swarm_session_sup:sup(TID),
            case supervisor:start_child(SessionSup, ChildSpec) of
                {ok, SessionPid} ->
                    lager:info("Started simultaneous connection with ~p as ~p", [libp2p_connection:addr_info(Connection), SessionPid]),
                    case libp2p_connection:controlling_process(Connection, SessionPid) of
                        {ok, _} ->
                            libp2p_config:insert_session(TID, Addr, SessionPid, outbound),
                            AddrInfo = libp2p_connection:addr_info(Connection),
                            libp2p_config:insert_session_addr_info(TID, SessionPid, AddrInfo),
                            libp2p_swarm:register_session(libp2p_swarm:swarm(TID), SessionPid),
                            {ok, SessionPid};
                        {error, Error} ->
                            lager:error("Changing controlling process for ~p to ~p failed ~p",
                                        [Connection, SessionPid, Error]),
                            libp2p_connection:close(Connection),
                            {error, Error}
                    end;
                Other ->
                    lager:warning("failed to start simultaneous connection with ~p : ~p", [libp2p_connection:addr_info(Connection), Other]),
                    {error, Other}
            end;
        {ok, {_, {M, F}}} ->
            ChildSpec = #{ id => make_ref(),
                           start => {M, F, [Connection, [], TID]},
                           restart => temporary,
                           shutdown => 5000,
                           type => worker },
            SessionSup = libp2p_swarm_session_sup:sup(TID),
            {ok, SessionPid} = supervisor:start_child(SessionSup, ChildSpec),
            case libp2p_connection:controlling_process(Connection, SessionPid) of
                {ok, _} ->
                    libp2p_config:insert_session(TID, Addr, SessionPid, inbound),
                    AddrInfo = libp2p_connection:addr_info(Connection),
                    libp2p_config:insert_session_addr_info(TID, SessionPid, AddrInfo),
                    libp2p_swarm:register_session(libp2p_swarm:swarm(TID), SessionPid),
                    {ok, SessionPid};
                {error, Error} ->
                    lager:error("Changing controlling process for ~p to ~p failed ~p",
                                [Connection, SessionPid, Error]),
                    libp2p_connection:close(Connection),
                    {error, Error}
            end
    end.


-spec start_server_session(reference(), ets:tab(), libp2p_connection:connection()) -> {ok, pid()} | {error, term()}.
start_server_session(Ref, TID, Connection) ->
    {_, RemoteAddr} = libp2p_connection:addr_info(Connection),
    case libp2p_config:lookup_session(TID, RemoteAddr) of
        {ok, Pid} ->
            % This should really not happen since the remote address
            % should be unique for most transports (e.g. a different
            % port for tcp). It _can_ happen if there is no listen
            % port (a slow listen on start with a fast connect) that
            % is reused which can cause the same inbound remote port
            % to already be the target of a previous outbound
            % connection (using a 0 source port). We prefer the new
            % inbound connection, so close the other connection.
            lager:notice("Duplicate session for ~p at ~p", [RemoteAddr, Pid]),
            libp2p_session:close(Pid);
        false -> ok
    end,
    Handlers = [{Key, Handler} ||
                   {Key, {Handler, _}} <- libp2p_config:lookup_connection_handlers(TID)],
    {ok, SessionPid} = libp2p_multistream_server:start_link(Ref, Connection, Handlers, TID),
    AddrInfo = libp2p_connection:addr_info(Connection),
    libp2p_config:insert_session_addr_info(TID, SessionPid, AddrInfo),
    libp2p_config:insert_session(TID, RemoteAddr, SessionPid, inbound),
    libp2p_swarm:register_session(libp2p_swarm:swarm(TID), SessionPid),
    {ok, SessionPid}.
