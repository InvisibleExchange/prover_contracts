%builtins output pedersen range_check ecdsa bitwise ec_op poseidon

from starkware.cairo.common.cairo_builtins import (
    PoseidonBuiltin,
    EcOpBuiltin,
    SignatureBuiltin,
    BitwiseBuiltin,
    HashBuiltin,
)
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.merkle_multi_update import merkle_multi_update
from starkware.cairo.common.squash_dict import squash_dict
from starkware.cairo.common.math import unsigned_div_rem
from starkware.cairo.common.math_cmp import is_not_zero
from starkware.cairo.common.cairo_keccak.keccak import finalize_keccak

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
    OnChainMMActionOutput,
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
from rollup.partition_output import partition_output

from forced_escapes.escape_helpers import EscapeOutput, PositionEscapeOutput
from forced_escapes.note_escape import execute_forced_note_escape
from forced_escapes.order_tab_escape import execute_forced_tab_escape
from forced_escapes.position_escape import execute_forced_position_escape

from smart_contract_mms.register_mm import register_mm
from smart_contract_mms.add_liquidity import add_liquidity_to_mm
from smart_contract_mms.remove_liquidity import remove_liquidity_from_mm
from smart_contract_mms.close_mm import close_mm_position

func main{
    output_ptr,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    bitwise_ptr: BitwiseBuiltin*,
    ec_op_ptr: EcOpBuiltin*,
    poseidon_ptr: PoseidonBuiltin*,
}() {
    alloc_locals;

    // GLOBAL VERIABLES
    %{ transaction_input_data = program_input["transactions"] %}

    // Define python hint functions and classes
    python_define_utils();

    let (keccak_ptr: felt*) = alloc();
    local keccak_ptr_start: felt* = keccak_ptr;

    // * INITIALIZE DICTIONARIES ***********************************************

    local state_dict: DictAccess*;  // Dictionary of updated notes (idx -> note hash)
    local fee_tracker_dict: DictAccess*;  // Dictionary of fees collected (token -> fees collected)
    %{
        ids.state_dict = segments.add()
        ids.fee_tracker_dict = segments.add()
    %}
    let state_dict_start = state_dict;
    let fee_tracker_dict_start = fee_tracker_dict;

    // ? Initialize state update arrays
    let (local note_updates: Note*) = alloc();
    let note_updates_start = note_updates;

    // ? Initialize global config
    local global_config: GlobalConfig*;
    %{ ids.global_config = segments.add() %}
    init_global_config(global_config);

    // * SPLIT OUTPUT SECTIONS ******************************************************

    let (
        local accumulated_hashes: AccumulatedHashesOutput*,
        local deposit_output_ptr: DepositTransactionOutput*,
        local withdraw_output_ptr: WithdrawalTransactionOutput*,
        local onchain_mm_action_output_ptr: OnChainMMActionOutput*,
        local escape_output_ptr: EscapeOutput*,
        local position_escape_output_ptr: PositionEscapeOutput*,
        local note_output_ptr: NoteDiffOutput*,
        local position_output_ptr: PerpPositionOutput*,
        local tab_output_ptr: OrderTabOutput*,
        local empty_output_ptr: ZeroOutput*,
    ) = partition_output(global_config);

    let deposit_output_ptr_start = deposit_output_ptr;
    let withdraw_output_ptr_start = withdraw_output_ptr;

    // * SET FUNDING INFO AND PRICE RANGES * #
    local funding_info: FundingInfo*;
    %{ ids.funding_info = segments.add() %}
    set_funding_info(funding_info);

    // todo: Use this to verify liquidation prices
    let (price_ranges: PriceRange*) = get_price_ranges{global_config=global_config}();

    // * EXECUTE TRANSACTION BATCH ================================================

    %{ countsMap = {} %}
    execute_transactions{
        keccak_ptr=keccak_ptr,
        state_dict=state_dict,
        note_updates=note_updates,
        fee_tracker_dict=fee_tracker_dict,
        deposit_output_ptr=deposit_output_ptr,
        withdraw_output_ptr=withdraw_output_ptr,
        onchain_mm_action_output_ptr=onchain_mm_action_output_ptr,
        escape_output_ptr=escape_output_ptr,
        position_escape_output_ptr=position_escape_output_ptr,
        funding_info=funding_info,
        global_config=global_config,
        price_ranges=price_ranges,
    }();
    %{ print("\ncountsMap: ", countsMap) %}

    // * Squash dictionaries =============================================================================

    // let dict_len = (state_dict - state_dict_start) / DictAccess.SIZE;
    // %{
    //     prev_values = {}
    //     for i in range(ids.dict_len):
    //         idx = memory[ids.state_dict_start.address_ + i*ids.DictAccess.SIZE +0]
    //         prev_val = memory[ids.state_dict_start.address_ + i*ids.DictAccess.SIZE +1]
    //         new_val = memory[ids.state_dict_start.address_ + i*ids.DictAccess.SIZE +2]

    // if idx in prev_values and prev_values[idx] != prev_val:
    //             print("idx: ", idx, "prev_values[idx]: ", prev_values[idx], "prev_val: ", prev_val)

    // prev_values[idx] = new_val
    // %}

    finalize_keccak(keccak_ptr_start=keccak_ptr_start, keccak_ptr_end=keccak_ptr);

    local squashed_state_dict: DictAccess*;
    %{ ids.squashed_state_dict = segments.add() %}
    let (squashed_state_dict_end) = squash_dict(
        dict_accesses=state_dict_start,
        dict_accesses_end=state_dict,
        squashed_dict=squashed_state_dict,
    );
    local squashed_state_dict_len = (squashed_state_dict_end - squashed_state_dict) /
        DictAccess.SIZE;

    // %{
    //     prev_values = {}
    //     for i in range(ids.squashed_state_dict_len):
    //         idx = memory[ids.squashed_state_dict.address_ + i*ids.DictAccess.SIZE +0]
    //         prev_val = memory[ids.squashed_state_dict.address_ + i*ids.DictAccess.SIZE +1]
    //         new_val = memory[ids.squashed_state_dict.address_ + i*ids.DictAccess.SIZE +2]

    // print("idx: ", idx, "prev_val: ", prev_val, "new_val: ", new_val)
    // %}

    // * VERIFY MERKLE TREE UPDATES ******************************************************
    verify_merkle_tree_updates(
        global_config.dex_state.init_state_root,
        global_config.dex_state.final_state_root,
        squashed_state_dict,
        squashed_state_dict_len,
        global_config.dex_state.state_tree_depth,
    );

    // * WRITE STATE UPDATES TO THE PROGRAM OUTPUT ******************************
    %{ stored_indexes = {} %}
    write_state_updates_to_output{
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

    // TODO: local output_ptr: felt = cast(empty_output_ptr, felt);
    local output_ptr: felt = cast(position_escape_output_ptr, felt);

    %{ print("all good") %}

    return ();
}

func execute_transactions{
    pedersen_ptr: HashBuiltin*,
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ec_op_ptr: EcOpBuiltin*,
    ecdsa_ptr: SignatureBuiltin*,
    bitwise_ptr: BitwiseBuiltin*,
    keccak_ptr: felt*,
    state_dict: DictAccess*,
    note_updates: Note*,
    fee_tracker_dict: DictAccess*,
    deposit_output_ptr: DepositTransactionOutput*,
    withdraw_output_ptr: WithdrawalTransactionOutput*,
    onchain_mm_action_output_ptr: OnChainMMActionOutput*,
    escape_output_ptr: EscapeOutput*,
    position_escape_output_ptr: PositionEscapeOutput*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
    price_ranges: PriceRange*,
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
    if (nondet %{ tx_type == "onchain_mm_action" %} != 0) {
        %{ current_order = current_transaction %}

        if (nondet %{ current_order["action_type"] == "register_mm" %} != 0) {
            register_mm();

            return execute_transactions();
        }
        if (nondet %{ current_order["action_type"] == "add_liquidity" %} != 0) {
            add_liquidity_to_mm();

            return execute_transactions();
        }
        if (nondet %{ current_order["action_type"] == "remove_liquidity" %} != 0) {
            remove_liquidity_from_mm();

            return execute_transactions();
        }
        if (nondet %{ current_order["action_type"] == "close_mm_position" %} != 0) {
            close_mm_position();

            return execute_transactions();
        }
    }
    if (nondet %{ tx_type == "forced_escape" %} != 0) {
        if (nondet %{ current_transaction["escape_type"] == "note_escape" %} != 0) {
            execute_forced_note_escape();

            return execute_transactions();
        }
        if (nondet %{ current_transaction["escape_type"] == "order_tab_escape" %} != 0) {
            execute_forced_tab_escape();

            return execute_transactions();
        } else {
            execute_forced_position_escape();

            return execute_transactions();
        }
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
//
