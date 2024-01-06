from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.bool import TRUE, FALSE

// Structures:
// - assets: [token1, token2, ...]
// - observers : [observer1, observer2, ...]
// - leverage_bounds_per_asset: [token1, value11, value12, token2, value21, value22 ...]
// - everything else: [token1, value1, token2, value2, ...]

struct GlobalDexState {
    tx_batch_id: felt,  // why do we need this? (rename)
    init_state_root: felt,
    final_state_root: felt,
    state_tree_depth: felt,
    global_expiration_timestamp: felt,
    n_deposits: felt,
    n_withdrawals: felt,
    n_output_notes: felt,
    n_output_positions: felt,
    n_output_tabs: felt,
    n_zero_indexes: felt,
    n_onchain_mm_actions: felt,
    n_note_escapes: felt,
    n_position_escapes: felt,
    n_tab_escapes: felt,
}

struct GlobalConfig {
    dex_state: GlobalDexState,
    assets_len: felt,
    assets: felt*,
    synthetic_assets_len: felt,
    synthetic_assets: felt*,
    collateral_token: felt,
    //
    chain_ids_len: felt,
    chain_ids: felt*,
    leverage_decimals: felt,
    //
    decimals_per_asset: felt*,
    dust_amount_per_asset: felt*,
    //
    price_decimals_per_asset: felt*,
    leverage_bounds_per_asset: felt*,
    min_partial_liquidation_size: felt*,
    //
    observers_len: felt,
    observers: felt*,
}

func get_array_index_for_token{range_check_ptr, global_config: GlobalConfig*}(
    token: felt, is_synthetic: felt
) -> (idx: felt) {
    alloc_locals;

    if (is_synthetic == TRUE) {
        local idx: felt;
        %{
            for i in range(ids.global_config.synthetic_assets_len):
                token_ = memory[ids.global_config.synthetic_assets + i]
                if token_ == ids.token:
                    ids.idx = i
                    break
        %}

        assert global_config.synthetic_assets[idx] = token;

        return (idx,);
    } else {
        local idx: felt;
        %{
            for i in range(ids.global_config.assets_len):
                token_ = memory[ids.global_config.assets + i]
                if token_ == ids.token:
                    ids.idx = i
                    break
        %}

        assert global_config.assets[idx] = token;

        return (idx,);
    }
}

// ? Verify the token is valid
func verify_valid_token{range_check_ptr, global_config: GlobalConfig*}(
    token: felt, is_synthetic: felt
) {
    // ? If token doesent exist this function will throw an error
    let (token_idx) = get_array_index_for_token(token, is_synthetic);

    return ();
}

// ? Get token decimals
func token_decimals{range_check_ptr, global_config: GlobalConfig*}(token: felt) -> (res: felt) {
    let (token_idx) = get_array_index_for_token(token, FALSE);

    let decimals_per_asset = global_config.decimals_per_asset;

    let decimals = decimals_per_asset[token_idx];

    return (decimals,);
}

// ? Get dust amount for a token
func get_dust_amount{range_check_ptr, global_config: GlobalConfig*}(token: felt) -> (res: felt) {
    let (token_idx) = get_array_index_for_token(token, FALSE);

    let dust_amount_per_asset = global_config.dust_amount_per_asset;
    let dust_amount = dust_amount_per_asset[token_idx];

    return (dust_amount,);
}

// ? Get token price decimals
func price_decimals{range_check_ptr, global_config: GlobalConfig*}(token: felt) -> (res: felt) {
    let (token_idx) = get_array_index_for_token(token, TRUE);

    let price_decimals_per_asset = global_config.price_decimals_per_asset;

    let decimals = price_decimals_per_asset[token_idx];

    return (decimals,);
}

// ? Get min partial liquidation size for a token
func get_min_partial_liquidation_size{range_check_ptr, global_config: GlobalConfig*}(
    token: felt
) -> (res: felt) {
    let (token_idx) = get_array_index_for_token(token, TRUE);

    let min_partial_liquidation_size = global_config.min_partial_liquidation_size;
    let size = min_partial_liquidation_size[token_idx];

    return (size,);
}

// TODO Get max leverage
func get_max_leverage{range_check_ptr, global_config: GlobalConfig*}(token: felt, amount: felt) -> (
    res: felt
) {
    // TODO:
}

// * ------- ---------- ------------- ------------- -------------- -------------- --------------

// ? Verify the chain id exists
func verify_valid_chain_id{range_check_ptr, global_config: GlobalConfig*}(chain_id: felt) {
    let is_valid = _verify_valid_chain_id_inner(
        global_config.chain_ids_len, global_config.chain_ids, chain_id
    );

    assert is_valid = 1;

    return ();
}

func _verify_valid_chain_id_inner{range_check_ptr}(
    chain_ids_len: felt, chain_ids: felt*, chain_id: felt
) -> felt {
    if (chain_ids_len == 0) {
        return 0;
    }

    if (chain_id == chain_ids[0]) {
        return 1;
    }

    return _verify_valid_chain_id_inner(chain_ids_len - 1, &chain_ids[1], chain_id);
}

// ? get the observer pub key from the observer index
func get_observer_by_index{range_check_ptr, global_config: GlobalConfig*}(observer_idx: felt) -> (
    res: felt
) {
    return (global_config.observers[observer_idx],);
}

// * ==============================================================

func init_global_config(global_config_ptr: GlobalConfig*) {
    %{
        # // * DEX STATE FIEELDS
        dex_state = program_input["global_dex_state"]
        program_input_counts = dex_state["program_input_counts"]
        dex_state_addr = ids.global_config_ptr.address_ + ids.GlobalConfig.dex_state
        memory[dex_state_addr + ids.GlobalDexState.tx_batch_id] = int(dex_state["tx_batch_id"])
        memory[dex_state_addr + ids.GlobalDexState.init_state_root] = int(dex_state["init_state_root"])
        memory[dex_state_addr + ids.GlobalDexState.final_state_root] = int(dex_state["final_state_root"])
        memory[dex_state_addr + ids.GlobalDexState.state_tree_depth] = dex_state["state_tree_depth"]
        memory[dex_state_addr + ids.GlobalDexState.global_expiration_timestamp] = dex_state["global_expiration_timestamp"]
        memory[dex_state_addr + ids.GlobalDexState.n_deposits] = program_input_counts["n_deposits"]
        memory[dex_state_addr + ids.GlobalDexState.n_withdrawals] = program_input_counts["n_withdrawals"]
        memory[dex_state_addr + ids.GlobalDexState.n_output_notes] = program_input_counts["n_output_notes"]
        memory[dex_state_addr + ids.GlobalDexState.n_output_positions] = program_input_counts["n_output_positions"]
        memory[dex_state_addr + ids.GlobalDexState.n_output_tabs] = program_input_counts["n_output_tabs"]
        memory[dex_state_addr + ids.GlobalDexState.n_zero_indexes] = program_input_counts["n_zero_indexes"]
        memory[dex_state_addr + ids.GlobalDexState.n_onchain_mm_actions] = program_input_counts["n_onchain_mm_actions"]
        memory[dex_state_addr + ids.GlobalDexState.n_note_escapes] = program_input_counts["n_note_escapes"]
        memory[dex_state_addr + ids.GlobalDexState.n_position_escapes] = program_input_counts["n_position_escapes"]
        memory[dex_state_addr + ids.GlobalDexState.n_tab_escapes] = program_input_counts["n_tab_escapes"]


        # // * GLOBAL CONFIG FIELDS
        global_config = program_input["global_config"]

        memory[ids.global_config_ptr.address_ + LEVERAGE_DECIMALS_OFFSET] = global_config["leverage_decimals"]
        memory[ids.global_config_ptr.address_ + COLLATERAL_TOKEN_OFFSET] = global_config["collateral_token"]
        # //? Assets ----- ----- ----- ----- ----- ------ ------ ------ ----- ------ ------
        assets = global_config["assets"]
        memory[ids.global_config_ptr.address_ + ASSETS_LEN_OFFSET] = len(assets)
        memory[ids.global_config_ptr.address_ + ASSETS_OFFSET] = assets_ = segments.add()
        for i in range(len(assets)):
            memory[assets_ + i] = int(assets[i])
        # //? Synthetic Assets ----- ----- ----- ----- ----- ------ ------ ------ ----- ------ ------
        synthetic_assets = global_config["synthetic_assets"]
        memory[ids.global_config_ptr.address_ + SYNTHETIC_ASSETS_LEN_OFFSET] = len(synthetic_assets)
        memory[ids.global_config_ptr.address_ + SYNTHETIC_ASSETS_OFFSET] = synthetic_assets_ = segments.add()
        for i in range(len(synthetic_assets)):
            memory[synthetic_assets_ + i] = int(synthetic_assets[i])
         # //? Chain IDs ----- ----- ----- ----- ----- ------ ------ ------ ----- ------ ------
        chain_ids = global_config["chain_ids"]
        memory[ids.global_config_ptr.address_ + CHAIN_IDS_LEN_OFFSET] = len(chain_ids)
        memory[ids.global_config_ptr.address_ + CHAIN_IDS_OFFSET] = chain_ids_ = segments.add()
        for i in range(len(chain_ids)):
            memory[chain_ids_ + i] = int(chain_ids[i])
        # //? Decimals per asset ----- ----- ----- ----- ----- ------ ------ ------ ----- ------ ------
        decimals_per_asset = global_config["decimals_per_asset"]
        memory[ids.global_config_ptr.address_ + DECIMALS_PER_ASSET_OFFSET] = decimals1 = segments.add()
        for i in range(0, len(decimals_per_asset)):
            memory[decimals1 + i] = int(decimals_per_asset[i])
        # //? Price decimals per asset ----- ----- ----- ----- ----- ------ ------ ------ ----- ------ ------
        price_decimals_per_asset = global_config["price_decimals_per_asset"]
        memory[ids.global_config_ptr.address_ + PRICE_DECIMALS_PER_ASSET_OFFSET] = decimals2 = segments.add()
        for i in range(0, len(price_decimals_per_asset)):
            memory[decimals2 + i] = int(price_decimals_per_asset[i])
        # //?  Leverage bounds per asset ----- ----- ----- ----- ----- ------ ------ ------ ----- ------ ------
        leverage_bounds_per_asset = global_config["leverage_bounds_per_asset"]
        memory[ids.global_config_ptr.address_ + LEVERAGE_BOUNDS_PER_ASSET_OFFSET] = lev_bounds_ = segments.add()
        for i in range(0, len(leverage_bounds_per_asset), 2):
            memory[lev_bounds_ +  i] = int(leverage_bounds_per_asset[i] * 100000)
            memory[lev_bounds_ + i + 1] = int(leverage_bounds_per_asset[i+1] * 100000)
        # //? Dust amount per asset ----- ----- ----- ----- ----- ------ ------ ------ ----- ------ ------
        dust_amount_per_asset = global_config["dust_amount_per_asset"]
        memory[ids.global_config_ptr.address_ + DUST_AMOUNT_PER_ASSET_OFFSET] = amounts_ = segments.add()
        for i in range(0, len(dust_amount_per_asset)):
            memory[amounts_ + i] = int(dust_amount_per_asset[i])
        # //? observers ----- ----- ----- ----- ----- ------ ------ ------ ----- ------ ------
        observers = global_config["observers"]
        memory[ids.global_config_ptr.address_ + OBSERVERS_LEN_OFFSET] = len(observers)
        memory[ids.global_config_ptr.address_ + OBSERVERS_OFFSET] = observers_ = segments.add()
        for i in range(len(observers)):
            memory[observers_ + i] = int(observers[i])
        # //? min partial liquidation size ----- ----- ----- ----- ----- ------ ------ ------ ----- ------ ------ 
        min_partial_liquidation_sizes = global_config["min_partial_liquidation_sizes"]
        memory[ids.global_config_ptr.address_ + MIN_PARTIAL_LIQUIDATION_SIZE_OFFSET] = min_pl_size = segments.add()
        for i in range(0, len(min_partial_liquidation_sizes)):
            memory[min_pl_size + i] = int(min_partial_liquidation_sizes[i])
    %}

    return ();
}

// * ===============================================================

// & depth_and_exipration_time: | state_tree_depth (8 bits) | global_expiration_timestamp (32 bits) |
// & output_counts1: | n_output_notes (32 bits) | n_output_positions (16 bits) | n_output_tabs (16 bits) | n_zero_indexes (32 bits) |
// &                 n_deposits (16 bits) | n_withdrawals (16 bits) | n_mm_registrations (16 bits) | n_mm_add_liquidity (16 bits) |
// &                 n_mm_remove_liquidity (16 bits) | n_note_escapes (16 bits) | n_position_escapes (16 bits) | n_tab_escapes (16 bits) |

func init_output_structs{poseidon_ptr: PoseidonBuiltin*}(
    config_output_ptr: felt*, global_config: GlobalConfig*
) -> (config_output_ptr: felt*) {
    let dex_state: GlobalDexState = global_config.dex_state;

    assert config_output_ptr[0] = dex_state.init_state_root;
    assert config_output_ptr[1] = dex_state.final_state_root;

    // & 1: | state_tree_depth (8 bits) | global_expiration_timestamp (32 bits) | tx_batch_id (32 bits) |
    let batched_info = (
        (dex_state.state_tree_depth * 2 ** 32) + dex_state.global_expiration_timestamp
    ) * 2 ** 32 + dex_state.tx_batch_id;
    assert config_output_ptr[2] = batched_info;

    // & 2:
    // & n_output_notes (32 bits) | n_output_positions (16 bits) | n_output_tabs (16 bits) | n_zero_indexes (32 bits) | n_deposits (16 bits) | n_withdrawals (16 bits) |
    // & n_onchain_mm_actions (16 bits) | n_note_escapes (16 bits) | n_tab_escapes (16 bits) | n_position_escapes (16 bits) |
    let o1 = (
        ((dex_state.n_output_notes * 2 ** 16) + dex_state.n_output_positions) * 2 ** 16 +
        dex_state.n_output_tabs
    ) * 2 ** 32 + dex_state.n_zero_indexes;
    let o2 = (((o1 * 2 ** 16) + dex_state.n_deposits) * 2 ** 16 + dex_state.n_withdrawals) * 2 **
        16 + dex_state.n_onchain_mm_actions;
    let batched_info = (
        ((o2 * 2 ** 16) + dex_state.n_note_escapes) * 2 ** 16 + dex_state.n_tab_escapes
    ) * 2 ** 16 + dex_state.n_position_escapes;

    assert config_output_ptr[3] = batched_info;

    // * Global Config =========================================================================

    // & 3: | collateral_token (32 bits) | leverage_decimals (8 bits) | assets_len (32 bits) | synthetic_assets_len (32 bits) | observers_len (32 bits) | chain_ids_len (32 bits) |
    let batched_info = (
        (
            (
                (global_config.collateral_token * 2 ** 8 + global_config.leverage_decimals) * 2 **
                32 +
                global_config.assets_len
            ) * 2 ** 32 +
            global_config.synthetic_assets_len
        ) * 2 ** 32 +
        global_config.observers_len
    ) * 2 ** 32 + global_config.chain_ids_len;
    assert config_output_ptr[4] = batched_info;

    // ? assets
    let (config_output_ptr: felt*) = output_arr(
        global_config.assets_len, global_config.assets, config_output_ptr + 5
    );
    // ? synthetic assets
    let (config_output_ptr: felt*) = output_arr(
        global_config.synthetic_assets_len, global_config.synthetic_assets, config_output_ptr
    );
    //
    // ? decimals_per_asset
    let (config_output_ptr: felt*) = output_arr(
        global_config.assets_len, global_config.decimals_per_asset, config_output_ptr
    );
    // ? dust_amount_per_asset
    let (config_output_ptr: felt*) = output_arr(
        global_config.assets_len, global_config.dust_amount_per_asset, config_output_ptr
    );
    //
    // ? price_decimals_per_asset
    let (config_output_ptr: felt*) = output_arr(
        global_config.synthetic_assets_len,
        global_config.price_decimals_per_asset,
        config_output_ptr,
    );
    // ? min_partial_liquidation_size
    let (config_output_ptr: felt*) = output_arr(
        global_config.synthetic_assets_len,
        global_config.min_partial_liquidation_size,
        config_output_ptr,
    );
    // ? leverage_bounds_per_asset
    let (config_output_ptr: felt*) = output_arr(
        2 * global_config.synthetic_assets_len,
        global_config.leverage_bounds_per_asset,
        config_output_ptr,
    );
    //
    // ? Chain IDs
    let (config_output_ptr: felt*) = output_arr(
        global_config.chain_ids_len, global_config.chain_ids, config_output_ptr
    );
    // ? observers
    let (config_output_ptr: felt*) = output_arr(
        global_config.observers_len, global_config.observers, config_output_ptr
    );

    return (config_output_ptr,);
}

func output_batched_arr(arr_len: felt, arr: felt*, config_output_ptr: felt*) -> (
    config_output_ptr: felt*
) {
    if (arr_len == 0) {
        return (config_output_ptr,);
    }

    if (arr_len == 1) {
        assert config_output_ptr[0] = arr[0];
        let config_output_ptr = config_output_ptr + 1;

        return (config_output_ptr,);
    }
    if (arr_len == 2) {
        let batched_info = (arr[0] * 2 ** 64) + arr[1];

        assert config_output_ptr[0] = batched_info;
        let config_output_ptr = config_output_ptr + 1;

        return (config_output_ptr,);
    } else {
        let batched_info = ((arr[0] * 2 ** 64) + arr[1]) * 2 ** 64 + arr[2];

        assert config_output_ptr[0] = batched_info;
        let config_output_ptr = config_output_ptr + 1;

        return output_batched_arr(arr_len - 3, &arr[3], config_output_ptr);
    }
}

func output_arr(arr_len: felt, arr: felt*, config_output_ptr: felt*) -> (config_output_ptr: felt*) {
    alloc_locals;

    if (arr_len == 0) {
        return (config_output_ptr,);
    }

    assert config_output_ptr[0] = arr[0];
    let config_output_ptr = config_output_ptr + 1;

    return output_arr(arr_len - 1, &arr[1], config_output_ptr);
}
