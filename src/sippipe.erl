%%%--------------------------------------------------------------------
%%% File    : sippipe.erl
%%% Author  : Fredrik Thulin <ft@it.su.se>
%%% Descrip.: Try a given set of destinations sequentially until we
%%%           get a final response from one or them, or have no
%%%           destinations left to try.
%%%
%%% Note    : We should erlang:monitor() our client transactions to
%%%           be alerted when they die.
%%%
%%% Created :  20 Feb 2004 by Fredrik Thulin <ft@it.su.se>
%%--------------------------------------------------------------------
-module(sippipe).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
	 start/5
	]).

-export([test/0]).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("sipsocket.hrl").
-include("siprecords.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------
-record(state, {branch,			%% string(), current client transaction branch
		serverhandler,		%% term(), server transaction handle
		clienttransaction_pid,	%% pid(), current client transaction process
		request,		%% request record(), the request we are working on
		dstlist,		%% list() of sipdst record(), our list of destinations for this request
		timeout,		%% integer(), timeout value for this process and transactions it starts
		endtime,		%% integer(), point in time when we terminate
		warntime,		%% integer(), point in time when we should warn about still being alive
		approxmsgsize,		%% integer(), approximate size of the SIP requests when we send them
		cancelled = false	%% true | false, have we been cancelled or not?
	       }).

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------
-define(WARN_AFTER, 300).

%%====================================================================
%% External functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: start(ServerHandler, ClientPid, Request, Dst, Timeout)
%%           ServerHandler = term(), server transaction handler
%%           ClientPid     = pid() | none, pid of already existing
%%                           client transaction that we should connect
%%                           with the server transaction
%%           Request       = request record(), original request
%%           Dst           = sipurl record() | route |
%%                           list() of sipdst record()
%%           Timeout       = integer(), seconds given for this sippipe
%%                           to finish. Our client transactions
%%                           timeouts will be adjusted to not exceed
%%                           this value in total.
%% Descrip.: Try to be flexible. If we are provided with a URI as
%%           DstList, we resolve it into a list of sipdst records.
%%           If we are given a client transaction handle, we start out
%%           with that one. Otherwise we start a client transaction
%%           and then enter loop/1.
%% Returns : Does not matter
%%--------------------------------------------------------------------
start(ServerHandler, ClientPid, RequestIn, DstIn, Timeout) when is_record(RequestIn, request) ->
    %% call check_proxy_request to get sanity of proxying this request verified (Max-Forwards checked etc)
    try siprequest:check_proxy_request(RequestIn) of
	{ok, NewHeader1, ApproxMsgSize} ->
	    Request1 = RequestIn#request{header = NewHeader1},
	    %% now make sure we know some destinations of this request
	    case start_get_dstlist(ServerHandler, Request1, ApproxMsgSize, DstIn) of
		{ok, DstList, Request} ->
		    %% Adopt server transaction and get it's branch. If ServerHandler is not a valid
		    %% transaction handle, then try to figure the server transaction handler out using Request.
		    case start_get_servertransaction(ServerHandler, Request) of
			{ok, STHandler, Branch} ->
			    guarded_start2(Branch, STHandler, ClientPid, Request, DstList, Timeout, ApproxMsgSize);
			ignore ->
			    ok
		    end;
		error ->
		    %% just end on error, start_get_dstlist will have instructed the STHandler to send an
		    %% SIP error message already.
		    error
	    end
    catch
	throw:
	  {siperror, Status, Reason} ->
	    transactionlayer:send_response_handler(ServerHandler, Status, Reason);
	  {siperror, Status, Reason, ExtraHeaders} ->
	    transactionlayer:send_response_handler(ServerHandler, Status, Reason, ExtraHeaders)
    end.

%%
%% ClientPid /= none
%%
guarded_start2(Branch, ServerHandler, ClientPid, Request, DstListIn, Timeout, ApproxMsgSize)
  when is_record(Request, request), ClientPid /= none ->
    %% A client pid was supplied to us, go to work
    final_start(Branch, ServerHandler, ClientPid, Request, DstListIn, Timeout, ApproxMsgSize);

%%
%% ClientPid == none
%%
guarded_start2(Branch, ServerHandler, none, Request, Dst, Timeout, ApproxMsgSize) when is_record(Request, request) ->
    %% No client transaction handler is specified, start a client transaction on the first
    %% element from the destination list, after making sure it is complete.
    case get_next_sipdst(Dst, ApproxMsgSize) of
	[] ->
	    logger:log(normal, "sippipe: Failed processing request '~s ~s', no valid destination(s) found",
		       [Request#request.method, sipurl:print(Request#request.uri)]),
	    transactionlayer:send_response_handler(ServerHandler, 500, "Destination unreachable"),
	    error;
	[FirstDst | _] = DstList when is_record(FirstDst, sipdst) ->
	    NewRequest = Request#request{uri = FirstDst#sipdst.uri},
	    case local:start_client_transaction(NewRequest, FirstDst, Branch, Timeout) of
		BranchPid when is_pid(BranchPid) ->
		    final_start(Branch, ServerHandler, BranchPid, Request, DstList, Timeout, ApproxMsgSize);
		{error, E} ->
		    logger:log(error, "sippipe: Failed starting client transaction : ~p", [E]),
		    transactionlayer:send_response_handler(ServerHandler, 500, "Server Internal Error"),
		    error
	    end
    end.

%% Do piping between a now existing server and client transaction handler.
final_start(Branch, ServerHandler, ClientPid, Request, [Dst | _] = DstList, Timeout, ApproxMsgSize)
  when is_list(Branch), is_pid(ClientPid), is_record(Request, request), is_record(Dst, sipdst),
       is_integer(Timeout), is_integer(ApproxMsgSize) ->
    Now = util:timestamp(),
    State =
	#state{branch			= Branch,
	       serverhandler		= ServerHandler,
	       clienttransaction_pid	= ClientPid,
	       request			= Request,
	       dstlist			= DstList,
	       approxmsgsize		= ApproxMsgSize,
	       timeout			= Timeout,
	       endtime			= Now + Timeout,
	       warntime			= Now + ?WARN_AFTER
	      },
    logger:log(debug, "sippipe: All preparations finished, entering pipe loop (~p destinations in my list)",
	       [length(DstList)]),
    loop(State).


%%--------------------------------------------------------------------
%% Function: loop(State)
%% Descrip.: Main loop.
%% Returns : Does not matter - does not return until we are finished.
%%--------------------------------------------------------------------
loop(State) when is_record(State, state) ->

    ClientPid = State#state.clienttransaction_pid,
    ServerHandlerPid = transactionlayer:get_pid_from_handler(State#state.serverhandler),

    WarnOrEnd = lists:min([State#state.warntime, State#state.endtime]) - util:timestamp(),
    {Res, NewState} =
	receive
	    {servertransaction_cancelled, ServerHandlerPid, ExtraHeaders} ->
		NewState1 = cancel_transaction(State, "server transaction cancelled", ExtraHeaders),
		{ok, NewState1};

	    {branch_result, _ClientPid, _Branch, _BranchSipState, Response} ->
		NewState1 = process_received_response(Response, State),
		{ok, NewState1};

	    {servertransaction_terminating, ServerHandlerPid} ->
		NewState1 = State#state{serverhandler = none},
		{quit, NewState1};

	    {clienttransaction_terminating, ClientPid, _Branch} ->
		NewState1 = State#state{clienttransaction_pid = none},
		{quit, NewState1};

	    {clienttransaction_terminating, _ClientPid, _Branch} ->
		%% An (at this time) unknown client transaction signals us that it
		%% has terminated. This is probably one of our previously started
		%% client transactions that is now finishing - just ignore the signal.
		{ok, State};

	    Msg ->
		logger:log(error, "sippipe: Received unknown message ~p, ignoring", [Msg]),
		{error, State}
	after
	    WarnOrEnd * 1000 ->
		warn_or_end(State, util:timestamp())
	end,
    case Res of
	quit ->
	    ok;
	_ ->
	    loop(NewState)
    end.

%%--------------------------------------------------------------------
%% Function: warn_or_end(State, Now)
%%           Now = integer(), current time
%% Descrip.: Check to see if it is time to warn, or time to die.
%% Returns : {quit, NewState} |
%%           {Res, NewState}
%%           NewState = state record()
%%           Res      = quit | ok | warn_or_end
%%--------------------------------------------------------------------

%%
%% Time to quit.
%%
warn_or_end(State, Now) when is_record(State, state), Now >= State#state.endtime ->
    logger:log(error, "sippipe: Reached end time after ~p seconds, exiting.", [State#state.timeout]),
    {quit, State};

%%
%% Time to warn
%%
warn_or_end(State, Now) when is_record(State, state), Now >= State#state.warntime ->
    logger:log(error, "sippipe: Warning: pipe process still alive!~nClient handler : ~p, Server handler : ~p",
	       [State#state.clienttransaction_pid, State#state.serverhandler]),
    {ok, State#state{warntime = Now + 60}}.


%%--------------------------------------------------------------------
%% Function: process_received_response(Response, State)
%%           Response = response record()
%% Descrip.: We have received a response. Check if we should do
%%           something.
%% Returns : NewState = state record()
%%--------------------------------------------------------------------
%%
%% We are already cancelled
%%
process_received_response(_Response, #state{cancelled=true}=State) ->
    logger:log(debug, "sippipe: Ignoring response received when cancelled"),
    State;
%%
%% Response = response record()
%%
process_received_response(Response, State) when is_record(Response, response), is_record(State, state) ->
    {Status, Reason} = {Response#response.status, Response#response.reason},
    final_response_event(Status, Reason, forwarded, State),
    process_received_response2(Status, Reason, Response, State);
%%
%% Response = {Status, Reason}
%%
process_received_response({Status, Reason}=Response, State) when is_integer(Status), is_list(Reason),
								 is_record(State, state) ->
    final_response_event(Status, Reason, created, State),
    process_received_response2(Status, Reason, Response, State).

%% part of process_received_response/2
final_response_event(Status, Reason, Origin, State) when Status >= 200 ->
    %% Make event out of final response
    [CurDst | _] = State#state.dstlist,
    L = [{method, (State#state.request)#request.method},
	 {uri, sipurl:print((State#state.request)#request.uri)},
	 {response, lists:concat([Status, " ", Reason])},
	 {origin, Origin},
	 {peer, sipdst:dst2str(CurDst)}],
    event_handler:request_info(normal, State#state.branch, L);
final_response_event(_Status, _Reason, _Origin, _State) ->
    %% non-final response
    ok.

process_received_response2(Status, Reason, Response, State) when Status >= 200, is_record(State, state) ->
    logger:log(debug, "sippipe: Received final response '~p ~s'", [Status, Reason]),
    %% This is a final response. See if local:sippipe_received_response() has an opinion on what
    %% we should do next.
    case local:sippipe_received_response(State#state.request, Response, State#state.dstlist) of
	{huntstop, SendStatus, SendReason} ->
	    %% Don't continue searching, respond something
	    transactionlayer:send_response_handler(State#state.serverhandler, SendStatus, SendReason),
	    %% XXX cancel client handler?
	    State#state{clienttransaction_pid	= none,
			branch			= none,
			dstlist			= []
		       };
	{next, NewDstList} ->
	    %% Continue, possibly with an altered DstList
	    start_next_client_transaction(State#state{dstlist = NewDstList});
	undefined ->
	    %% Use sippipe defaults
	    default_process_received_response(Status, Reason, Response, State)
    end;
process_received_response2(Status, Reason, Response, State) when is_record(Response, response),
								 is_record(State, state) ->
    logger:log(debug, "sippipe: Piping non-final response '~p ~s' to server transaction",
	       [Status, Reason]),
    transactionlayer:send_proxy_response_handler(State#state.serverhandler, Response),
    State.

default_process_received_response(503, _Reason, _Response, State) when is_record(State, state) ->
    start_next_client_transaction(State);
default_process_received_response(Status, Reason, Response, State) when is_record(State, state) ->
    logger:log(debug, "sippipe: Piping final response '~p ~s' to server transaction ~p",
	       [Status, Reason, State#state.serverhandler]),
    case is_record(Response, response) of
	true ->
	    transactionlayer:send_proxy_response_handler(State#state.serverhandler, Response);
	false ->
	    %% this is a locally generated response
	    transactionlayer:send_response_handler(State#state.serverhandler, Status, Reason)
    end,
    State.

%%--------------------------------------------------------------------
%% Function: start_next_client_transaction(State)
%% Descrip.: When this function is called, any previous client
%%           transactions will have received a final response. Start
%%           the next client transaction from State#state.dstlist, or
%%           send a 500 response in case we have no destinations left.
%% Returns : NewState = state record()
%%--------------------------------------------------------------------
start_next_client_transaction(#state{cancelled = false} = State) ->
    case get_next_client_transaction_params(State) of
	{ok, NewRequest, FirstDst, BranchTimeout, NewState} ->
	    case local:start_client_transaction(NewRequest, FirstDst, NewState#state.branch, BranchTimeout) of
		BranchPid when is_pid(BranchPid) ->
		    NewState#state{clienttransaction_pid = BranchPid};
		{error, E} ->
		    logger:log(error, "sippipe: Failed starting client transaction : ~p", [E]),
		    erlang:exit(failed_starting_client_transaction)
	    end;
	{siperror, Status, Reason, ExtraHeaders} ->
	    transactionlayer:send_response_handler(State#state.serverhandler, Status, Reason, ExtraHeaders),
	    State#state{clienttransaction_pid	= none,
			branch			= none,
			dstlist			= []
		       }
    end.

%% part of start_next_client_transaction/1
%% Returns : {ok, NewRequest, FirstDst, BranchTimeout, NewState} |
%%           {siperror, Status, Reason, ExtraHeaders}
get_next_client_transaction_params(State) when is_record(State, state) ->
    case State#state.dstlist of
	[_LastDst] ->
	    logger:log(debug, "sippipe: There are no more destinations to try for this target - " ++
		       "telling server transaction to answer 500 No reachable destination"),
	    %% RFC3261 #16.7 bullet 6 says we SHOULD generate a 500 if a 503 is the best we've got
	    {siperror, 500, "No reachable destination", []};
	[_FailedDst | DstList] ->
	    case get_next_sipdst(DstList, State#state.approxmsgsize) of
		[FirstDst | _] = NewDstList when is_record(FirstDst, sipdst) ->
		    NewBranch = get_next_target_branch(State#state.branch),
		    Request = State#state.request,
		    NewRequest = Request#request{uri = FirstDst#sipdst.uri},
		    %% Figure out what timeout to use. To not get stuck on a single destination, we divide the
		    %% total ammount of time we have at our disposal with the number of remaining destinations
		    %% that we might try. This might not be the ideal algorithm for this, but it is better than
		    %% nothing.
		    SecondsRemaining = State#state.endtime - util:timestamp(),
		    BranchTimeout = SecondsRemaining div length(NewDstList),
		    logger:log(debug, "sippipe: Starting new branch ~p for next destination (~s) (timeout ~p seconds)",
			       [NewBranch, sipdst:dst2str(FirstDst), BranchTimeout]),
		    NewState =
			State#state{branch	= NewBranch,
				    dstlist	= NewDstList
				   },
		    {ok, NewRequest, FirstDst, BranchTimeout, NewState};
		[] ->
		    logger:log(debug, "sippipe: There are no more destinations to try for this target - " ++
			       "telling server transaction to answer '500 No reachable destination'"),
		    %% RFC3261 #16.7 bullet 6 says we SHOULD generate a 500 if a 503 is the best we've got
		    {siperror, 500, "No reachable destination", []}
	    end
    end.

%%--------------------------------------------------------------------
%% Function: get_next_target_branch(In)
%%           In = string()
%% Descrip.: Given the current branch as input, return the next one
%%           to use.
%% Returns: NewBranch = string()
%%--------------------------------------------------------------------
get_next_target_branch(In) ->
    case string:rchr(In, $.) of
	0 ->
	    In ++ ".1";
	Index when is_integer(Index) ->
	    Rhs = string:substr(In, Index + 1),
	    case util:isnumeric(Rhs) of
		true ->
		    Lhs = string:substr(In, 1, Index),
		    Lhs ++ integer_to_list(list_to_integer(Rhs) + 1);
	    	_ ->
	    	    In ++ ".1"
	    end
    end.

%%--------------------------------------------------------------------
%% Function: get_next_sipdst(DstList, ApproxMsgSize)
%%           DstList       = list() of sipdst record()
%%           ApproxMsgSize = integer()
%% Descrip.: Look at the first element of the input DstList. If it is
%%           a URI instead of a sipdst record, then resolve the URI
%%           into sipdst record(s) and prepend the new record(s) to
%%           the input DstList and return the new list
%% Returns : NewDstList = list() of sipdst record()
%%--------------------------------------------------------------------
get_next_sipdst([], _ApproxMsgSize) ->
    [];

get_next_sipdst([#sipdst{proto = undefined, socket = #sipsocket{} = Socket} = Dst | T], ApproxMsgSize) ->
    %% specific socket specified, fill in proto, addr and port
    case sipsocket:get_remote_peer(Socket) of
	{ok, Proto, Addr, Port} ->
	    NewDst = Dst#sipdst{proto = Proto,
				addr  = Addr,
				port  = Port
			       },
	    get_next_sipdst([NewDst | T], ApproxMsgSize);
	not_applicable ->
	    logger:log(error, "sippipe: Can't get remote peer address for sipsocket ~p", [Socket]),
	    get_next_sipdst(T, ApproxMsgSize)
    end;
get_next_sipdst([#sipdst{proto = undefined} = Dst | T], ApproxMsgSize) ->
    URI = Dst#sipdst.uri,
    %% This is an incomplete sipdst, it should have it's URI set so we resolve the rest from here
    case is_record(URI, sipurl)  of
	true ->
	    case sipdst:url_to_dstlist(URI, ApproxMsgSize, URI) of
		DstList when is_list(DstList) ->
		    get_next_sipdst(DstList ++ T, ApproxMsgSize);
		{error, Reason} ->
		    logger:log(error, "sippipe: Failed resolving URI ~s : ~p", [sipurl:print(URI), Reason]),
		    get_next_sipdst(T, ApproxMsgSize)
	    end;
	false ->
	    logger:log(error, "sippipe: Skipping destination with invalid URI : ~p", [URI]),
	    get_next_sipdst(T, ApproxMsgSize)
    end;
get_next_sipdst([H | T] = DstList, ApproxMsgSize) when is_record(H, sipdst) ->
    case transportlayer:is_eligible_dst(H) of
	true ->
	    DstList;
	{false, Reason} ->
	    logger:log(debug, "sippipe: Skipping non-eligible destination (~s) : ~s", [Reason, sipdst:dst2str(H)]),
	    get_next_sipdst(T, ApproxMsgSize)
    end.

%%--------------------------------------------------------------------
%% Function: cancel_transaction(State, Reason, ExtraHeaders)
%%           State        = state record()
%%           Reason       = string()
%%           ExtraHeaders = list() of {Key, ValueList} tuples
%% Descrip.: Our server transaction has been cancelled. Signal the
%%           client transaction.
%% Returns : NewState = state record()
%%--------------------------------------------------------------------
cancel_transaction(#state{cancelled = false} = State, Reason, ExtraHeaders) when is_list(Reason) ->
    logger:log(debug, "sippipe: Original request has been cancelled, asking current "
	       "client transaction handler (~p) to cancel, and answering "
	       "'487 Request Cancelled' to original request",
	       [State#state.clienttransaction_pid]),
    transactionlayer:cancel_client_transaction(State#state.clienttransaction_pid, Reason, ExtraHeaders),
    transactionlayer:send_response_handler(State#state.serverhandler, 487, "Request Cancelled"),
    State#state{cancelled = true};
cancel_transaction(#state{cancelled = true} = State, Reason, _ExtraHeaders) when is_list(Reason) ->
    %% already cancelled
    State.

%%====================================================================
%% Startup functions
%%====================================================================


%%--------------------------------------------------------------------
%% Function: start_get_dstlist(ServerHandler, Request, ApproxMsgSize,
%%                             Dst)
%%           ServerHandler = term(), server transaction handle
%%           Request       = request record()
%%           ApproxMsgSize = integer(), approximate size of formatted
%%                                      request
%%           Dst           = sipurl record() | route |
%%                           list() of sipdst record()
%% Descrip.: Get an initial list of destinations for this request.
%%           This might mean we pop the destination from a Route
%%           header, in which case we return a new request.
%% Returns : {ok, DstList, NewRequest} |
%%           error
%%           DstList    = list of sipdst record()
%%           NewRequest = request record()
%%--------------------------------------------------------------------

%%
%% Dst is an URI
%%
start_get_dstlist(_ServerHandler, Request, _ApproxMsgSize, URI) when is_record(Request, request),
								     is_record(URI, sipurl) ->
    Dst = #sipdst{uri = URI},
    logger:log(debug, "sippipe: Made sipdst record out of URI input : ~s", [sipurl:print(URI)]),
    {ok, [Dst], Request};

%%
%% Dst == route
%%
start_get_dstlist(ServerHandler, Request, ApproxMsgSize, route) when is_record(Request, request),
								     is_integer(ApproxMsgSize) ->
    %% Request should have a Route header
    %% URI passed to process_route_header is foo here
    case siprequest:process_route_header(Request#request.header, Request#request.uri) of
	nomatch ->
	    logger:log(error, "sippipe: No destination given, and request has no Route header"),
	    erlang:fault("no destination and no route", [ServerHandler, Request, route]);
	{ok, NewHeader, DstURI, ReqURI} when is_record(DstURI, sipurl), is_record(ReqURI, sipurl) ->
	    logger:log(debug, "sippipe: Routing request as per the Route header, Destination ~p, Request-URI ~p",
		      [sipurl:print(DstURI), sipurl:print(ReqURI)]),
	    case sipdst:url_to_dstlist(DstURI, ApproxMsgSize, ReqURI) of
                DstList when is_list(DstList) ->
                    {ok, DstList, Request#request{header = NewHeader}};
		{error, nxdomain} ->
		    logger:log(debug, "sippipe: Failed resolving URI ~s : NXDOMAIN (responding "
			       "'604 Does Not Exist Anywhere')", [sipurl:print(DstURI)]),
		    transactionlayer:send_response_handler(ServerHandler, 604, "Does Not Exist Anywhere"),
		    error;
		{error, What} ->
		    logger:log(normal, "sippipe: Failed resolving URI ~s : ~p", [sipurl:print(DstURI), What]),
		    transactionlayer:send_response_handler(ServerHandler, 500, "Failed resolving Route destination"),
		    error
            end
    end;

start_get_dstlist(_ServerHandler, Request, _ApproxMsgSize, [Dst | _] = DstList) when is_record(Request, request),
										     is_record(Dst, sipdst) ->
    {ok, DstList, Request}.

%%--------------------------------------------------------------------
%% Function: start_get_servertransaction(ServerHandler, Request)
%%           ServerHandler = none | term(), server transaction handle
%%           Request       = request record()
%% Descrip.: Assure we have a working server transaction handle.
%%           Either we get one as ServerHandler argument, or we try to
%%           find one using the transaction layer. If the server
%%           transaction has already been cancelled, we return 'ok'.
%% Returns : {ok, STHandler, Branch} |
%%           ignore
%%           STHandler = term()
%%           Branch    = string()
%%--------------------------------------------------------------------
start_get_servertransaction(TH, Request) when is_record(Request, request) ->
    Q = case TH of
	    none -> Request;
	    _ -> TH
	end,
    %% No server transaction handler supplied. Try to find a valid handler using the request,
    %% and get the branch from it
    case transactionlayer:adopt_st_and_get_branchbase(Q) of
	{ok, STHandler, BranchBase} ->
	    {ok, STHandler, BranchBase ++ "-UAC"};
	ignore ->
	    %% Request has already been cancelled, completed or something
	    ignore;
	error ->
	    logger:log(error, "sippipe: Failed adopting server transaction, exiting"),
	    erlang:exit(failed_adopting_server_transaction)
    end.




%%====================================================================
%% Test functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: test()
%% Descrip.: autotest callback
%% Returns : ok | throw()
%%--------------------------------------------------------------------
test() ->
    yxa_test_config:init(incomingproxy, [{sipsocket_blacklisting, false}]),

    %% get_next_target_branch(In)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_next_target_branch/1 - 1"),
    "foo.1" = get_next_target_branch("foo"),

    autotest:mark(?LINE, "get_next_target_branch/1 - 2"),
    "foo.2" = get_next_target_branch("foo.1"),

    autotest:mark(?LINE, "get_next_target_branch/1 - 3"),
    "foo.bar.1" = get_next_target_branch("foo.bar"),


    %% get_next_sipdst(DstList, ApproxMsgSize)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_next_sipdst/2 - 1"),
    %% test normal case with sipsocket
    autotest:store_unit_test_result(?MODULE, {sipsocket_test, get_remote_peer},
				    {ok, yxa_test, "192.0.2.1", 4999}),
    GNSipDst1 = [#sipdst{socket = #sipsocket{proto = yxa_test,
					     module = sipsocket_test
					    }}],
    [#sipdst{proto = yxa_test,
	     addr  = "192.0.2.1",
	     port  = 4999
	    }] = get_next_sipdst(GNSipDst1, 500),
    autotest:clear_unit_test_result(?MODULE, {sipsocket_test, get_remote_peer}),

    autotest:mark(?LINE, "get_next_sipdst/2 - 2"),
    %% test with transport not supporting remote peer
    autotest:store_unit_test_result(?MODULE, {sipsocket_test, get_remote_peer},
				    not_applicable),
    [] = get_next_sipdst(GNSipDst1, 500),
    autotest:clear_unit_test_result(?MODULE, {sipsocket_test, get_remote_peer}),


    autotest:mark(?LINE, "get_next_sipdst/2 - 3"),
    %% test with transport not supporting remote peer, and another one
    autotest:store_unit_test_result(?MODULE, {sipsocket_test, get_remote_peer},
				    not_applicable),
    GNSipURI3 = sipurl:parse("sip:user@192.0.2.3"),
    GNSipDst3 = GNSipDst1 ++ [#sipdst{uri = GNSipURI3}],
    [#sipdst{proto = udp,
	     addr  = "192.0.2.3",
	     uri   = GNSipURI3
	    }] = get_next_sipdst(GNSipDst3, 500),
    autotest:clear_unit_test_result(?MODULE, {sipsocket_test, get_remote_peer}),


    autotest:mark(?LINE, "get_next_sipdst/2 - 4"),
    %% test all kinds of brokenness, only the second last entry is valid
    autotest:store_unit_test_result(?MODULE, dnsutil_test_res,
				    [{{get_ip_port, "unresolvable.example.org", 4999},
				      {error, "testing unresolvable things"}}
				    ]),
    GNSipDst4_1 =
	[#sipdst{uri = foo},
	 #sipdst{uri = sipurl:parse("sip:unresolvable.example.org:4999")}
	],
    GNSipDst4_Tail =
	[#sipdst{proto = udp,
		 addr  = "192.0.2.4",
		 port  = 4998
		},
	 #sipdst{addr = "last entry"}],
    GNSipDst4 = GNSipDst4_1 ++ GNSipDst4_Tail,
    GNSipDst4_Tail = get_next_sipdst(GNSipDst4, 500),
    autotest:clear_unit_test_result(?MODULE, dnsutil_test_res),


    %% get_next_client_transaction_params(State)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_next_client_transaction_params/1 - 1"),
    {siperror, 500, _, []} = get_next_client_transaction_params(#state{dstlist = [#sipdst{}]}),

    autotest:mark(?LINE, "get_next_client_transaction_params/1 - 2"),
    %% test with only an unresolvable destination left
    autotest:store_unit_test_result(?MODULE, dnsutil_test_res,
				    [{{get_ip_port, "unresolvable.example.org", 4999},
				      {error, "testing unresolvable things"}}
				    ]),
    GNCTP_DstL_2 =
	[#sipdst{proto = yxa_test, addr = "failed dst"},
	 #sipdst{uri = sipurl:parse("sip:unresolvable.example.org:4999")}
	],
    GNCTP_State2 =
	#state{dstlist = GNCTP_DstL_2,
	       approxmsgsize = 500
	      },
    {siperror, 500, _, []} = get_next_client_transaction_params(GNCTP_State2),
    autotest:clear_unit_test_result(?MODULE, dnsutil_test_res),

    autotest:mark(?LINE, "get_next_client_transaction_params/1 - 3.0"),
    %% test working case
    GNCTP_NewURL3 = sipurl:parse("sip:new.example.org"),
    GNCTP_DstL_3 =
	[#sipdst{proto = yxa_test, addr = "failed dst"},
	 #sipdst{proto = yxa_test,
		 addr  = "192.0.2.3",
		 port  = 4997,
		 uri   = GNCTP_NewURL3
		}
	],
    GNCTP_State3 =
	#state{dstlist		= GNCTP_DstL_3,
	       approxmsgsize	= 500,
	       branch		= "foo.1",
	       request		= #request{method = "TEST",
					   uri    = sipurl:parse("sip:old.example.org")
					  },
	       endtime		= util:timestamp() + 10
	      },

    autotest:mark(?LINE, "get_next_client_transaction_params/1 - 3.1"),
    GNCTP_Res3 = get_next_client_transaction_params(GNCTP_State3),

    autotest:mark(?LINE, "get_next_client_transaction_params/1 - 3.2"),
    {ok, #request{uri = GNCTP_NewURL3}, #sipdst{addr = "192.0.2.3", port = 4997}, 10, GNCTP_State3_Res} = GNCTP_Res3,
    "foo.2" = GNCTP_State3_Res#state.branch,


    %% start_get_dstlist(ServerHandler, Request, ApproxMsgSize, Dst)
    %%--------------------------------------------------------------------
    %% dst 'route', no Route header - programmer error
    THandler = transactionlayer:test_get_thandler_self(),
    SGD_Request0 = #request{method = "TEST",
			    uri    = sipurl:parse("sip:test.example.org"),
			    header = keylist:from_list([]),
			    body   = <<>>
			   },

    autotest:mark(?LINE, "start_get_dstlist/4 - 1"),
    {'EXIT', {"no destination " ++ _, _}} = (catch start_get_dstlist(THandler, SGD_Request0, 500, route)),


    autotest:mark(?LINE, "start_get_dstlist/4 - 2"),
    SGD_Dst_URL2 = sipurl:parse("sip:foo.example.org:2990"),
    {ok, [#sipdst{uri = SGD_Dst_URL2}], SGD_Request0} = start_get_dstlist(THandler, SGD_Request0, 500, SGD_Dst_URL2),

    autotest:mark(?LINE, "start_get_dstlist/4 - 3"),
    %% test working case
    SGD_RouteURL3 = sipurl:parse("sip:route.example.org:99;lr"),
    SGD_Header3 = keylist:from_list([{"Route", ["<" ++ sipurl:print(SGD_RouteURL3) ++ ">"]}]),
    SGD_Request3 = SGD_Request0#request{header = SGD_Header3},
    SGD_DNS_3 = [{{get_ip_port, "route.example.org", 99},
		  [#sipdns_hostport{family = inet,
				    addr   = "192.0.2.2",
				    port   = 99
				   }]
		 }],
    autotest:store_unit_test_result(?MODULE, dnsutil_test_res, SGD_DNS_3),

    {ok, SGD_Dst3_Res, SGD_Request3_Res} = start_get_dstlist(THandler, SGD_Request3, 500, route),
    SGD_Request3_URI = SGD_Request3#request.uri,
    [#sipdst{addr = "192.0.2.2",
	     uri = SGD_Request3_URI
	    }] = SGD_Dst3_Res,
    SGD_Request3 = SGD_Request3_Res,
    autotest:clear_unit_test_result(?MODULE, dnsutil_test_res),

    autotest:mark(?LINE, "start_get_dstlist/4 - 4"),
    %% test nxdomain
    SGD_Header4 = keylist:from_list([{"Route", ["<sip:route.example.org:99>"]}]),
    SGD_Request4 = SGD_Request0#request{header = SGD_Header4},
    SGD_DNS_4 = [{{get_ip_port, "route.example.org", 99},
		  {error, nxdomain}
		 }],
    autotest:store_unit_test_result(?MODULE, dnsutil_test_res, SGD_DNS_4),
    error = start_get_dstlist(THandler, SGD_Request4, 500, route),

    {604, "Does Not Exist Anywhere", [], <<>>} = get_created_response(),
    autotest:clear_unit_test_result(?MODULE, dnsutil_test_res),

    autotest:mark(?LINE, "start_get_dstlist/4 - 5"),
    %% test other DNS error (timeout)
    SGD_Header5 = keylist:from_list([{"Route", ["<sip:route.example.org:99>"]}]),
    SGD_Request5 = SGD_Request0#request{header = SGD_Header5},
    SGD_DNS_5 = [{{get_ip_port, "route.example.org", 99},
		  {error, timeout}
		 }],
    autotest:store_unit_test_result(?MODULE, dnsutil_test_res, SGD_DNS_5),
    error = start_get_dstlist(THandler, SGD_Request5, 500, route),

    {500, "Failed resolving Route destination", [], <<>>} = get_created_response(),
    autotest:clear_unit_test_result(?MODULE, dnsutil_test_res),

    ok.


get_created_response() ->
    receive
	{'$gen_cast', {create_response, Status, Reason, EH, Body}} ->
	    {Status, Reason, EH, Body};
	M ->
	    Msg = io_lib:format("Test: Unknown signal found in process mailbox :~n~p~n~n", [M]),
	    {error, lists:flatten(Msg)}
    after 0 ->
	    {error, "no created response in my mailbox"}
    end.

