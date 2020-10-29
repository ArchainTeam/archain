-module(ar_storage).

-export([
	start/0,
	write_block/1, write_full_block/1, write_full_block/2,
	read_block/1, read_block/2,
	invalidate_block/1, blocks_on_disk/0,
	write_tx/1, write_tx_data/1, write_tx_data/2, read_tx/1, read_tx_data/1,
	read_wallet_list/1, write_wallet_list/4, write_wallet_list/2, write_wallet_list_chunk/4,
	write_block_index/1, read_block_index/0,
	delete_full_block/1, delete_tx/1, delete_block/1,
	enough_space/1, select_drive/2,
	calculate_disk_space/0, calculate_used_space/0, start_update_used_space/0, get_free_space/0,
	lookup_block_filename/1, lookup_tx_filename/1, wallet_list_filepath/1,
	tx_filepath/1, tx_data_filepath/1,
	read_tx_file/1, read_migrated_v1_tx_file/1,
	ensure_directories/0, clear/0,
	write_file_atomic/2,
	has_chunk/1, write_chunk/3, read_chunk/1, delete_chunk/1,
	write_term/2, write_term/3, read_term/1, read_term/2, delete_term/1
]).

-include("ar.hrl").
-include("ar_wallets.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%%% Reads and writes blocks from disk.

-define(DIRECTORY_SIZE_TIMER, 300000).

%% @doc Ready the system for block/tx reading and writing.
%% %% This function should block.
start() ->
	ar_firewall:start(),
	ensure_directories(),
	ok = migrate_block_filenames(),
	count_blocks_on_disk(),
	case ar_meta_db:get(disk_space) of
		undefined ->
			ar_meta_db:put(disk_space, calculate_disk_space()),
			ok;
		_ ->
			ok
	end.

migrate_block_filenames() ->
	case v1_migration_file_exists() of
		true ->
			ok;
		false ->
			DataDir = ar_meta_db:get(data_dir),
			BlockDir = filename:join(DataDir, ?BLOCK_DIR),
			{ok, Filenames} = file:list_dir(BlockDir),
			lists:foreach(
				fun(Filename) ->
					case string:split(Filename, ".json") of
						[Height_Hash, []] ->
							case string:split(Height_Hash, "_") of
								[_, H] when length(H) == 64 ->
									rename_block_file(BlockDir, Filename, H ++ ".json");
								_ ->
									noop
							end;
						_ ->
							noop
					end
				end,
				Filenames
			),
			complete_v1_migration()
	end.

v1_migration_file_exists() ->
	filelib:is_file(v1_migration_file()).

v1_migration_file() ->
	filename:join([ar_meta_db:get(data_dir), ?STORAGE_MIGRATIONS_DIR, "v1"]).

rename_block_file(BlockDir, Source, Dest) ->
	file:rename(filename:join(BlockDir, Source), filename:join(BlockDir, Dest)).

complete_v1_migration() ->
	write_file_atomic(v1_migration_file(), <<>>).

count_blocks_on_disk() ->
	spawn(
		fun() ->
			DataDir = ar_meta_db:get(data_dir),
			case file:list_dir(filename:join(DataDir, ?BLOCK_DIR)) of
				{ok, List} ->
					ar_meta_db:put(blocks_on_disk, length(List) - 1); %% - the "invalid" folder
				{error, Reason} ->
					ar:warn([
						{event, failed_to_count_blocks_on_disk},
						{reason, Reason}
					]),
					error
			end
		end
	).

%% @doc Ensure that all of the relevant storage directories exist.
ensure_directories() ->
	DataDir = ar_meta_db:get(data_dir),
	%% Append "/" to every path so that filelib:ensure_dir/1 creates a directory if it does not exist.
	filelib:ensure_dir(filename:join(DataDir, ?TX_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?BLOCK_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?WALLET_LIST_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?HASH_LIST_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?STORAGE_MIGRATIONS_DIR) ++ "/"),
	filelib:ensure_dir(filename:join([DataDir, ?TX_DIR, "migrated_v1"]) ++ "/").

%% @doc Clear the cache of saved blocks.
clear() ->
	lists:map(
		fun file:delete/1,
		filelib:wildcard(filename:join([ar_meta_db:get(data_dir), ?BLOCK_DIR, "*.json"]))
	),
	ar_meta_db:put(blocks_on_disk, 0).

%% @doc Returns the number of blocks stored on disk.
blocks_on_disk() ->
	ar_meta_db:get(blocks_on_disk).

%% @doc Move a block into the 'invalid' block directory.
invalidate_block(B) ->
	ar_meta_db:increase(blocks_on_disk, -1),
	TargetFile = invalid_block_filepath(B),
	filelib:ensure_dir(TargetFile),
	file:rename(block_filepath(B), TargetFile).

write_block(Blocks) when is_list(Blocks) ->
	lists:foldl(
		fun	(B, ok) ->
				write_block(B);
			(_B, Acc) ->
				Acc
		end,
		ok,
		Blocks
	);
write_block(B) ->
	case ar_meta_db:get(disk_logging) of
		true ->
			ar:info([
				{event, writing_block_to_disk},
				{block, ar_util:encode(B#block.indep_hash)}
			]);
		_ ->
			do_nothing
	end,
	Filepath = block_filepath(B),
	case filelib:is_file(Filepath) of
		true ->
			ok;
		false ->
			BlockJSON = ar_serialize:jsonify(ar_serialize:block_to_json_struct(B)),
			ByteSize = byte_size(BlockJSON),
			case enough_space(ByteSize) of
				true ->
					case write_file_atomic(Filepath, BlockJSON) of
						ok ->
							ar_meta_db:increase(blocks_on_disk, 1),
							ar_meta_db:increase(used_space, ByteSize);
						Error ->
							Error
					end;
				false ->
					ar:err(
						[
							{event, not_enough_space_to_write_block}
						]
					),
					{error, not_enough_space}
			end
	end.

write_full_block(B) ->
	BShadow = B#block{ txs = [T#tx.id || T <- B#block.txs] },
	write_full_block(BShadow, B#block.txs).

write_full_block(BShadow, TXs) ->
	case write_tx(TXs) of
		Response when Response == ok orelse Response == {error, firewall_check} ->
			case write_block(BShadow) of
				ok ->
					StoreTags = case ar_meta_db:get(arql_tags_index) of
						true ->
							store_tags;
						_ ->
							do_not_store_tags
					end,
					ar_arql_db:insert_full_block(BShadow#block{ txs = TXs }, StoreTags),
					app_ipfs:maybe_ipfs_add_txs(TXs),
					ok;
				Error ->
					Error
			end;
		Error ->
			Error
	end.

%% @doc Read a block from disk, given a height
%% and a block index (used to determine the hash by height).
read_block(Height, BI) when is_integer(Height) ->
	case Height of
		_ when Height < 0 ->
			unavailable;
		_ when Height > length(BI) - 1 ->
			unavailable;
		_ ->
			{H, _, _} = lists:nth(length(BI) - Height, BI),
			read_block(H)
	end;
read_block(H, _BI) ->
	read_block(H).

%% @doc Read a block from disk, given a hash, a height, or a block index entry.
read_block(unavailable) ->
	unavailable;
read_block(B) when is_record(B, block) ->
	B;
read_block(Blocks) when is_list(Blocks) ->
	lists:map(fun(B) -> read_block(B) end, Blocks);
read_block({H, _, _}) ->
	read_block(H);
read_block(BH) ->
	case lookup_block_filename(BH) of
		unavailable ->
			unavailable;
		Filename ->
			case file:read_file(Filename) of
				{ok, JSON} ->
					case parse_block_shadow_json(JSON) of
						{error, _} ->
							invalidate_block(BH),
							unavailable;
						{ok, B} ->
							B
					end;
				{error, _} ->
					unavailable
			end
	end.

parse_block_shadow_json(JSON) ->
	case ar_serialize:json_decode(JSON) of
		{ok, JiffyStruct} ->
			case catch ar_serialize:json_struct_to_block(JiffyStruct) of
				B when is_record(B, block) ->
					{ok, B};
				_ ->
					{error, json_struct_to_block}
			end;
		Error ->
			Error
	end.

%% @doc Recalculate the used space in bytes of the data directory disk.
start_update_used_space() ->
	spawn(
		fun() ->
			UsedSpace = ar_meta_db:get(used_space),
			catch ar_meta_db:put(used_space, max(calculate_used_space(), UsedSpace)),
			timer:apply_after(
				?DIRECTORY_SIZE_TIMER,
				?MODULE,
				start_update_used_space,
				[]
			)
		end
	).

%% @doc Return available disk space, in bytes.
get_free_space() ->
	max(0, ar_meta_db:get(disk_space) - ar_meta_db:get(used_space)).

lookup_block_filename(H) ->
	Name = filename:join([
		ar_meta_db:get(data_dir),
		?BLOCK_DIR,
		binary_to_list(ar_util:encode(H)) ++ ".json"
	]),
	case filelib:is_file(Name) of
		true ->
			Name;
		false ->
			unavailable
	end.

%% @doc Remove the block header, its transaction headers, and its wallet list.
%% Return {ok, BytesRemoved} if everything was removed successfully or either
%% of the files has been already removed.
delete_full_block(H) ->
	case read_block(H) of
		unavailable ->
			{ok, 0};
		B ->
			DeleteTXsResult =
				lists:foldl(
					fun (TXID, {ok, Bytes}) ->
							case delete_tx(TXID) of
								{ok, BytesRemoved} ->
									{ok, Bytes + BytesRemoved};
								Error ->
									Error
							end;
						(_TXID, Acc) ->
							Acc
					end,
					{ok, 0},
					B#block.txs
				),
			case DeleteTXsResult of
				{ok, TXBytesRemoved} ->
					case delete_wallet_list(B#block.wallet_list) of
						{ok, WalletListBytesRemoved} ->
							case delete_block(H) of
								{ok, BlockBytesRemoved} ->
									BytesRemoved =
										TXBytesRemoved +
										WalletListBytesRemoved +
										BlockBytesRemoved,
									{ok, BytesRemoved};
								Error ->
									Error
							end;
						Error ->
							Error
					end;
				Error ->
					Error
			end
	end.

delete_wallet_list(RootHash) ->
	WalletListFile = wallet_list_filepath(RootHash),
	case filelib:is_file(WalletListFile) of
		true ->
			case file:read_file_info(WalletListFile) of
				{ok, FileInfo} ->
					case file:delete(WalletListFile) of
						ok ->
							ar_meta_db:increase(used_space, -FileInfo#file_info.size),
							{ok, FileInfo#file_info.size};
						Error ->
							Error
					end;
				Error ->
					Error
			end;
		false ->
			delete_wallet_list_chunks(0, RootHash, 0)
	end.

delete_wallet_list_chunks(Position, RootHash, BytesRemoved) ->
	WalletListChunkFile = wallet_list_chunk_filepath(Position, RootHash),
	case filelib:is_file(WalletListChunkFile) of
		true ->
			case file:read_file_info(WalletListChunkFile) of
				{ok, FileInfo} ->
					case file:delete(WalletListChunkFile) of
						ok ->
							ar_meta_db:increase(used_space, -FileInfo#file_info.size),
							delete_wallet_list_chunks(
								Position + ?WALLET_LIST_CHUNK_SIZE,
								RootHash,
								BytesRemoved + FileInfo#file_info.size
							);
						Error ->
							Error
					end;
				Error ->
					Error
			end;
		false ->
			{ok, BytesRemoved}
	end.

%% @doc Delete the tx with the given hash from disk. Return {ok, BytesRemoved} if
%% the removal is successful or the file does not exist.
delete_tx(Hash) ->
	case lookup_tx_filename(Hash) of
		{_, Filename} ->
			case file:read_file_info(Filename) of
				{ok, FileInfo} ->
					case file:delete(Filename) of
						ok ->
							ar_meta_db:increase(used_space, -FileInfo#file_info.size),
							{ok, FileInfo#file_info.size};
						Error ->
							Error
					end;
				Error ->
					Error
			end;
		unavailable ->
			{ok, 0}
	end.

%% @doc Delete the block with the given hash from disk. Return {ok, BytesRemoved} if
%% the removal is successful or the file does not exist.
delete_block(H) ->
	case lookup_block_filename(H) of
		unavailable ->
			{ok, 0};
		Filename ->
			case file:read_file_info(Filename) of
				{ok, FileInfo} ->
					case file:delete(Filename) of
						ok ->
							ar_meta_db:increase(used_space, -FileInfo#file_info.size),
							{ok, FileInfo#file_info.size};
						Error ->
							Error
					end;
				Error ->
					Error
			end
	end.

write_tx(TXs) when is_list(TXs) ->
	lists:foldl(
		fun (TX, ok) ->
				write_tx(TX);
			(TX, {error, firewall_check}) ->
				write_tx(TX);
			(_TX, Acc) ->
				Acc
		end,
		ok,
		TXs
	);
write_tx(#tx{ format = Format } = TX) ->
	case write_tx_header(TX) of
		ok ->
			DataSize = byte_size(TX#tx.data),
			case DataSize > 0 of
				true ->
					case {DataSize == TX#tx.data_size, Format} of
						{false, 2} ->
							ar:err([{event, failed_to_store_tx_data}, {reason, size_mismatch}]);
						_ ->
							case TX#tx.data_root of
								<<>> ->
									write_tx_data(TX#tx.data);
								DataRoot ->
									write_tx_data(DataRoot, TX#tx.data)
							end
					end;
				false ->
					ok
			end;
		NotOk ->
			NotOk
	end.

write_tx_header(TX) ->
	%% Only store data that passes the firewall configured by the miner.
	case ar_firewall:scan_tx(TX) of
		accept ->
			write_tx_header_after_scan(TX);
		reject ->
			{error, firewall_check}
	end.

write_tx_header_after_scan(TX) ->
	TXJSON = ar_serialize:jsonify(ar_serialize:tx_to_json_struct(TX#tx{ data = <<>> })),
	ByteSize = byte_size(TXJSON),
	Filepath =
		case {TX#tx.format, byte_size(TX#tx.data) > 0} of
			{1, true} ->
				filepath([?TX_DIR, "migrated_v1", tx_filename(TX)]);
			_ ->
				tx_filepath(TX)
		end,
	case filelib:is_file(Filepath) of
		true ->
			ok;
		false ->
			case enough_space(ByteSize) of
				true ->
					case write_file_atomic(Filepath, TXJSON) of
						ok ->
							spawn(ar_meta_db, increase, [used_space, ByteSize]),
							ok;
						Error ->
							Error
					end;
				false ->
					ar:err([{event, not_enough_space_to_write_tx}]),
					{error, not_enough_space}
			end
	end.

write_tx_data(Data) ->
	write_tx_data(no_expected_data_root, Data).

write_tx_data(ExpectedDataRoot, Data) ->
	Chunks = ar_tx:chunk_binary(?DATA_CHUNK_SIZE, Data),
	SizeTaggedChunks = ar_tx:chunks_to_size_tagged_chunks(Chunks),
	SizeTaggedChunkIDs = ar_tx:sized_chunks_to_sized_chunk_ids(SizeTaggedChunks),
	case {ExpectedDataRoot, ar_merkle:generate_tree(SizeTaggedChunkIDs)} of
		{no_expected_data_root, {DataRoot, DataTree}} ->
			write_tx_data(DataRoot, DataTree, Data, SizeTaggedChunks);
		{_, {ExpectedDataRoot, DataTree}} ->
			write_tx_data(ExpectedDataRoot, DataTree, Data, SizeTaggedChunks);
		_ ->
			{error, invalid_data_root}
	end.

write_tx_data(ExpectedDataRoot, DataTree, Data, SizeTaggedChunks) ->
	lists:foreach(
		fun
			({<<>>, _}) ->
				%% Empty chunks are produced by ar_tx:chunk_binary/2, when
				%% the data is evenly split by the given chunk size. They are
				%% the last chunks of the corresponding transactions and have
				%% the same end offsets as their preceding chunks. They are never
				%% picked as recall chunks because recall byte has to be strictly
				%% smaller than the end offset. They are an artifact of the original
				%% chunking implementation. There is no value in storing them.
				ignore_empty_chunk;
			({Chunk, Offset}) ->
					DataPath =
						ar_merkle:generate_path(ExpectedDataRoot, Offset - 1, DataTree),
					Proof = #{
						data_root => ExpectedDataRoot,
						chunk => Chunk,
						offset => Offset - 1,
						data_path => DataPath,
						data_size => byte_size(Data)
					},
					ar_data_sync:add_chunk(Proof, infinity)
		end,
		SizeTaggedChunks
	).

%% @doc Read a tx from disk, given a hash.
read_tx(unavailable) -> unavailable;
read_tx(TX) when is_record(TX, tx) -> TX;
read_tx(TXs) when is_list(TXs) ->
	lists:map(fun read_tx/1, TXs);
read_tx(ID) ->
	case lookup_tx_filename(ID) of
		{ok, Filename} ->
			case read_tx_file(Filename) of
				{ok, TX} ->
					TX;
				_Error ->
					unavailable
			end;
		{migrated_v1, Filename} ->
			case read_migrated_v1_tx_file(Filename) of
				{ok, TX} ->
					TX;
				_Error ->
					unavailable
			end;
		unavailable ->
			unavailable
	end.

read_tx_file(Filename) ->
	case file:read_file(Filename) of
		{ok, <<>>} ->
			file:delete(Filename),
			ar:err([
				{event, empty_tx_file},
				{filename, Filename}
			]),
			{error, tx_file_empty};
		{ok, Binary} ->
			case catch ar_serialize:json_struct_to_tx(Binary) of
				TX when is_record(TX, tx) ->
					{ok, TX};
				_ ->
					file:delete(Filename),
					ar:err([
						{event, failed_to_parse_tx},
						{filename, Filename}
					]),
					{error, failed_to_parse_tx}
			end;
		Error ->
			Error
	end.

read_migrated_v1_tx_file(Filename) ->
	case file:read_file(Filename) of
		{ok, Binary} ->
			case catch ar_serialize:json_struct_to_v1_tx(Binary) of
				#tx{ id = ID } = TX ->
					case catch ar_data_sync:get_tx_data(ID) of
						{ok, Data} ->
							{ok, TX#tx{ data = Data }};
						{error, not_found} ->
							{error, data_unavailable};
						{'EXIT', {timeout, {gen_server, call, _}}} ->
							{error, data_fetch_timeout};
						Error ->
							Error
					end
			end;
		Error ->
			Error
	end.

read_tx_data(TX) ->
	case file:read_file(tx_data_filepath(TX)) of
		{ok, Data} ->
			{ok, ar_util:decode(Data)};
		Error ->
			Error
	end.

%% Write a block index to disk for retreival later (in emergencies).
write_block_index(BI) ->
	ar:info([{event, writing_block_index_to_disk}]),
	JSON = ar_serialize:jsonify(ar_serialize:block_index_to_json_struct(BI)),
	File = block_index_filepath(),
	case write_file_atomic(File, JSON) of
		ok ->
			ok;
		{error, Reason} = Error ->
			ar:err([{event, failed_to_write_block_index_to_disk}, {reason, Reason}]),
			Error
	end.

write_wallet_list(RootHash, Tree) ->
	write_wallet_list_chunks(RootHash, Tree, first, 0).

write_wallet_list_chunks(RootHash, Tree, Cursor, Position) ->
	case write_wallet_list_chunk(RootHash, Tree, Cursor, Position) of
		{ok, complete} ->
			ok;
		{ok, NextCursor, NextPosition} ->
			write_wallet_list_chunks(RootHash, Tree, NextCursor, NextPosition);
		{error, _Reason} = Error ->
			Error
	end.

write_wallet_list_chunk(RootHash, Tree, Cursor, Position) ->
	Range =
		case Cursor of
			first ->
				ar_patricia_tree:get_range(?WALLET_LIST_CHUNK_SIZE + 1, Tree);
			_ ->
				ar_patricia_tree:get_range(Cursor, ?WALLET_LIST_CHUNK_SIZE + 1, Tree)
		end,
	{NextCursor, NextPosition, Range2} =
		case length(Range) of
			?WALLET_LIST_CHUNK_SIZE + 1 ->
				{element(1, hd(Range)), Position + ?WALLET_LIST_CHUNK_SIZE, tl(Range)};
			_ ->
				{last, none, [last | Range]}
		end,
	Name = wallet_list_chunk_relative_filepath(Position, RootHash),
	case write_term(ar_meta_db:get(data_dir), Name, Range2, do_not_override) of
		ok ->
			case NextCursor of
				last ->
					{ok, complete};
				_ ->
					{ok, NextCursor, NextPosition}
			end;
		{error, Reason} = Error ->
			ar:err([
				{event, failed_to_write_wallet_list_chunk},
				{reason, Reason}
			]),
			Error
	end.

%% Write a block hash list to disk for retrieval later.
write_wallet_list(ID, RewardAddr, IsRewardAddrNew, WalletList) ->
	JSON = ar_serialize:jsonify(
		ar_serialize:wallet_list_to_json_struct(RewardAddr, IsRewardAddrNew, WalletList)
	),
	Filepath = wallet_list_filepath(ID),
	case filelib:is_file(Filepath) of
		true ->
			ok;
		false ->
			write_file_atomic(Filepath, JSON)
	end.

%% @doc Read a list of block hashes from the disk.
read_block_index() ->
	case file:read_file(block_index_filepath()) of
		{ok, Binary} ->
			case ar_serialize:json_struct_to_block_index(ar_serialize:dejsonify(Binary)) of
				[H | _] = HL when is_binary(H) ->
					[{BH, not_set, not_set} || BH <- HL];
				BI ->
					BI
			end;
		Error ->
			Error
	end.

%% @doc Read a given wallet list (by hash) from the disk.
read_wallet_list(WalletListHash) when is_binary(WalletListHash) ->
	case read_wallet_chunk(WalletListHash) of
		not_found ->
			Filename = wallet_list_filepath(WalletListHash),
			case file:read_file(Filename) of
				{ok, JSON} ->
					parse_wallet_list_json(JSON);
				{error, Reason} ->
					{error, {failed_reading_file, Filename, Reason}}
			end;
		{ok, Tree} ->
			{ok, Tree};
		{error, _Reason} = Error ->
			Error
	end;
read_wallet_list(WL) when is_list(WL) ->
	{ok, ar_patricia_tree:from_proplist([{A, {B, LTX}} || {A, B, LTX} <- WL])}.

read_wallet_chunk(RootHash) ->
	read_wallet_chunk(RootHash, 0, ar_patricia_tree:new()).

read_wallet_chunk(RootHash, Cursor, Tree) ->
	Name = binary_to_list(iolist_to_binary([
		?WALLET_LIST_DIR,
		"/",
		ar_util:encode(RootHash),
		"-",
		integer_to_binary(Cursor),
		"-",
		integer_to_binary(?WALLET_LIST_CHUNK_SIZE)
	])),
	case read_term(Name) of
		{ok, Chunk} ->
			{NextCursor, Wallets} =
				case Chunk of
					[last | Tail] ->
						{last, Tail};
					_ ->
						{Cursor + ?WALLET_LIST_CHUNK_SIZE, Chunk}
				end,
			Tree2 =
				lists:foldl(
					fun({K, V}, Acc) -> ar_patricia_tree:insert(K, V, Acc) end,
					Tree,
					Wallets
				),
			case NextCursor of
				last ->
					{ok, Tree2};
				_ ->
					read_wallet_chunk(RootHash, NextCursor, Tree2)
			end;
		{error, Reason} = Error ->
			ar:err([
				{event, failed_to_read_wallet_chunk},
				{reason, Reason}
			]),
			Error;
		not_found ->
			not_found
	end.

parse_wallet_list_json(JSON) ->
	case ar_serialize:json_decode(JSON) of
		{ok, JiffyStruct} ->
			{ok, ar_serialize:json_struct_to_wallet_list(JiffyStruct)};
		{error, Reason} ->
			{error, {invalid_json, Reason}}
	end.

lookup_tx_filename(ID) ->
	Filepath = tx_filepath(ID),
	case filelib:is_file(Filepath) of
		true ->
			{ok, Filepath};
		false ->
			MigratedV1Path = filepath([?TX_DIR, "migrated_v1", tx_filename(ID)]),
			case filelib:is_file(MigratedV1Path) of
				true ->
					{migrated_v1, MigratedV1Path};
				false ->
					unavailable
			end
	end.

% @doc Check that there is enough space to write Bytes bytes of data
enough_space(Bytes) ->
	(ar_meta_db:get(disk_space)) >= (Bytes + ar_meta_db:get(used_space)).

%% @doc Calculate the available space in bytes on the data directory disk.
calculate_disk_space() ->
	{_, KByteSize, _} = get_data_dir_disk_data(),
	KByteSize * 1024.

%% @doc Calculate the used space in bytes on the data directory disk.
calculate_used_space() ->
	{_, KByteSize, CapacityKByteSize} = get_data_dir_disk_data(),
	(KByteSize - CapacityKByteSize) * 1024.

get_data_dir_disk_data() ->
	DataDir = filename:absname(ar_meta_db:get(data_dir)),
	[DiskData | _] = select_drive(ar_disksup:get_disk_data(), DataDir),
	DiskData.

%% @doc Calculate the root drive in which the Arweave server resides
select_drive(Disks, []) ->
	CWD = "/",
	case
		Drives = lists:filter(
			fun({Name, _, _}) ->
				case Name == CWD of
					false -> false;
					true -> true
				end
			end,
			Disks
		)
	of
		[] -> false;
		Drives ->
			Drives
	end;
select_drive(Disks, CWD) ->
	try
		case
			Drives = lists:filter(
				fun({Name, _, _}) ->
					try
						case string:find(Name, CWD) of
							nomatch -> false;
							_ -> true
						end
					catch _:_ -> false
					end
				end,
				Disks
			)
		of
			[] -> select_drive(Disks, hd(string:split(CWD, "/", trailing)));
			Drives -> Drives
		end
	catch _:_ -> select_drive(Disks, [])
	end.

filepath(PathComponents) ->
	to_string(filename:join([ar_meta_db:get(data_dir) | PathComponents])).

to_string(Bin) when is_binary(Bin) ->
	binary_to_list(Bin);
to_string(String) ->
	String.

block_filename(B) when is_record(B, block) ->
	block_filename(B#block.indep_hash);
block_filename(BH) when is_binary(BH) ->
	iolist_to_binary([ar_util:encode(BH), ".json"]).

block_filepath(B) ->
	filepath([?BLOCK_DIR, block_filename(B)]).

invalid_block_filepath(B) ->
	filepath([?BLOCK_DIR, "invalid", block_filename(B)]).

tx_filepath(TX) ->
	filepath([?TX_DIR, tx_filename(TX)]).

tx_data_filepath(TX) when is_record(TX, tx) ->
	tx_data_filepath(TX#tx.id);
tx_data_filepath(ID) ->
	filepath([?TX_DIR, tx_data_filename(ID)]).

tx_filename(TX) when is_record(TX, tx) ->
	tx_filename(TX#tx.id);
tx_filename(TXID) when is_binary(TXID) ->
	iolist_to_binary([ar_util:encode(TXID), ".json"]).

tx_data_filename(TXID) ->
	iolist_to_binary([ar_util:encode(TXID), "_data.json"]).

block_index_filepath() ->
	filepath([?HASH_LIST_DIR, <<"last_block_index.json">>]).

wallet_list_filepath(Hash) when is_binary(Hash) ->
	filepath([?WALLET_LIST_DIR, iolist_to_binary([ar_util:encode(Hash), ".json"])]).

wallet_list_chunk_filepath(Position, RootHash) when is_binary(RootHash) ->
	filename:join(
		ar_meta_db:get(data_dir),
		wallet_list_chunk_relative_filepath(Position, RootHash)
	).

wallet_list_chunk_relative_filepath(Position, RootHash) ->
	binary_to_list(iolist_to_binary([
		?WALLET_LIST_DIR,
		"/",
		ar_util:encode(RootHash),
		"-",
		integer_to_binary(Position),
		"-",
		integer_to_binary(?WALLET_LIST_CHUNK_SIZE)
	])).

write_file_atomic(Filename, Data) ->
	SwapFilename = Filename ++ ".swp",
	case file:write_file(SwapFilename, Data) of
		ok ->
			file:rename(SwapFilename, Filename);
		Error ->
			Error
	end.

has_chunk(DataPathHash) ->
	DataDir = ar_meta_db:get(data_dir),
	ChunkDir = filename:join(DataDir, ?DATA_CHUNK_DIR),
	filelib:is_file(filename:join(ChunkDir, ar_util:encode(DataPathHash))).

write_chunk(DataPathHash, Chunk, DataPath) ->
	DataDir = ar_meta_db:get(data_dir),
	Data = term_to_binary({Chunk, DataPath}),
	ChunkDir = filename:join(DataDir, ?DATA_CHUNK_DIR),
	case filelib:ensure_dir(ChunkDir ++ "/") of
		{error, Reason} ->
			{error, Reason};
		ok ->
			write_file_atomic(
				filename:join(
					ChunkDir,
					binary_to_list(ar_util:encode(DataPathHash))
				),
				Data
			)
	end.

read_chunk(DataPathHash) ->
	DataDir = ar_meta_db:get(data_dir),
	ChunkDir = filename:join(DataDir, ?DATA_CHUNK_DIR),
	case file:read_file(filename:join(ChunkDir, ar_util:encode(DataPathHash))) of
		{error, enoent} ->
			not_found;
		{ok, Binary} ->
			{ok, binary_to_term(Binary)};
		Error ->
			Error
	end.

delete_chunk(DataPathHash) ->
	DataDir = ar_meta_db:get(data_dir),
	ChunkDir = filename:join(DataDir, ?DATA_CHUNK_DIR),
	file:delete(filename:join(ChunkDir, ar_util:encode(DataPathHash))).

write_term(Name, Term) ->
	write_term(ar_meta_db:get(data_dir), Name, Term, override).

write_term(Dir, Name, Term) when is_atom(Name) ->
	write_term(Dir, atom_to_list(Name), Term, override);
write_term(Dir, Name, Term) ->
	write_term(Dir, Name, Term, override).

write_term(Dir, Name, Term, Override) ->
	Filepath = filename:join(Dir, Name),
	case Override == do_not_override andalso filelib:is_file(Filepath) of
		true ->
			ok;
		false ->
			case write_file_atomic(Filepath, term_to_binary(Term)) of
				ok ->
					ok;
				{error, Reason} = Error ->
					ar:err([{event, failed_to_write_term}, {name, Name}, {reason, Reason}]),
					Error
			end
	end.

read_term(Name) ->
	DataDir = ar_meta_db:get(data_dir),
	read_term(DataDir, Name).

read_term(Dir, Name) when is_atom(Name) ->
	read_term(Dir, atom_to_list(Name));
read_term(Dir, Name) ->
	case file:read_file(filename:join(Dir, Name)) of
		{ok, Binary} ->
			{ok, binary_to_term(Binary)};
		{error, enoent} ->
			not_found;
		{error, Reason} = Error ->
			ar:err([{event, failed_to_read_term}, {name, Name}, {reason, Reason}]),
			Error
	end.

delete_term(Name) ->
	DataDir = ar_meta_db:get(data_dir),
	file:delete(filename:join(DataDir, atom_to_list(Name))).

%% @doc Test block storage.
store_and_retrieve_block_test() ->
	ar_storage:clear(),
	?assertEqual(0, blocks_on_disk()),
	BI0 = [B0] = ar_weave:init([]),
	{Node, _} = ar_test_node:start(B0),
	?assertEqual(
        B0#block{
            hash_list = unset,
            size_tagged_txs = unset
        }, read_block(B0#block.indep_hash)),
	?assertEqual(
		B0#block{ hash_list = unset, size_tagged_txs = unset },
		read_block(B0#block.height, ar_weave:generate_block_index(BI0))
	),
	ar_node:mine(Node),
	ar_test_node:wait_until_height(Node, 1),
	ar_node:mine(Node),
	BI1 = ar_test_node:wait_until_height(Node, 2),
	ar_util:do_until(
		fun() ->
			3 == blocks_on_disk()
		end,
		100,
		2000
	),
	BH1 = element(1, hd(BI1)),
	?assertMatch(#block{ height = 2, indep_hash = BH1 }, read_block(BH1)),
	?assertMatch(#block{ height = 2, indep_hash = BH1 }, read_block(2, BI1)).

%% @doc Ensure blocks can be written to disk, then moved into the 'invalid'
%% block directory.
invalidate_block_test() ->
	[B] = ar_weave:init(),
	write_full_block(B),
	invalidate_block(B),
	unavailable = read_block(B#block.indep_hash, ar_weave:generate_block_index([B])),
	TargetFile = filename:join([
		ar_meta_db:get(data_dir),
		?BLOCK_DIR,
		"invalid",
		binary_to_list(ar_util:encode(B#block.indep_hash)) ++ ".json"
	]),
	{ok, Binary} = file:read_file(TargetFile),
	{ok, JSON} = ar_serialize:json_decode(Binary),
	?assertEqual(B#block.indep_hash, (ar_serialize:json_struct_to_block(JSON))#block.indep_hash).

store_and_retrieve_block_block_index_test() ->
	RandomEntry =
		fun() ->
			{crypto:strong_rand_bytes(32), rand:uniform(10000), crypto:strong_rand_bytes(32)}
		end,
	BI = [RandomEntry() || _ <- lists:seq(1, 100)],
	write_block_index(BI),
	ReadBI = read_block_index(),
	?assertEqual(BI, ReadBI).

store_and_retrieve_wallet_list_test() ->
	[B0] = ar_weave:init(),
	write_block(B0),
	Height = B0#block.height,
	RewardAddr = B0#block.reward_addr,
	ExpectedWL =
		ar_patricia_tree:from_proplist([{A, {B, T}} || {A, B, T} <- ar_util:genesis_wallets()]),
	{WalletListHash, _} = ar_block:hash_wallet_list(Height, RewardAddr, ExpectedWL),
	{ok, ActualWL} = read_wallet_list(WalletListHash),
	assert_wallet_trees_equal(ExpectedWL, ActualWL).

assert_wallet_trees_equal(Expected, Actual) ->
	?assertEqual(
		ar_patricia_tree:foldr(fun(K, V, Acc) -> [{K, V} | Acc] end, [], Expected),
		ar_patricia_tree:foldr(fun(K, V, Acc) -> [{K, V} | Acc] end, [], Actual)
	).

read_wallet_list_chunks_test() ->
	TestCases = [
		[],
		[random_wallet()], % < chunk size
		[random_wallet() || _ <- lists:seq(1, ?WALLET_LIST_CHUNK_SIZE)], % == chunk size
		[random_wallet() || _ <- lists:seq(1, ?WALLET_LIST_CHUNK_SIZE + 1)], % > chunk size
		[random_wallet() || _ <- lists:seq(1, 10 * ?WALLET_LIST_CHUNK_SIZE)],
		[random_wallet() || _ <- lists:seq(1, 10 * ?WALLET_LIST_CHUNK_SIZE + 1)]
	],
	lists:foreach(
		fun(TestCase) ->
			Tree = ar_patricia_tree:from_proplist(TestCase),
			{RootHash, _} = ar_block:hash_wallet_list(ar_fork:height_2_2(), unclaimed, Tree),
			%% Chunked write.
			ok = write_wallet_list(RootHash, Tree),
			{ok, ReadTree} = read_wallet_list(RootHash),
			assert_wallet_trees_equal(Tree, ReadTree),
			?assertEqual(true, filelib:is_file(wallet_list_chunk_filepath(0, RootHash))),
			?assertMatch({ok, _}, delete_wallet_list(RootHash)),
			?assertEqual({ok, 0}, delete_wallet_list(RootHash)),
			?assertMatch({error, {failed_reading_file, _, enoent}}, read_wallet_list(RootHash)),
			?assertEqual(false, filelib:is_file(wallet_list_chunk_filepath(0, RootHash))),
			%% Not chunked write - wallets before the fork 2.2.
			ok = write_wallet_list(RootHash, unclaimed, false, Tree),
			?assertEqual(false, filelib:is_file(wallet_list_chunk_filepath(0, RootHash))),
			?assertEqual(true, filelib:is_file(wallet_list_filepath(RootHash))),
			{ok, ReadTree2} = read_wallet_list(RootHash),
			assert_wallet_trees_equal(Tree, ReadTree2),
			?assertMatch({ok, _}, delete_wallet_list(RootHash)),
			?assertEqual({ok, 0}, delete_wallet_list(RootHash)),
			?assertEqual(false, filelib:is_file(wallet_list_filepath(RootHash))),
			?assertMatch({error, {failed_reading_file, _, enoent}}, read_wallet_list(RootHash))
		end,
		TestCases
	).

random_wallet() ->
	{crypto:strong_rand_bytes(32), {rand:uniform(1000000000), crypto:strong_rand_bytes(32)}}.

handle_corrupted_wallet_list_test() ->
	H = crypto:strong_rand_bytes(32),
	ok = file:write_file(wallet_list_filepath(H), <<>>),
	?assertMatch({error, _}, read_wallet_list(H)).
