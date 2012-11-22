-module(erlinotify).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-define(log(T),
        error_logger:info_report(
          [process_info(self(),current_function),{line,?LINE},T])).
%% TODO
%% Docs
%% Ets table to store Dir
%% Callback addition

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, watch/1, unwatch/1, callback/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% Record Definitions
%% ------------------------------------------------------------------

%% @type state() = Record :: #state{ fd = term(),
%%                                   dirnames = ets:tid(),
%%                                   watchdescriptors = ets:tid(),
%%                                   callback= term() }.

-record(state, {fd, callback, dirnames, watchdescriptors}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

watch(Name) ->
    gen_server:cast(?MODULE, {watch, Name}).

unwatch(Name) ->
    gen_server:cast(?MODULE, {unwatch, Name}).

callback(CB) ->
    gen_server:cast(?MODULE, {callback, CB}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State} |
%%          {ok, State, Timeout} |
%%          ignore |
%%          {stop, Reason}
%%----------------------------------------------------------------------

init([]) ->
    {ok,Fd} = erlinotify_nif:start(),
    {ok, Ds} = ets_manager:give_me(dirnames),
    {ok, Wds} = ets_manager:give_me(watchdescriptors),
    X = fun(E) -> io:fwrite(standard_error,"~p~n",[E]) end,
    {ok, #state{fd=Fd, callback=X, dirnames = Ds, watchdescriptors=Wds}}.

%%----------------------------------------------------------------------
%% Func: handle_call/3
%% Returns: {reply, Reply, State} |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State} |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, Reply, State} | (terminate/2 is called)
%%          {stop, Reason, State} (terminate/2 is called)
%%----------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%----------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State} |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State} (terminate/2 is called)
%%----------------------------------------------------------------------
handle_cast(stop, State) ->
  {stop, normal, State};
handle_cast({watch, Watch}, State) ->
  {noreply, do_watch(Watch, State)};
handle_cast({unwatch, Unwatch}, State) ->
  {noreply, do_unwatch(Unwatch, State)};
handle_cast({callback, CB}, State) ->
  {noreply, State#state{callback = CB}};
handle_cast(Msg, State) ->
  ?log({unknown_message, Msg}),
  {noreply, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State} |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State} (terminate/2 is called)
%%----------------------------------------------------------------------
handle_info({inotify_event, Wd, Type, Event, Cookie, Name} = Info, State) ->
  CB = State#state.callback,
  case ets:lookup(State#state.watchdescriptors, Wd) of
      [] -> ?log({unknown_file_watch, Info}),
            {noreply, State};
      [{Wd, File}] -> CB({File, Type, Event, Cookie, Name}),
                      {noreply, State}
  end;
handle_info({'ETS-TRANSFER', _Tid, _Pid, new_table}, State) ->
    %% log at some point?
    {noreply, State};
handle_info({'ETS-TRANSFER', Tid, _Pid, reissued} = Info, State) ->
    ?log({rewatch_this, Info}),
    case ets:info(Tid, name) of
        dirnames -> case rewatch(State) of
                        {ok, State} -> ok,
                                       {noreply, State};
                        Error -> ?log({error,Error}),
                                 {noreply, State}
                    end;
        _DontCare -> ?log({ignored, Info}),
                     {noreply, State}
    end;
handle_info(Info, State) ->
  ?log({unknown_message, Info}),
  {noreply, State}.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any (ignored by gen_server)
%%----------------------------------------------------------------------
terminate(_Reason, State) ->
    erlinotify_nif:stop(State#state.fd),
    {close, State#state.fd}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% @spec (Dirname, State) -> state()
%%        State = state()
%%        Dirname = filelib:dirname()
%% @doc Makes a call to the nif to add a resource to
%% watch. Logs on error
do_watch(File, State) ->
    case erlinotify_nif:add_watch(State#state.fd, File) of
        {ok, Wd} -> ets:insert(State#state.dirnames, {File, Wd}),
                    ets:insert(State#state.watchdescriptors, {Wd, File}),
                    State;
        Error -> Error
    end.

%% @spec (Dirname, State) -> state()
%%        State = state()
%%        Dirname = filelib:dirname()
%% @doc Makes a call to the nif to remove a resource to
%% watch. Logs on error
do_unwatch(File, State) ->
    case ets:lookup(State#state.dirnames, File) of
        [] -> State;
        [{File,Wd}] -> case erlinotify_nif:remove_watch(State#state.fd, Wd) of
                  ok -> ets:delete(State#state.dirnames, File),
                        ets:delete(State#state.watchdescriptors, Wd),
                        State;
                  Error -> Error
              end
    end.

%% @spec (state()) -> ok
%% @doc Rewatch everything in the ets table. Assigning a new
%% Wd as we move through.
rewatch(State) ->
    case ets:delete_all_objects(State#state.watchdescriptors) of
        true ->  Key = ets:first(State#state.dirnames),
                 rewatch(State, Key);
        Error -> Error
    end.

rewatch(State, '$end_of_table') ->
    {ok, State};
rewatch(State, Key) ->
    do_watch(Key, State),
    NextKey = ets:next(State#state.dirnames, Key),
    rewatch(State, NextKey).

