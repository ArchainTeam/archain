%%%
%%% @doc Server to queue ar_node state-changing tasks.
%%%

-module(ar_node_worker).

-export([start/2, stop/1, cast/2, call/2, call/3]).

-include("ar.hrl").

%%%
%%% Public API.
%%%

%% @doc Start a node worker.
start(NPid, SPid) ->
	Pid = spawn(fun() -> server(NPid, SPid) end),
	{ok, Pid}.

%% @doc Stop a node worker.
stop(Pid) ->
	Pid ! stop,
	ok.

%% @doc Send an asynchronous task to a node worker. The answer
%% will be sent to the caller.
cast(Pid, Task) ->
	Pid ! {task, Task},
	ok.

%% @doc Send a synchronous task to a node worker. The timeout
%% can be passed, default is 5000 ms.
call(Pid, Task) ->
	call(Pid, Task, 5000).

call(Pid, Task, Timeout) ->
	cast(Pid, Task),
	% TODO mue: Fix, reply is sent to node, need extra way for
	% synchronous calls.
	receive
		{worker, Reply} ->
			Reply
	after
		Timeout ->
			{error, timeout}
	end.

%%%
%%% Server functions.
%%%

%% @doc Main server loop.
server(NPid, SPid) ->
	receive
		{task, Task} ->
			try handle(SPid, Task) of
				Reply ->
					NPid ! {worker, Reply},
					server(NPid, SPid)
			catch
				throw:Term ->
					ar:report( [ {'NodeWorkerEXCEPTION', {Term} } ]),
					server(NPid, SPid);
				exit:Term ->
					ar:report( [ {'NodeWorkerEXIT', Term} ] ),
					server(NPid, SPid);
				error:Term ->
					ar:report( [ {'NodeWorkerERROR', {Term, erlang:get_stacktrace()} } ]),
					server(NPid, SPid)
			end;
		stop ->
			ok
	end.

%% @doc Handle the server tasks. Return values a sent to the caller. Simple tasks like
%% setter can be done directy, more complex ones are handled as private API functions.
handle(SPid, {add_tx, TX}) ->
	{ok, StateIn} = ar_node_state:lookup(SPid, [node, txs, waiting_txs, potential_txs]),
	case add_tx(StateIn, TX) of
		{ok, StateOut} ->
			ar_node_state:update(SPid, StateOut);
		none ->
			ok
	end,
	{ok, add_tx};
handle(SPid, {add_tx, TX, NewGS}) ->
	{ok, StateIn} = ar_node_state:lookup(SPid, [node, txs, waiting_txs, potential_txs]),
	case add_tx(StateIn, TX, NewGS) of
		{ok, StateOut} ->
			ar_node_state:update(SPid, StateOut);
		none ->
			ok
	end,
	{ok, add_tx};
handle(SPid, {encounter_new_tx, TX, NewGS}) ->
	{ok, StateIn} = ar_node_state:lookup(SPid, [txs, waiting_txs, floating_wallet_list]),
	case encounter_new_tx(StateIn, TX, NewGS) of
		{ok, StateOut} ->
			ar_node_state:update(SPid, StateOut);
		none ->
			ok
	end,
	{ok, encounter_new_tx};
handle(SPid, {process_new_block, NewGS, NewB, RecallB, Peer, HashList}) ->
	{ok, StateIn} = ar_node_state:all(SPid),
	case process_new_block(StateIn, NewGS, NewB, RecallB, Peer, HashList) of
		{ok, StateOut} ->
			ar_node_state:update(SPid, StateOut);
		none ->
			ok
	end,
	{ok, process_new_block};
handle(SPid, {work_complete, MinedTXs, Diff, Nonce, Timestamp}) ->
	{ok, StateIn} = ar_node_state:all(SPid),
	case integrate_block_from_miner(StateIn, MinedTXs, Diff, Nonce, Timestamp) of
		{ok, StateOut} ->
			ar_node_state:update(SPid, StateOut);
		none ->
			ok
	end,
	{ok, work_complete};
handle(SPid, {fork_recovered, NewHs}) ->
	{ok, StateIn} = ar_node_state:all(SPid),
	case recovered_from_fork(StateIn, NewHs) of
		{ok, StateOut} ->
			ar_node_state:update(SPid, StateOut);
		none ->
			ok
	end,
	{ok, fork_recovered};
handle(SPid, mine) ->
	{ok, StateIn} = ar_node_state:all(SPid),
	StateOut = ar_node_utils:start_mining(StateIn),
	ar_node_state:update(SPid, StateOut),
	{ok, mine};
handle(SPid, {mine_at_diff, Diff}) ->
	{ok, StateIn} = ar_node_state:all(SPid),
	StateOut = ar_node_utils:start_mining(StateIn, Diff),
	ar_node_state:update(SPid, StateOut),
	{ok, mine};
handle(SPid, automine) ->
	{ok, StateIn} = ar_node_state:all(SPid),
	StateOut = ar_node_utils:start_mining(StateIn#{ automine => true }),
	ar_node_state:update(SPid, StateOut),
	{ok, automine};
handle(SPid, {replace_block_list, [Block | _]}) ->
	ar:d({replaced, [Block#block.indep_hash | Block#block.hash_list]}),
	ar_node_state:update(SPid, [
		{hash_list, [Block#block.indep_hash | Block#block.hash_list]},
		{wallet_list, Block#block.wallet_list},
		{height, Block#block.height}
	]),
	{ok, replace_block_list};
handle(SPid, {ignore, NewGS}) ->
	ar_node_state:update(SPid, [
		{gossip, NewGS}
	]),
	{ok, set_reward_addr};
handle(SPid, {set_reward_addr, Addr}) ->
	ar_node_state:update(SPid, [
		{reward_addr, Addr}
	]),
	{ok, set_reward_addr};
handle(SPid, {add_peers, Peers}) ->
	{ok, GS} = ar_node_state:lookup(SPid, gossip),
	NewGS = ar_gossip:add_peers(GS, Peers),
	ar_node_state:update(SPid, [
		{gossip, NewGS}
	]),
	{ok, add_peers};
handle(SPid, {set_loss_probability, Prob}) ->
	{ok, GS} = ar_node_state:lookup(SPid, gossip),
	ar_node_state:update(SPid, [
		{gossip, ar_gossip:set_loss_probability(GS, Prob)}
	]),
	{ok, set_loss_probability};
handle(SPid, {set_delay, MaxDelay}) ->
	{ok, GS} = ar_node_state:lookup(SPid, gossip),
	ar_node_state:update(SPid, [
		{gossip, ar_gossip:set_delay(GS, MaxDelay)}
	]),
	{ok, set_delay};
handle(SPid, {set_xfer_speed, Speed}) ->
	{ok, GS} = ar_node_state:lookup(SPid, gossip),
	ar_node_state:update(SPid, [
		{gossip, ar_gossip:set_xfer_speed(GS, Speed)}
	]),
	{ok, set_xfer_speed};
handle(SPid, {set_mining_delay, Delay}) ->
	ar_node_state:update(SPid, [
		{mining_delay, Delay}
	]),
	{ok, set_mining_delay};
handle(_SPid, Msg) ->
	{error, {unknown_node_worker_message, Msg}}.

%%%
%%% Private API functions.
%%%

%% @doc Add new transaction to a server state.
add_tx(StateIn, TX) ->
	#{node := Node, waiting_txs := WaitingTXs, potential_txs := PotentialTXs} = StateIn,
	case ar_node_utils:get_conflicting_txs(aggregate_txs(StateIn), TX) of
		[] ->
			timer:send_after(
				calculate_delay(byte_size(TX#tx.data)),
				Node,
				{apply_tx, TX}
			),
			{ok , [
				{waiting_txs, ar_util:unique([TX | WaitingTXs])}
			]};
		_ ->
			% TODO mue: Space in string atom correct?
			ar_tx_db:put(TX#tx.id, ["last_tx_not_valid "]),
			{ok, [
				{potential_txs, ar_util:unique([TX | PotentialTXs])}
			]}
	end.

add_tx(StateIn, TX, NewGS) ->
	#{node := Node, waiting_txs := WaitingTXs, potential_txs := PotentialTXs} = StateIn,
	case ar_node_utils:get_conflicting_txs(aggregate_txs(StateIn), TX) of
		[] ->
			timer:send_after(
				calculate_delay(byte_size(TX#tx.data)),
				Node,
				{apply_tx, TX}
			),
			{ok, [
				{waiting_txs, ar_util:unique([TX | WaitingTXs])},
				{gossip, NewGS}
			]};
		_ ->
			{ok, [
				{potential_txs, ar_util:unique([TX | PotentialTXs])},
				{gossip, NewGS}
			]}
	end.

%% @doc Update miner and amend server state when encountering a new transaction.
encounter_new_tx(StateIn, TX, NewGS) ->
	#{txs := TXs, waiting_txs := WaitingTXs, floating_wallet_list := FloatingWalletList} = StateIn,
	memsup:start_link(),
	{_, Mem} = lists:keyfind(system_total_memory, 1, memsup:get_system_memory_data()),
	case (Mem div 4) > byte_size(TX#tx.data) of
		true ->
			NewTXs = TXs ++ [TX],
			{ok, [
				{txs, NewTXs},
				{floating_wallet_list, ar_node_utils:apply_tx(FloatingWalletList, TX)},
				{gossip, NewGS},
				{waiting_txs, WaitingTXs -- [TX]}
			]};
		false ->
			{ok, [
				{gossip, NewGS},
				{waiting_txs, WaitingTXs -- [TX]}
			]}
	end.

%% @doc Validate whether a new block is legitimate, then handle it, optionally
%% dropping or starting a fork recoverer as appropriate.
process_new_block(_StateIn, NewGS, NewB, _, _Peer, not_joined) ->
	ar_join:start(ar_gossip:peers(NewGS, NewB)),
	none;
process_new_block(#{ height := Height } = StateIn, NewGS, NewB, unavailable, Peer, HashList)
		when NewB#block.height == Height + 1 ->
	% This block is at the correct height.
	RecallHash = ar_node_utils:find_recall_hash(NewB, HashList),
	FullBlock = ar_node_utils:get_full_block(Peer, RecallHash, HashList),
	case ?IS_BLOCK(FullBlock) of
		true ->
			% TODO: Cleanup full block -> shadow generation.
			RecallShadow = FullBlock#block { txs = [
													T#tx.id
													||
													T <- FullBlock#block.txs] },
			ar_storage:write_full_block(FullBlock),
			StateNext = StateIn#{ gossip => NewGS },
			process_new_block(StateNext, NewGS, NewB, RecallShadow, Peer, HashList);
		false ->
			ar:d(failed_to_get_recall_block),
			none
	end;
process_new_block(#{ height := Height } = StateIn, NewGS, NewB, RecallB, Peer, HashList)
		when NewB#block.height == Height + 1 ->
	% This block is at the correct height.
	StateNext = StateIn#{ gossip => NewGS },
	#{
		reward_pool := RewardPool,
		wallet_list := WalletList
	} = StateNext,
	% If transaction not found in state or storage, txlist built will be
	% incomplete and will fail in validate
	TXs = lists:foldr(
		fun(T, Acc) ->
			case [ TX || TX <- aggregate_txs(StateNext), TX#tx.id == T ] of
				[] ->
					case ar_storage:read_tx(T) of
						unavailable -> Acc;
						TX			-> [TX | Acc]
					end;
				[TX | _] ->
					[TX | Acc]
			end
		end,
		[],
		NewB#block.txs
	),
	{FinderReward, _} =
		ar_node_utils:calculate_reward_pool(
			RewardPool,
			TXs,
			NewB#block.reward_addr,
			ar_node_utils:calculate_proportion(
				RecallB#block.block_size,
				NewB#block.weave_size,
				NewB#block.height
			)
		),
	NewWalletList =
		ar_node_utils:apply_mining_reward(
			ar_node_utils:apply_txs(WalletList, TXs),
			NewB#block.reward_addr,
			FinderReward,
			NewB#block.height
		),
	StateNew = StateNext#{ wallet_list => NewWalletList },
	% TODO mue: Setting the state gossip for fork_recover/3 has to be
	% checked. The gossip is already set to NewGS in first function
	% statement. Compare to pre-refactoring.
	StateOut = case ar_node_utils:validate(StateNew, NewB, TXs, ar_util:get_head_block(HashList), RecallB) of
		true ->
			% The block is legit. Accept it.
			case whereis(fork_recovery_server) of
				undefined -> ar_node_utils:integrate_new_block(StateNew, NewB);
				_		  -> ar_node_utils:fork_recover(StateNext#{ gossip => NewGS }, Peer, NewB)
			end;
		false ->
			ar:d({could_not_validate_new_block, ar_util:encode(NewB#block.indep_hash)}),
			ar_node_utils:fork_recover(StateNext#{ gossip => NewGS }, Peer, NewB)
	end,
	{ok, StateOut};
process_new_block(#{ height := Height }, NewGS, NewB, _RecallB, _Peer, _HashList)
		when NewB#block.height =< Height ->
	% Block is lower than us, ignore it.
	ar:report(
		[
			{ignoring_block_below_current, ar_util:encode(NewB#block.indep_hash)},
			{current_height, Height},
			{proposed_block_height, NewB#block.height}
		]
	),
	{ok, [{gossip, NewGS}]};
process_new_block(#{ height := Height } = StateIn, NewGS, NewB, _RecallB, Peer, _HashList)
		when (NewB#block.height > Height + 1) ->
	StateOut = ar_node_utils:fork_recover(StateIn#{ gossip => NewGS }, Peer, NewB),
	{ok, StateOut}.

%% @doc Verify a new block found by a miner, integrate it.
integrate_block_from_miner(#{ hash_list := not_joined }, _MinedTXs, _Diff, _Nonce, _Timestamp) ->
	none;
integrate_block_from_miner(StateIn, MinedTXs, Diff, Nonce, Timestamp) ->
	#{
		id            := BinID,
		node          := Node,
		hash_list     := HashList,
		wallet_list   := RawWalletList,
		txs           := TXs,
		gossip        := GS,
		reward_addr   := RewardAddr,
		tags          := Tags,
		reward_pool   := OldPool,
		weave_size    := OldWeaveSize,
		potential_txs := PotentialTXs
	} = StateIn,
	% Calculate the new wallet list (applying TXs and mining rewards).
	RecallB = ar_node_utils:find_recall_block(HashList),
	WeaveSize = OldWeaveSize +
		lists:foldl(
			fun(TX, Acc) ->
				Acc + byte_size(TX#tx.data)
			end,
			0,
			TXs
		),
	{FinderReward, RewardPool} =
		ar_node_utils:calculate_reward_pool(
			OldPool,
			MinedTXs,
			RewardAddr,
			ar_node_utils:calculate_proportion(
				RecallB#block.block_size,
				WeaveSize,
				length(HashList)
			)
		),
	ar:report(
		[
			calculated_reward_for_mined_block,
			{finder_reward, FinderReward},
			{new_reward_pool, RewardPool},
			{reward_address, RewardAddr},
			{old_reward_pool, OldPool},
			{txs, length(MinedTXs)},
			{recall_block_size, RecallB#block.block_size},
			{weave_size, WeaveSize},
			{length, length(HashList)}
		]
	),
	WalletList =
		ar_node_utils:apply_mining_reward(
			ar_node_utils:apply_txs(RawWalletList, MinedTXs),
			RewardAddr,
			FinderReward,
			length(HashList)
		),
	% Store the transactions that we know about, but were not mined in
	% this block.
	NotMinedTXs =
		lists:filter(
			fun(T) -> ar_tx:verify(T, Diff, WalletList) end,
			ar_node_utils:filter_all_out_of_order_txs(WalletList, TXs -- MinedTXs)
		),
	StateNew = StateIn#{ wallet_list => WalletList },
	% Build the block record, verify it, and gossip it to the other nodes.
	[NextB | _] = ar_weave:add(
		HashList, MinedTXs, HashList, RewardAddr, RewardPool,
		WalletList, Tags, RecallB, Diff, Nonce, Timestamp),
	case ar_node_utils:validate(
			StateNew,
			NextB,
			MinedTXs,
			ar_util:get_head_block(HashList),
			RecallB = ar_node_utils:find_recall_block(HashList)) of
		false ->
			ar:report_console(miner_produced_invalid_block),
			case rand:uniform(5) of
				1 ->
					#{ gossip := StateInGS } = StateIn,
					{ok, ar_node_utils:reset_miner(
						StateIn#{
							gossip		  => StateInGS,
							txs			  => [], % TXs not included in the block
							potential_txs => []
						}
					)};
				_ ->
					{ok, ar_node_utils:reset_miner(StateIn)}
			end;
		true ->
			ar_storage:write_tx(MinedTXs),
			ar_storage:write_block(NextB),
			app_search:update_tag_table(NextB),
			{NewGS, _} =
				ar_gossip:send(
					GS,
					{new_block, self(), NextB#block.height, NextB, RecallB}
				),
			ar:report_console(
				[
					{node, self()},
					{accepted_block, NextB#block.height},
					{indep_hash, ar_util:encode(NextB#block.indep_hash)},
					{recall_block, RecallB#block.height},
					{recall_hash, RecallB#block.indep_hash},
					{txs, length(MinedTXs)},
					case is_atom(RewardAddr) of
						true -> {reward_address, unclaimed};
						false -> {reward_address, ar_util:encode(RewardAddr)}
					end
				]
			),
			lists:foreach(
				fun(MinedTX) ->
					ar:report(
						{successfully_mined_tx_into_block, ar_util:encode(MinedTX#tx.id)}
					)
				end,
				MinedTXs
			),
			lists:foreach(
				fun(T) ->
					ar_tx_db:maybe_add(T#tx.id)
				end,
				PotentialTXs
			),
			NewHL = [NextB#block.indep_hash | HashList],
			ar_storage:write_block_hash_list(BinID, NewHL),
			{ok, ar_node_utils:reset_miner(
				StateNew#{
					hash_list => NewHL,
					gossip               => NewGS,
					txs                  => ar_track_tx_db:remove_bad_txs(NotMinedTXs), % TXs not included in the block
					height               => NextB#block.height,
					floating_wallet_list => ar_node_utils:apply_txs(WalletList, NotMinedTXs),
					reward_pool          => RewardPool,
					potential_txs        => [],
					diff                 => NextB#block.diff,
					last_retarget        => NextB#block.last_retarget,
					weave_size           => NextB#block.weave_size
				}
			)}
	end.


%% @doc Handle executed fork recovery.
recovered_from_fork(#{ id := BinID, hash_list := HashList } = StateIn, NewHs) when HashList == not_joined ->
	NewB = ar_storage:read_block(hd(NewHs), NewHs),
	ar:report_console(
		[
			node_joined_successfully,
			{height, NewB#block.height}
		]
	),
	case whereis(fork_recovery_server) of
		undefined -> ok;
		_		  -> erlang:unregister(fork_recovery_server)
	end,
	% ar_cleanup:remove_invalid_blocks(NewHs),
	TXPool = maps:get(txs, StateIn) ++ maps:get(potential_txs, StateIn),
	TXs =
		ar_node_utils:filter_all_out_of_order_txs(
			NewB#block.wallet_list,
			TXPool
		),
	PotentialTXs = TXPool -- TXs,
	ar_storage:write_block_hash_list(BinID, NewHs),
	{ok, ar_node_utils:reset_miner(
		StateIn#{
			hash_list            => NewHs,
			wallet_list          => NewB#block.wallet_list,
			height               => NewB#block.height,
			reward_pool          => NewB#block.reward_pool,
			floating_wallet_list => NewB#block.wallet_list,
			txs                  => TXs,
			potential_txs        => PotentialTXs,
			diff                 => NewB#block.diff,
			last_retarget        => NewB#block.last_retarget,
			weave_size           => NewB#block.weave_size
		}
	)};
recovered_from_fork(#{ id := BinID, hash_list := HashList } = StateIn, NewHs) when (length(NewHs)) > (length(HashList)) ->
	% TODO mue: Comparing lengths of lists might get quite expensive.
	case whereis(fork_recovery_server) of
		undefined -> ok;
		_		  -> erlang:unregister(fork_recovery_server)
	end,
	NewB = ar_storage:read_block(hd(NewHs), NewHs),
	ar:report_console(
		[
			fork_recovered_successfully,
			{height, NewB#block.height}
		]
	),
	% ar_cleanup:remove_invalid_blocks(NewHs),
	TXPool = maps:get(txs, StateIn) ++ maps:get(potential_txs, StateIn),
	TXs =
		ar_node_utils:filter_all_out_of_order_txs(
			NewB#block.wallet_list,
			TXPool
		),
	PotentialTXs = TXPool -- TXs,
	NewHS = [NewB#block.indep_hash | NewB#block.hash_list],
	ar_storage:write_block_hash_list(BinID, NewHS),
	{ok, ar_node_utils:reset_miner(
		StateIn#{
			hash_list            => NewHS,
			wallet_list          => NewB#block.wallet_list,
			height               => NewB#block.height,
			reward_pool          => NewB#block.reward_pool,
			floating_wallet_list => NewB#block.wallet_list,
			txs                  => TXs,
			potential_txs        => PotentialTXs,
			diff                 => NewB#block.diff,
			last_retarget        => NewB#block.last_retarget,
			weave_size           => NewB#block.weave_size
		}
	)};
recovered_from_fork(_StateIn, _) ->
	none.

%% @doc Aggregates the transactions of a state to one list.
aggregate_txs(#{txs := TXs, waiting_txs := WaitingTXs, potential_txs := PotentialTXs}) ->
	TXs ++ WaitingTXs ++ PotentialTXs.

%% @doc Calculate the time a tx must wait after being received to be mined.
%% Wait time is a fixed interval combined with a wait dependent on tx data size.
%% This wait helps ensure that a tx has propogated around the network.
%% NB: If debug is defined no wait is applied.
-ifdef(DEBUG).
-define(FIXED_DELAY, 0).
-endif.

-ifdef(FIXED_DELAY).
calculate_delay(0) ->
	?FIXED_DELAY;
calculate_delay(Bytes) ->
	?FIXED_DELAY.
-else.
calculate_delay(0) ->
	30000;
calculate_delay(Bytes) ->
	30000 + ((Bytes * 300) div 1000).
-endif.

%%%
%%% EOF
%%%
