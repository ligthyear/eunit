%% This library is free software; you can redistribute it and/or modify
%% it under the terms of the GNU Lesser General Public License as
%% published by the Free Software Foundation; either version 2 of the
%% License, or (at your option) any later version.
%%
%% This library is distributed in the hope that it will be useful, but
%% WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
%% Lesser General Public License for more details.
%%
%% You should have received a copy of the GNU Lesser General Public
%% License along with this library; if not, write to the Free Software
%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
%% USA
%%
%% $Id$
%%
%% @author Richard Carlsson <richardc@it.uu.se>
%% @copyright 2009 Richard Carlsson
%% @private
%% @see eunit
%% @doc Generic listener process for eunit.

-module(eunit_listener).

-define(NODEBUG, true).
-include("eunit.hrl").
-include("eunit_internal.hrl").

-export([start/1, start/2]).

-export([behaviour_info/1]).


behaviour_info(callbacks) ->
    [{init,1},{handle_begin,3},{handle_end,3},{handle_cancel,3},
     {terminate,2}];
behaviour_info(_Other) ->
    undefined.


-record(state, {callback,    % callback module
		success = 0,
		fail = 0,
		skipped = 0,
		cancel = false,
		state        % substate
	       }).

start(Callback) ->
    start(Callback, []).

start(Callback, Options) ->
    St = #state{callback = Callback},
    spawn_opt(fun () -> init(St, Options) end,
	      proplists:get_all_values(spawn, Options)).

init(St0, Options) ->
    St1 = call(init, [Options], St0),
    St2 = expect([], undefined, St1),
    Data = [{success, St2#state.success},
	    {fail, St2#state.fail},
	    {skipped, St2#state.skipped},
	    {cancel, St2#state.cancel}],
    call(terminate, [{ok, Data}, St2#state.state], St2),
    exit(normal).

expect(Id, ParentId, St) ->
    case wait_for(Id, 'begin', ParentId) of
	{done, Data} ->
	    {done, Data, St};
	{ok, Msg} ->
	    case Msg of
		{group, Data} ->
		    group(Id, Data, St);
		{test, Data} ->
		    St1 = handle_begin(test, Id, Data, St),
		    case wait_for(Id, 'end', ParentId) of
			{cancel, Reason} ->
			    handle_cancel(test, Id, Data, Reason, St1);
			{ok, Result} ->
			    handle_end(test, Id, Data, Result, St1)
		    end
	    end
    end.

%% collect group items in order until group is done
group(Id, Data, St) ->
    St1 = handle_begin(group, Id, Data, St),
    group_loop(0, Id, Data, St1).

group_loop(N, Id, Data, St) ->
    N1 = N + 1,
    case expect(Id ++ [N1], Id, St) of
	{done, {cancel, Reason}, St1} ->
	    handle_cancel(group, Id, Data, Reason, St1);
	{done, Result, St1} ->
	    handle_end(group, Id, Data, Result, St1);
	St1 ->
	    group_loop(N1, Id, Data, St1)
    end.

%% waiting for [..., M, N] begin
%% get:
%%      [..., M, N] begin test  -> expect [..., M, N] end    (test begin)
%%      [..., M, N] begin group -> expect [..., M, N, 1] end (group begin)
%%      [..., M] end -> expect [..., M+1] begin        (parent end)
%%      cancel([..., M])                               (parent cancel)
%%
%% waiting for [..., M, N] end
%% get:
%%      [..., M, N] end -> expect [..., M, N+1] begin    (seen end)
%%      cancel([..., M, N])                              (cancelled)

wait_for(Id, Type, ParentId) ->
    ?debugFmt("waiting for ~w ~w", [Id, Type]),
    receive
	{status, Id, {progress, Type, Data}} ->
	    ?debugFmt("got status ~w ~w", [Id, Data]),
	    {ok, Data};
	{status, ParentId, {progress, 'end', Data}} when Type =:= 'begin' ->
	    ?debugFmt("got parent end ~w ~w", [ParentId, Data]),
	    {done, Data};
	{status, Id, {cancel, Reason}} when Type =:= 'end' ->
	    ?debugFmt("got cancel ~w ~w", [Id, Reason]),
	    {cancel, Reason};
	{status, ParentId, {cancel, _Reason}} ->
	    ?debugFmt("got parent cancel ~w ~w", [ParentId, _Reason]),
	    {done, {cancel, _Reason}}
    end.

call(F, As, St) when is_atom(F) ->
    try apply(St#state.callback, F, As) of
	Substate -> St#state{state = Substate}
    catch
	Class:Term ->
	    Trace = erlang:get_stacktrace(),
	    if F =/= terminate ->
		    call(terminate, [{error, {Class, Term, Trace}},
				     St#state.state], St);
	       true -> ok
	    end,
	    erlang:raise(Class, Term, Trace)
    end.

handle_begin(group, Id, {Desc, Extra}, St) ->
    Data = [{id, Id}, {desc, Desc} | Extra],
    ?debugFmt("handle_begin group ~w ~w", [Id, Data]),
    call(handle_begin, [group, Data, St#state.state], St);
handle_begin(test, Id, {Desc, Loc, Line}, St) ->
    Data = [{id, Id}, {desc, Desc}, {source, Loc}, {line, Line}],
    ?debugFmt("handle_begin test ~w ~w", [Id, Data]),
    call(handle_begin, [test, Data, St#state.state], St).

handle_end(group, Id, {Desc, Extra}, {Count, Time, Output}, St) ->
    Data = [{id, Id}, {desc, Desc}, {size, Count}, {time, Time}, {output, Output}
	    | Extra],
    ?debugFmt("handle_end group ~w ~w", [Id, Data]),
    call(handle_end, [group, Data, St#state.state], St);
handle_end(test, Id, {Desc, Loc, Line}, {Status, Time, Output}, St) ->
    Data = [{id, Id}, {desc, Desc}, {source, Loc}, {line, Line},
	    {time, Time}, {status, Status}, {output, Output}],
    ?debugFmt("handle_end test ~w ~w", [Id, Data]),
    St1 = case Status of
	      ok -> St#state{success = St#state.success + 1};
	      {skipped,_} -> St#state{skipped = St#state.skipped + 1};
	      {error,_} -> St#state{fail = St#state.fail + 1}
	  end,
    call(handle_end, [test, Data, St#state.state], St1).

handle_cancel(group, Id, {Desc, Extra}, Reason, St) ->
    Data = [{id, Id}, {desc, Desc}, {reason, Reason} | Extra],
    ?debugFmt("handle_cancel group ~w ~w", [Id, Data]),
    call(handle_cancel, [group, Data, St#state.state],
	 St#state{cancel = true});
handle_cancel(test, Id, {Desc, Loc, Line}, Reason, St) ->
    Data = [{id, Id}, {desc, Desc}, {source, Loc}, {line, Line},
	    {reason, Reason}],
    ?debugFmt("handle_cancel test ~w ~w", [Id, Data]),
    call(handle_cancel, [test, Data, St#state.state],
	 St#state{cancel = true}).
