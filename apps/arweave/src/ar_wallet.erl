%%% @doc Utilities for manipulating wallets.
-module(ar_wallet).

-export([
	new/0,
	sign/2,
	verify/3, verify_pre_fork_2_4/3,
	to_address/1,
	load_keyfile/1,
	new_keyfile/0, new_keyfile/1,
	wallet_filepath/1
]).

-include_lib("arweave/include/ar.hrl").
-include_lib("arweave/include/ar_config.hrl").

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

%% @doc Generate a new wallet public key and private key.
new() -> new(?DEFAULT_KEY_TYPE).
new(KeyType = {KeyAlg, PublicExpnt}) when KeyType =:= ?DEFAULT_KEY_TYPE ->
    {[_, Pub], [_, Pub, Priv|_]} = {[_, Pub], [_, Pub, Priv|_]}
		= crypto:generate_key(KeyAlg, {?RSA_PRIV_KEY_SZ, PublicExpnt}),
    {{KeyType, Priv, Pub}, {KeyType, Pub}};
new(KeyType = {KeyAlg, KeyCrv}) when KeyAlg =:= ?ECDSA_SIGN_ALG andalso KeyCrv =:= secp256k1 ->
    {Pub, Priv} = crypto:generate_key(ecdh, KeyCrv),
    {{KeyType, Priv, Pub}, {KeyType, Pub}};
new(KeyType = {KeyAlg, KeyCrv}) when KeyAlg =:= ?EDDSA_SIGN_ALG andalso KeyCrv =:= ed25519 ->
    {Pub, Priv} = crypto:generate_key(KeyAlg, KeyCrv),
    {{KeyType, Priv, Pub}, {KeyType, Pub}}.

%% @doc Generate a new wallet public and private key, with a corresponding keyfile.
new_keyfile() ->
    new_keyfile(?DEFAULT_KEY_TYPE, wallet_address).
new_keyfile(WalletName) ->
    new_keyfile(?DEFAULT_KEY_TYPE, WalletName).

%% @doc Generate a new wallet public and private key, with a corresponding keyfile.
%% The provided key is used as part of the file name.
%% @end
new_keyfile(KeyType, WalletName) ->
    case KeyType of
		{?RSA_SIGN_ALG, PublicExpnt} ->
			{[Expnt, Pub], [Expnt, Pub, Priv, P1, P2, E1, E2, C]} =
				crypto:generate_key(rsa, {?RSA_PRIV_KEY_SZ, PublicExpnt}),
			Key =
				ar_serialize:jsonify(
					{
						[
							{kty, <<"RSA">>},
							{ext, true},
							{e, ar_util:encode(Expnt)},
							{n, ar_util:encode(Pub)},
							{d, ar_util:encode(Priv)},
							{p, ar_util:encode(P1)},
							{q, ar_util:encode(P2)},
							{dp, ar_util:encode(E1)},
							{dq, ar_util:encode(E2)},
							{qi, ar_util:encode(C)}
						]
					}
				);
		{?ECDSA_SIGN_ALG, secp256k1} ->
			{{_, Priv, Pub}, _} = new(KeyType),
			<<_:8, PubPoint/binary>> = Pub,
			PubPointMid = byte_size(PubPoint) div 2,
			<<X:PubPointMid/binary, Y:PubPointMid/binary>> = PubPoint,
			Key =
				ar_serialize:jsonify(
					{
						[
							{kty, <<"EC">>},
							{crv, <<"secp256k1">>},
							{x, ar_util:encode(X)},
							{y, ar_util:encode(Y)},
							{d, ar_util:encode(Priv)}
						]
					}
				);
		{?EDDSA_SIGN_ALG, ed25519} ->
			{{_, Priv, Pub}, _} = new(KeyType),
			Key =
				ar_serialize:jsonify(
					{
						[
							{kty, <<"OKP">>},
							{alg, <<"EdDSA">>},
							{crv, <<"Ed25519">>},
							{x, ar_util:encode(Pub)},
							{d, ar_util:encode(Priv)}
						]
					}
				)
	end,
	Filename = wallet_filepath(WalletName, Pub),
	filelib:ensure_dir(Filename),
	ar_storage:write_file_atomic(Filename, Key),
	{{KeyType, Priv, Pub}, {KeyType, Pub}}.

wallet_filepath(WalletName, PubKey) ->
	wallet_filepath(wallet_name(WalletName, PubKey)).

wallet_filepath(Wallet) ->
	{ok, Config} = application:get_env(arweave, config),
	Filename = lists:flatten(["arweave_keyfile_", binary_to_list(Wallet), ".json"]),
	filename:join([Config#config.data_dir, ?WALLET_DIR, Filename]).

wallet_name(wallet_address, PubKey) ->
	ar_util:encode(to_address(PubKey));
wallet_name(WalletName, _) ->
	WalletName.

%% @doc Extract the public and private key from a keyfile.
load_keyfile(File) ->
	{ok, Body} = file:read_file(File),
	{Key} = ar_serialize:dejsonify(Body),
	case lists:keyfind(<<"kty">>, 1, Key) of
		{<<"kty">>, <<"EC">>} ->
			{<<"x">>, XEncoded} = lists:keyfind(<<"x">>, 1, Key),
			{<<"y">>, YEncoded} = lists:keyfind(<<"y">>, 1, Key),
			{<<"d">>, PrivEncoded} = lists:keyfind(<<"d">>, 1, Key),
			Pub = iolist_to_binary([<<4:8>>, ar_util:decode(XEncoded), ar_util:decode(YEncoded)]),
			Priv = ar_util:decode(PrivEncoded),
			KeyType = {?ECDSA_SIGN_ALG, secp256k1};
		{<<"kty">>, <<"OKP">>} ->
			{<<"x">>, PubEncoded} = lists:keyfind(<<"x">>, 1, Key),
			{<<"d">>, PrivEncoded} = lists:keyfind(<<"d">>, 1, Key),
			Pub = ar_util:decode(PubEncoded),
			Priv = ar_util:decode(PrivEncoded),
			KeyType = {?EDDSA_SIGN_ALG, ed25519};
		_ ->
			{<<"n">>, PubEncoded} = lists:keyfind(<<"n">>, 1, Key),
			Pub = ar_util:decode(PubEncoded),
			{<<"d">>, PrivEncoded} = lists:keyfind(<<"d">>, 1, Key),
			Priv = ar_util:decode(PrivEncoded),
			KeyType = ?DEFAULT_KEY_TYPE
	end,
	{{KeyType, Priv, Pub}, {KeyType, Pub}}.

%% @doc Sign some data with a private key.
sign({{KeyAlg, PublicExpnt}, Priv, Pub}, Data) when KeyAlg =:= ?RSA_SIGN_ALG ->
	rsa_pss:sign(
		Data,
		sha256,
		#'RSAPrivateKey'{
			publicExponent = PublicExpnt,
			modulus = binary:decode_unsigned(Pub),
			privateExponent = binary:decode_unsigned(Priv)
		}
	);
sign({{KeyAlg, KeyCrv}, Priv, _}, Data) when KeyAlg =:= ?ECDSA_SIGN_ALG andalso KeyCrv =:= secp256k1 ->
	crypto:sign(
		KeyAlg,
		sha256,
		Data,
		[Priv, KeyCrv]
	);
sign({{KeyAlg, KeyCrv}, Priv, _}, Data) when KeyAlg =:= ?EDDSA_SIGN_ALG andalso KeyCrv =:= ed25519 ->
	crypto:sign(
		KeyAlg,
		sha512,
		Data,
		[Priv, KeyCrv]
	).

%% @doc Verify that a signature is correct.
verify({KeyType = {?RSA_SIGN_ALG, PublicExpnt}, Pub}, Data, Sig) when KeyType =:= ?DEFAULT_KEY_TYPE ->
	rsa_pss:verify(
		Data,
		sha256,
		Sig,
		#'RSAPublicKey'{
			publicExponent = PublicExpnt,
			modulus = binary:decode_unsigned(Pub)
		}
	);
verify({{KeyAlg, KeyCrv}, Pub}, Data, Sig) when KeyAlg =:= ?ECDSA_SIGN_ALG andalso KeyCrv =:= secp256k1 ->
	crypto:verify(
		KeyAlg,
		sha256,
		Data,
		Sig,
		[Pub, KeyCrv]
	);
verify({{KeyAlg, KeyCrv}, Pub}, Data, Sig) when KeyAlg =:= ?EDDSA_SIGN_ALG andalso KeyCrv =:= ed25519 ->
	crypto:verify(
		KeyAlg,
		sha512,
		Data,
		Sig,
		[Pub, KeyCrv]
	).

%% @doc Verify that a signature is correct. The function was used to verify
%% transactions until the fork 2.4. It rejects a valid transaction when the
%% key modulus bit size is less than 4096. The new method (verify/3) successfully
%% verifies all the historical transactions so this function is not used anywhere
%% after the fork 2.4.
%% @end
verify_pre_fork_2_4({KeyType = {?RSA_SIGN_ALG, PublicExpnt}, Pub}, Data, Sig) when KeyType =:= ?DEFAULT_KEY_TYPE ->
	rsa_pss:verify_legacy(
		Data,
		sha256,
		Sig,
		#'RSAPublicKey'{
			publicExponent = PublicExpnt,
			modulus = binary:decode_unsigned(Pub)
		}
	).

%% @doc Generate an address from a public key.
to_address(Addr) when ?IS_ADDR(Addr) -> Addr;
to_address({{_, _, Pub}, {_, Pub}}) -> to_address(Pub);
to_address({_, _, Pub}) -> to_address(Pub);
to_address({_, Pub}) -> to_address(Pub);
to_address(PubKey) ->
	crypto:hash(?HASH_ALG, PubKey).

%%%===================================================================
%%% Tests.
%%%===================================================================

rsa_wallet_sign_verify_test() ->
	test_wallet_sign_verify(?DEFAULT_KEY_TYPE).

ecdsa_wallet_sign_verify_test() ->
	test_wallet_sign_verify({?ECDSA_SIGN_ALG, secp256k1}).

test_wallet_sign_verify(KeyType) ->
	TestData = <<"TEST DATA">>,
	{Priv, Pub} = new(KeyType),
	Signature = sign(Priv, TestData),
	true = verify(Pub, TestData, Signature).

invalid_rsa_signature_test() ->
	test_invalid_signature(?DEFAULT_KEY_TYPE).

invalid_ecdsa_signature_test() ->
	test_invalid_signature({?ECDSA_SIGN_ALG, secp256k1}).

test_invalid_signature(KeyType) ->
	TestData = <<"TEST DATA">>,
	{Priv, Pub} = new(KeyType),
	<< _:32, Signature/binary >> = sign(Priv, TestData),
	false = verify(Pub, TestData, << 0:32, Signature/binary >>).

%% @doc Ensure that to_address'ing twice does not result in double hashing.
address_double_encode_test() ->
	{_, Pub} = new(),
	Addr = to_address(Pub),
	Addr = to_address(Addr).

%% @doc Check generated keyfiles can be retrieved.
generate_rsa_keyfile_test() ->
	test_generate_keyfile(?DEFAULT_KEY_TYPE).

generate_ecdsa_keyfile_test() ->
	test_generate_keyfile({?ECDSA_SIGN_ALG, secp256k1}).

test_generate_keyfile(KeyType) ->
	{Priv, Pub} = new_keyfile(KeyType, wallet_address),
	FileName = wallet_filepath(ar_util:encode(to_address(Pub))),
	{Priv, Pub} = load_keyfile(FileName).
