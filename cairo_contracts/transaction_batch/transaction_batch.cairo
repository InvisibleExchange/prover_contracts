%builtins output pedersen range_check ecdsa bitwise

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin, BitwiseBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.merkle_multi_update import merkle_multi_update
from starkware.cairo.common.squash_dict import squash_dict
from starkware.cairo.common.math import unsigned_div_rem
from starkware.cairo.common.math_cmp import is_not_zero

from invisible_swaps.swap.invisible_swap import execute_swap
from deposits_withdrawals.deposits.deposit import verify_deposit
from deposits_withdrawals.withdrawals.withdrawal import verify_withdrawal

from perpetuals.funding.funding import set_funding_info, FundingInfo
from perpetuals.prices.prices import PriceRange, get_price_ranges
from perpetuals.perp_swap.perpetual_swap import execute_perpetual_swap
from perpetuals.transaction.change_margin import execute_margin_change

from perpetuals.liquidations.liquidation_transaction import execute_liquidation_order

from order_tabs.open_order_tab import open_order_tab
from order_tabs.close_order_tab import close_order_tab

from invisible_swaps.split_notes.split_notes import execute_note_split
from helpers.utils import Note

from rollup.python_definitions import python_define_utils
from rollup.output_structs import (
    NoteDiffOutput,
    PerpPositionOutput,
    OrderTabOutput,
    ZeroOutput,
    MMRegistrationOutput,
    WithdrawalTransactionOutput,
    DepositTransactionOutput,
    write_state_updates_to_output,
    AccumulatedHashesOutput,
    write_accumulated_hashes_to_output,
)
from rollup.global_config import (
    GlobalConfig,
    init_global_config,
    init_output_structs,
    GlobalDexState,
)

from smart_contract_mms.register_mm import register_mm
from smart_contract_mms.add_liquidity import add_liquidity_to_mm
from smart_contract_mms.remove_liquidity import remove_liquidity_from_mm

const TREE_DEPTH = 5;

func main{
    output_ptr,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    bitwise_ptr: BitwiseBuiltin*,
}() {
    alloc_locals;

    // GLOBAL VERIABLES
    %{ transaction_input_data = program_input["transactions"] %}

    // Define python hint functions and classes
    python_define_utils();

    // * INITIALIZE DICTIONARIES ***********************************************

    local state_dict: DictAccess*;  // Dictionary of updated notes (idx -> note hash)
    local fee_tracker_dict: DictAccess*;  // Dictionary of fees collected (token -> fees collected)
    local order_tab_dict: DictAccess*;  // Dictionary of updated order tabs (idx -> tab hash)
    %{
        ids.state_dict = segments.add()
        ids.fee_tracker_dict = segments.add()
        ids.order_tab_dict = segments.add()
    %}
    let state_dict_start = state_dict;
    let fee_tracker_dict_start = fee_tracker_dict;
    let order_tab_dict_start = order_tab_dict;

    // ? Initialize state update arrays
    let (local note_updates: Note*) = alloc();
    let note_updates_start = note_updates;

    // ? Initialize global config
    local global_config: GlobalConfig*;
    %{ ids.global_config = segments.add() %}
    init_global_config(global_config);

    // * SPLIT OUTPUT SECTIONS ******************************************************
    // ? DexState and GlobalConfig
    local config_output_ptr: felt* = cast(output_ptr, felt*);
    let (config_output_ptr: felt*) = init_output_structs(config_output_ptr, global_config);

    // ? Accumulated hashes
    local accumulated_hashes: AccumulatedHashesOutput* = cast(
        config_output_ptr, AccumulatedHashesOutput*
    );
    // ? Deposits
    local deposit_output_ptr: DepositTransactionOutput* = cast(
        accumulated_hashes + global_config.chain_ids_len * AccumulatedHashesOutput.SIZE,
        DepositTransactionOutput*,
    );
    // ? Withdrawals
    local withdraw_output_ptr: WithdrawalTransactionOutput* = cast(
        deposit_output_ptr + global_config.dex_state.n_deposits * DepositTransactionOutput.SIZE,
        WithdrawalTransactionOutput*,
    );
    let deposit_output_ptr_start = deposit_output_ptr;
    let withdraw_output_ptr_start = withdraw_output_ptr;

    // ? MM registrations
    local registration_output_ptr: MMRegistrationOutput* = cast(
        withdraw_output_ptr + global_config.dex_state.n_withdrawals *
        WithdrawalTransactionOutput.SIZE,
        MMRegistrationOutput*,
    );
    // ? Note updates
    local note_output_ptr: NoteDiffOutput* = cast(
        registration_output_ptr + global_config.dex_state.n_mm_registrations *
        MMRegistrationOutput.SIZE,
        NoteDiffOutput*,
    );
    // ? Positon updates
    local position_output_ptr: PerpPositionOutput* = cast(
        note_output_ptr + global_config.dex_state.n_output_notes * NoteDiffOutput.SIZE,
        PerpPositionOutput*,
    );
    // ? Order tab updates
    local tab_output_ptr: OrderTabOutput* = cast(
        position_output_ptr + global_config.dex_state.n_output_positions * PerpPositionOutput.SIZE,
        OrderTabOutput*,
    );
    // ? Zero outputs
    local empty_output_ptr: ZeroOutput* = cast(
        tab_output_ptr + global_config.dex_state.n_output_tabs * OrderTabOutput.SIZE, ZeroOutput*
    );

    // * SET FUNDING INFO AND PRICE RANGES * #
    local funding_info: FundingInfo*;
    %{ ids.funding_info = segments.add() %}
    set_funding_info(funding_info);

    // todo: Use this to verify liquidation prices
    // let (price_ranges: PriceRange*) = get_price_ranges{global_config=global_config}();

    // * EXECUTE TRANSACTION BATCH ================================================

    %{
        import time
        t1_start = time.time()
    %}

    %{ countsMap = {} %}
    // price_ranges=price_ranges,
    execute_transactions{
        state_dict=state_dict,
        note_updates=note_updates,
        fee_tracker_dict=fee_tracker_dict,
        deposit_output_ptr=deposit_output_ptr,
        withdraw_output_ptr=withdraw_output_ptr,
        registration_output_ptr=registration_output_ptr,
        funding_info=funding_info,
        global_config=global_config,
    }();
    %{ print("countsMap: ", countsMap) %}

    // * Squash dictionaries =============================================================================

    // let dict_len = (state_dict - state_dict_start) / DictAccess.SIZE;
    // %{
    //     prev_values = {}
    //     for i in range(ids.dict_len):
    //         idx = memory[ids.state_dict_start.address_ + i*ids.DictAccess.SIZE +0]
    //         prev_val = memory[ids.state_dict_start.address_ + i*ids.DictAccess.SIZE +1]
    //         new_val = memory[ids.state_dict_start.address_ + i*ids.DictAccess.SIZE +2]

    // if idx in prev_values:
    //             if prev_values[idx] != prev_val:
    //                 print("idx: ", idx, "prev_values[idx]: ", prev_values[idx], "prev_val: ", prev_val)

    // prev_values[idx] = new_val
    // %}

    local squashed_state_dict: DictAccess*;
    %{ ids.squashed_state_dict = segments.add() %}
    let (squashed_state_dict_end) = squash_dict(
        dict_accesses=state_dict_start,
        dict_accesses_end=state_dict,
        squashed_dict=squashed_state_dict,
    );
    local squashed_state_dict_len = (squashed_state_dict_end - squashed_state_dict) /
        DictAccess.SIZE;

    // * VERIFY MERKLE TREE UPDATES ******************************************************

    // verify_merkle_tree_updates(
    //     global_config.dex_state.init_state_root,
    //     global_config.dex_state.final_state_root,
    //     squashed_state_dict,
    //     squashed_state_dict_len,
    //     global_config.dex_state.state_tree_depth,
    // );

    // * WRITE STATE UPDATES TO THE PROGRAM OUTPUT ******************************

    // TODO: Must verify that the output lengths are consistent with those defined in dex_state
    %{ stored_indexes = {} %}
    write_state_updates_to_output{
        pedersen_ptr=pedersen_ptr,
        bitwise_ptr=bitwise_ptr,
        note_output_ptr=note_output_ptr,
        position_output_ptr=position_output_ptr,
        tab_output_ptr=tab_output_ptr,
        empty_output_ptr=empty_output_ptr,
    }(squashed_state_dict, squashed_state_dict_len, note_updates_start);

    // * WRITE DEPOSIT AND WITHDRAWAL ACCUMULATED OUTPUTS TO THE PROGRAM OUTPUT ***********
    let deposit_output_len = (deposit_output_ptr - deposit_output_ptr_start) /
        DepositTransactionOutput.SIZE;
    let withdraw_output_len = (withdraw_output_ptr - withdraw_output_ptr_start) /
        WithdrawalTransactionOutput.SIZE;
    write_accumulated_hashes_to_output{
        accumulated_hashes=accumulated_hashes, global_config=global_config
    }(deposit_output_len, deposit_output_ptr_start, withdraw_output_len, withdraw_output_ptr_start);

    local output_ptr: felt = cast(empty_output_ptr, felt);

    %{ print("all good") %}

    return ();
}

func execute_transactions{
    pedersen_ptr: HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    fee_tracker_dict: DictAccess*,
    deposit_output_ptr: DepositTransactionOutput*,
    withdraw_output_ptr: WithdrawalTransactionOutput*,
    registration_output_ptr: MMRegistrationOutput*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}() {
    alloc_locals;

    if (nondet %{ len(transaction_input_data) == 0 %} != 0) {
        return ();
    }

    %{
        current_transaction = transaction_input_data.pop(0) 
        tx_type = current_transaction["transaction_type"]

        if tx_type in countsMap:
            countsMap[tx_type] += 1
        else:
            countsMap[tx_type] = 1
    %}

    if (nondet %{ tx_type == "swap" %} != 0) {
        %{ current_swap = current_transaction %}

        execute_swap();

        return execute_transactions();
    }

    if (nondet %{ tx_type == "deposit" %} != 0) {
        %{ current_deposit = current_transaction["deposit"] %}

        verify_deposit();

        return execute_transactions();
    }

    if (nondet %{ tx_type == "withdrawal" %} != 0) {
        %{ current_withdrawal = current_transaction["withdrawal"] %}

        verify_withdrawal();

        return execute_transactions();
    }

    if (nondet %{ tx_type == "perpetual_swap" %} != 0) {
        %{ current_swap = current_transaction %}

        execute_perpetual_swap();

        return execute_transactions();
    }

    if (nondet %{ tx_type == "liquidation_order" %} != 0) {
        %{
            current_liquidation = current_transaction
            current_order = current_liquidation["liquidation_order"]
        %}

        execute_liquidation_order();

        return execute_transactions();
    }

    if (nondet %{ tx_type == "note_split" %} != 0) {
        %{ current_split_info = current_transaction["note_split"] %}

        execute_note_split();

        return execute_transactions();
    }
    if (nondet %{ tx_type == "margin_change" %} != 0) {
        %{
            current_margin_change_info = current_transaction["margin_change"]
            zero_index = int(current_transaction["zero_idx"])
        %}

        execute_margin_change();

        return execute_transactions();
    }
    if (nondet %{ tx_type == "open_order_tab" %} != 0) {
        %{ current_order = current_transaction %}

        open_order_tab();

        return execute_transactions();
    }
    if (nondet %{ tx_type == "close_order_tab" %} != 0) {
        %{ current_order = current_transaction %}

        close_order_tab();

        return execute_transactions();
    }
    if (nondet %{ tx_type == "onchain_register_mm" %} != 0) {
        %{ current_order = current_transaction %}

        register_mm();

        return execute_transactions();
    }
    if (nondet %{ tx_type == "add_liquidity" %} != 0) {
        %{ current_order = current_transaction %}

        add_liquidity_to_mm();

        return execute_transactions();
    }
    if (nondet %{ tx_type == "remove_liquidity" %} != 0) {
        %{ current_order = current_transaction %}

        remove_liquidity_from_mm();

        return execute_transactions();
    } else {
        %{ print("unknown transaction type: ", current_transaction) %}
        return execute_transactions();
    }
}

func verify_merkle_tree_updates{pedersen_ptr: HashBuiltin*, range_check_ptr}(
    prev_root: felt,
    new_root: felt,
    squashed_state_dict: DictAccess*,
    squashed_state_dict_len: felt,
    state_tree_depth: felt,
) {
    %{
        preimage = program_input["preimage"]
        preimage = {int(k):[int(x) for x in v] for k,v in preimage.items()}
    %}
    merkle_multi_update{hash_ptr=pedersen_ptr}(
        squashed_state_dict, squashed_state_dict_len, state_tree_depth, prev_root, new_root
    );

    return ();
}
