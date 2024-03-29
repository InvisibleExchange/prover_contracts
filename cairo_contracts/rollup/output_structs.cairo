from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, BitwiseBuiltin
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash, poseidon_hash_many
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.math import unsigned_div_rem, split_felt
from starkware.cairo.common.math_cmp import is_not_zero
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.bitwise import bitwise_xor, bitwise_and
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.cairo_keccak.keccak import cairo_keccak_felts_bigend
from starkware.cairo.common.uint256 import Uint256

from helpers.utils import Note
from deposits_withdrawals.deposits.deposit_utils import Deposit
from deposits_withdrawals.withdrawals.withdraw_utils import Withdrawal

from perpetuals.order.order_structs import PerpPosition
from perpetuals.order.order_hash import verify_position_hash
from order_tabs.order_tab import OrderTab, TabHeader, verify_order_tab_hash

from rollup.global_config import GlobalConfig

const BIT_64_AMOUNT = 2 ** 64 - 1;

// Represents the struct of data written to the program output for each Note Modifictaion.
struct NoteDiffOutput {
    // & batched_note_info format: | token (32 bits) | hidden amount (64 bits) | idx (64 bits) |
    batched_note_info: felt,
    commitment: felt,
    address_x: felt,
    address_y: felt,
}

// Represents the struct of data written to the program output for each Deposit.
struct DepositTransactionOutput {
    // & batched_note_info format: | deposit_id (64 bits) | token (32 bits) | amount (64 bits) |
    // & --------------------------  deposit_id => chain id (32 bits) | identifier (32 bits) |
    batched_deposit_info: felt,
    stark_key: felt,
}

// Represents the struct of data written to the program output for each Withdrawal.
struct WithdrawalTransactionOutput {
    // & batched_note_info format: | is_automatic (8 bits) | withdrawal_chain_id (32 bits) | token (32 bits) | amount (64 bits) |
    batched_withdraw_info: felt,
    withdraw_address: felt,  // This should be the eth address to withdraw from
}

struct AccumulatedHashesOutput {
    chain_id: felt,
    accumulated_deposit_hash: felt,
    accumulated_withdrawal_hash: felt,
}

// *********************************************************************************************************

const REGISTRATION = 0;
const ADD_LIQUIDITY = 1;
const REMOVE_LIQUIDITY = 2;
const CLOSE_MM = 3;
struct OnChainMMActionOutput {
    // & batched_registration_info format: | vlp_token (32 bits) | vlp_amount (64 bits) | action_type (8 bits) |
    // & batched_add_liq_info format:  usdcAmount (64 bits) | vlp_amount (64 bits) | action_type (8 bits) |
    // & batched_remove_liq_info format:  | initialValue (64 bits) | vlpAmount (64 bits) | returnAmount (64 bits) | action_type (8 bits) |
    // & batched_close_mm_info format:  | initialValueSum (64 bits) | vlpAmountSum (64 bits) | returnAmount (64 bits) | action_type (8 bits) |
    mm_position_address: felt,
    depositor: felt,
    batched_action_info: felt,
}

// Represents the struct of data written to the program output for each perpetual position Modifictaion.
struct PerpPositionOutput {
    // & format: | index (64 bits) | synthetic_token (32 bits) | position_size (64 bits) | vlp_token (32 bits) |
    // & format: | entry_price (64 bits) | margin (64 bits) | vlp_supply (64 bits) | last_funding_idx (32 bits) | order_side (1 bits) | allow_partial_liquidations (1 bits) |
    // & format: | public key <-> position_address (251 bits) |
    batched_position_info_slot1: felt,
    batched_position_info_slot2: felt,
    public_key: felt,
}

// Represents the struct of data written to the program output for every newly opened order tab
struct OrderTabOutput {
    // & format: | index (59 bits) | base_token (32 bits) | quote_token (32 bits) | quote_hidden_amount (64 bits) | quote_hidden_amount (64 bits)
    batched_tab_info_slot: felt,
    base_commitment: felt,
    quote_commitment: felt,
    public_key: felt,
}

// This is used to output the index of the note/position that has been spent/closed
// The class is only defined for clarity we could just use a felt instead
struct ZeroOutput {
    batched_idxs: felt,  // & | idx1 (64bit) | idx2 (64bit) | idx3 (64bit) |
}

// * ================================================================================================================================================================0
// * STATE * //

func write_state_updates_to_output{
    poseidon_ptr: PoseidonBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*
}(
    state_dict_start: DictAccess*,
    n_state_outputs: felt,
    note_outputs: Note*,
    n_output_notes: felt,
    n_output_positions: felt,
    n_output_tabs: felt,
    n_output_zero_idxs: felt,
) -> (data_commitment: felt) {
    alloc_locals;

    let (data_output_start: felt*) = alloc();

    let note_output_ptr: felt* = data_output_start;
    let position_output_ptr: felt* = note_output_ptr + n_output_notes * NoteDiffOutput.SIZE;
    let tab_output_ptr: felt* = position_output_ptr + n_output_positions * PerpPositionOutput.SIZE;
    let empty_output_ptr: felt* = tab_output_ptr + n_output_tabs * OrderTabOutput.SIZE;

    let (zero_idxs: felt*) = alloc();

    // ? Write note/position/order_tab updates to the program_output
    let (zero_idxs_len: felt, zero_idxs: felt*) = _write_state_updates_to_output_inner{
        note_output_ptr=note_output_ptr,
        position_output_ptr=position_output_ptr,
        tab_output_ptr=tab_output_ptr,
    }(state_dict_start, n_state_outputs, note_outputs, 0, zero_idxs);

    // ? Write batched zero indexes to the output
    _write_zero_indexes_to_output{empty_output_ptr=empty_output_ptr}(zero_idxs_len, zero_idxs);

    // %{
    //     data_output_len = ids.empty_output_ptr - ids.data_output_start

    // for i in range(data_output_len):
    //         print(f"{memory[ids.data_output_start + i]},")
    // %}

    let data_output_len = empty_output_ptr - data_output_start;
    let (data_commitment: felt) = poseidon_hash_many(data_output_len, data_output_start);

    return (data_commitment,);
}

// * ================================================================================================================================================================
// * DEPOSITS/WITHDRAWALS * //

func write_deposit_info_to_output{
    poseidon_ptr: PoseidonBuiltin*, range_check_ptr, deposit_output_ptr: DepositTransactionOutput*
}(deposit: Deposit) {
    alloc_locals;

    // & batched_note_info format: | deposit_id (64 bits) | token (32 bits) | amount (64 bits) |
    // & --------------------------  deposit_id => chain id (32 bits) | identifier (32 bits) |
    let output: DepositTransactionOutput* = deposit_output_ptr;
    assert output.batched_deposit_info = ((deposit.deposit_id * 2 ** 32) + deposit.token) * 2 **
        64 + deposit.amount;
    assert output.stark_key = deposit.deposit_address;

    let deposit_output_ptr = deposit_output_ptr + DepositTransactionOutput.SIZE;

    return ();
}

func write_withdrawal_info_to_output{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    withdraw_output_ptr: WithdrawalTransactionOutput*,
}(withdrawal: Withdrawal, execution_gas_fee: felt) {
    alloc_locals;

    // & batched_note_info format: | is_automatic (8 bits) |  withdrawal_chain_id (32 bits) | token (32 bits) | amount (64 bits) |
    let output: WithdrawalTransactionOutput* = withdraw_output_ptr;

    let is_automatic = is_not_zero(execution_gas_fee);

    assert output.batched_withdraw_info = (
        ((is_automatic * 2 ** 32 + withdrawal.withdrawal_chain) * 2 ** 32) + withdrawal.token
    ) * 2 ** 64 + (withdrawal.amount - execution_gas_fee);
    assert output.withdraw_address = withdrawal.withdrawal_address;

    let withdraw_output_ptr = withdraw_output_ptr + WithdrawalTransactionOutput.SIZE;

    return ();
}

//

func write_l2_deposit_info_to_output{
    poseidon_ptr: PoseidonBuiltin*, range_check_ptr, l2_deposit_outputs: DepositTransactionOutput*
}(deposit: Deposit) {
    alloc_locals;

    // & batched_note_info format: | deposit_id (64 bits) | token (32 bits) | amount (64 bits) |
    // & --------------------------  deposit_id => chain id (32 bits) | identifier (32 bits) |
    let output: DepositTransactionOutput* = l2_deposit_outputs;
    assert output.batched_deposit_info = ((deposit.deposit_id * 2 ** 32) + deposit.token) * 2 **
        64 + deposit.amount;
    assert output.stark_key = deposit.deposit_address;

    let l2_deposit_outputs = l2_deposit_outputs + DepositTransactionOutput.SIZE;

    return ();
}

func write_l2_withdrawal_info_to_output{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    l2_withdrawal_outputs: WithdrawalTransactionOutput*,
}(withdrawal: Withdrawal, execution_gas_fee: felt) {
    alloc_locals;

    // & batched_note_info format: | is_automatic (8 bits) | withdrawal_chain_id (32 bits) | token (32 bits) | amount (64 bits) |
    let output: WithdrawalTransactionOutput* = l2_withdrawal_outputs;

    let is_automatic = is_not_zero(execution_gas_fee);

    assert output.batched_withdraw_info = (
        ((is_automatic * 2 ** 32 + withdrawal.withdrawal_chain) * 2 ** 32) + withdrawal.token
    ) * 2 ** 64 + (withdrawal.amount - execution_gas_fee);
    assert output.withdraw_address = withdrawal.withdrawal_address;

    let l2_withdrawal_outputs = l2_withdrawal_outputs + WithdrawalTransactionOutput.SIZE;

    return ();
}

// * ================================================================================================================================================================

func write_accumulated_hashes_to_output{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    bitwise_ptr: BitwiseBuiltin*,
    keccak_ptr: felt*,
    accumulated_hashes: AccumulatedHashesOutput*,
    global_config: GlobalConfig*,
}(
    l2_deposit_outputs_len: felt,
    l2_deposit_outputs: DepositTransactionOutput*,
    l2_withdrawal_outputs_len: felt,
    l2_withdrawal_outputs: WithdrawalTransactionOutput*,
) {
    return output_accumulated_hashes(
        global_config.chain_ids_len - 1,
        &global_config.chain_ids[1],
        l2_deposit_outputs_len,
        l2_deposit_outputs,
        l2_withdrawal_outputs_len,
        l2_withdrawal_outputs,
    );
}

// * SMART CONTRACT MM REGISTATION * //
func write_mm_registration_to_output{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    onchain_mm_action_output_ptr: OnChainMMActionOutput*,
}(address: felt, vlp_token: felt, vlp_amount: felt) {
    alloc_locals;

    // & batched_registration_info format: | vlp_token (32 bits) | vlp_amount (64 bits) | action_type (8 bits) |
    let output: OnChainMMActionOutput* = onchain_mm_action_output_ptr;
    assert output.mm_position_address = address;
    assert output.depositor = 0;
    assert output.batched_action_info = (vlp_token * 2 ** 64 + vlp_amount) * 2 ** 8 + REGISTRATION;

    let onchain_mm_action_output_ptr = onchain_mm_action_output_ptr + OnChainMMActionOutput.SIZE;

    return ();
}

// * ADD LIQUDITIY * //
func write_mm_add_liquidity_to_output{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    onchain_mm_action_output_ptr: OnChainMMActionOutput*,
}(position_address: felt, depositor: felt, usdc_amount: felt, vlp_amount: felt) {
    alloc_locals;

    // & batched_add_liq_info format:  usdcAmount (64 bits) | vlp_amount (64 bits) | action_type (8 bits) |
    let output: OnChainMMActionOutput* = onchain_mm_action_output_ptr;
    assert output.mm_position_address = position_address;
    assert output.depositor = depositor;
    assert output.batched_action_info = (usdc_amount * 2 ** 64 + vlp_amount) * 2 ** 8 +
        ADD_LIQUIDITY;

    let onchain_mm_action_output_ptr = onchain_mm_action_output_ptr + OnChainMMActionOutput.SIZE;

    return ();
}

// * REMOVE LIQUDITIY * //
func write_mm_remove_liquidity_to_output{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    onchain_mm_action_output_ptr: OnChainMMActionOutput*,
}(
    position_address: felt,
    depositor: felt,
    intial_value: felt,
    vlp_amount: felt,
    return_amount: felt,
) {
    alloc_locals;

    // & batched_remove_liq_info format:  | initialValue (64 bits) | vlpAmount (64 bits) | returnAmount (64 bits) | action_type (8 bits) |
    let output: OnChainMMActionOutput* = onchain_mm_action_output_ptr;
    assert output.mm_position_address = position_address;
    assert output.depositor = depositor;
    assert output.batched_action_info = (
        (intial_value * 2 ** 64 + vlp_amount) * 2 ** 64 + return_amount
    ) * 2 ** 8 + REMOVE_LIQUIDITY;

    let onchain_mm_action_output_ptr = onchain_mm_action_output_ptr + OnChainMMActionOutput.SIZE;

    return ();
}

// * CLOSE MM * //
func write_mm_close_to_output{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    onchain_mm_action_output_ptr: OnChainMMActionOutput*,
}(position_address: felt, intial_value_sum: felt, vlp_amount_sum: felt, return_amount: felt) {
    alloc_locals;

    // & batched_close_mm_info format:  | initialValueSum (64 bits) | vlpAmountSum (64 bits) | returnAmount (64 bits) | action_type (8 bits) |
    let output: OnChainMMActionOutput* = onchain_mm_action_output_ptr;
    assert output.mm_position_address = position_address;
    assert output.depositor = 0;
    assert output.batched_action_info = (
        (intial_value_sum * 2 ** 64 + vlp_amount_sum) * 2 ** 64 + return_amount
    ) * 2 ** 8 + CLOSE_MM;

    let onchain_mm_action_output_ptr = onchain_mm_action_output_ptr + OnChainMMActionOutput.SIZE;

    return ();
}

// ! ================================================================================================================================================================
// * ================================================================================================================================================================
// * ================================================================================================================================================================
// * ================================================================================================================================================================
// * ================================================================================================================================================================
// * ================================================================================================================================================================
// ! ================================================================================================================================================================
// HELPERS

// * ================================================================================================================================================================0
// * STATE * //

func _write_state_updates_to_output_inner{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    bitwise_ptr: BitwiseBuiltin*,
    note_output_ptr: felt*,
    position_output_ptr: felt*,
    tab_output_ptr: felt*,
}(
    state_dict_start: DictAccess*,
    n_state_outputs: felt,
    note_outputs: Note*,
    zero_idxs_len: felt,
    zero_idxs: felt*,
) -> (zero_idxs_len: felt, zero_idxs: felt*) {
    alloc_locals;

    if (n_state_outputs == 0) {
        // ? Write zero outputs

        return (zero_idxs_len, zero_idxs);
    }

    let idx: felt = state_dict_start.key;
    let leaf_hash: felt = state_dict_start.new_value;

    if (nondet %{ leaf_node_types[ids.idx] == "note" %} != 0) {
        if (leaf_hash != 0) {
            write_note_update(note_outputs, idx, leaf_hash);

            let state_dict_start = state_dict_start + DictAccess.SIZE;
            return _write_state_updates_to_output_inner(
                state_dict_start, n_state_outputs - 1, note_outputs, zero_idxs_len, zero_idxs
            );
        } else {
            assert zero_idxs[zero_idxs_len] = idx;
            let zero_idxs_len = zero_idxs_len + 1;

            let state_dict_start = state_dict_start + DictAccess.SIZE;
            return _write_state_updates_to_output_inner(
                state_dict_start, n_state_outputs - 1, note_outputs, zero_idxs_len, zero_idxs
            );
        }
    }

    if (nondet %{ leaf_node_types[ids.idx] == "position" %} != 0) {
        if (leaf_hash != 0) {
            write_position_update(idx, leaf_hash);

            let state_dict_start = state_dict_start + DictAccess.SIZE;
            return _write_state_updates_to_output_inner(
                state_dict_start, n_state_outputs - 1, note_outputs, zero_idxs_len, zero_idxs
            );
        } else {
            assert zero_idxs[zero_idxs_len] = idx;
            let zero_idxs_len = zero_idxs_len + 1;

            let state_dict_start = state_dict_start + DictAccess.SIZE;
            return _write_state_updates_to_output_inner(
                state_dict_start, n_state_outputs - 1, note_outputs, zero_idxs_len, zero_idxs
            );
        }
    }

    if (nondet %{ leaf_node_types[ids.idx] == "order_tab" %} != 0) {
        if (leaf_hash != 0) {
            write_order_tab_update(idx, leaf_hash);

            let state_dict_start = state_dict_start + DictAccess.SIZE;
            return _write_state_updates_to_output_inner(
                state_dict_start, n_state_outputs - 1, note_outputs, zero_idxs_len, zero_idxs
            );
        } else {
            assert zero_idxs[zero_idxs_len] = idx;
            let zero_idxs_len = zero_idxs_len + 1;

            let state_dict_start = state_dict_start + DictAccess.SIZE;
            return _write_state_updates_to_output_inner(
                state_dict_start, n_state_outputs - 1, note_outputs, zero_idxs_len, zero_idxs
            );
        }
    }

    return (zero_idxs_len, zero_idxs);
}

// * Helpers

// ?: Loop backwards through the notes array and write the last update for each index to the program output
func write_note_update{
    poseidon_ptr: PoseidonBuiltin*, bitwise_ptr: BitwiseBuiltin*, note_output_ptr: felt*
}(note_outputs: Note*, idx: felt, hash: felt) {
    alloc_locals;

    local array_position_idx: felt;
    %{ ids.array_position_idx = int(note_output_idxs[ids.idx]) %}

    let note_ouput: Note = note_outputs[array_position_idx];
    assert note_ouput.hash = hash;

    _write_new_note_to_output(note_ouput, idx);

    return ();
}

func write_position_update{
    poseidon_ptr: PoseidonBuiltin*, bitwise_ptr: BitwiseBuiltin*, position_output_ptr: felt*
}(idx: felt, hash: felt) {
    alloc_locals;

    local position: PerpPosition;
    %{ read_output_position(ids.position.address_, ids.idx) %}

    verify_position_hash(position);
    assert position.hash = hash;

    _write_position_info_to_output(position, idx);

    return ();
}

func write_order_tab_update{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    bitwise_ptr: BitwiseBuiltin*,
    tab_output_ptr: felt*,
}(idx: felt, hash: felt) {
    alloc_locals;

    // let (__fp__, _) = get_fp_and_pc();

    local order_tab: OrderTab;
    %{ read_output_order_tab(ids.order_tab.address_, ids.idx) %}

    verify_order_tab_hash(order_tab);
    assert order_tab.hash = hash;

    _write_order_tab_info_to_output(order_tab, idx);

    return ();
}

// * ================================================================================================================================================================
// * DEPOSITS/WITHDRAWALS * //

func output_accumulated_hashes{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    bitwise_ptr: BitwiseBuiltin*,
    keccak_ptr: felt*,
    accumulated_hashes: AccumulatedHashesOutput*,
    global_config: GlobalConfig*,
}(
    chain_ids_len: felt,
    chain_ids: felt*,
    deposit_outputs_len: felt,
    deposit_outputs: DepositTransactionOutput*,
    withdraw_outputs_len: felt,
    withdraw_outputs: WithdrawalTransactionOutput*,
) {
    alloc_locals;

    if (chain_ids_len == 0) {
        return ();
    }

    let chain_id: felt = chain_ids[0];

    // ? Get the accumulated hashes for the current chain
    let accumulated_deposit_hash = get_accumulated_deposit_hash(
        chain_id, deposit_outputs_len, deposit_outputs, 0
    );
    let accumulated_withdraw_hash = get_accumulated_withdraw_hash(
        chain_id, withdraw_outputs_len, withdraw_outputs, 0
    );

    %{
        print(f"chain_id: {ids.chain_id}")
        print(f"accumulated_deposit_hash: {ids.accumulated_deposit_hash}")
        print(f"accumulated_withdraw_hash: {ids.accumulated_withdraw_hash}")
    %}

    // ? Write the accumulated hashes to the output
    let output: AccumulatedHashesOutput* = accumulated_hashes;

    assert output.chain_id = chain_id;
    assert output.accumulated_deposit_hash = accumulated_deposit_hash;
    assert output.accumulated_withdrawal_hash = accumulated_withdraw_hash;

    let accumulated_hashes = accumulated_hashes + AccumulatedHashesOutput.SIZE;

    return output_accumulated_hashes(
        chain_ids_len - 1,
        &chain_ids[1],
        deposit_outputs_len,
        deposit_outputs,
        withdraw_outputs_len,
        withdraw_outputs,
    );
}

func get_accumulated_deposit_hash{
    range_check_ptr, poseidon_ptr: PoseidonBuiltin*, bitwise_ptr: BitwiseBuiltin*, keccak_ptr: felt*
}(
    chain_id: felt,
    deposit_outputs_len: felt,
    deposit_outputs: DepositTransactionOutput*,
    accumulated_deposit_hash: felt,
) -> felt {
    alloc_locals;

    if (deposit_outputs_len == 0) {
        return accumulated_deposit_hash;
    }

    let deposit_output: DepositTransactionOutput = deposit_outputs[0];

    // & batched_note_info format: | deposit_id (64 bits) | token (32 bits) | amount (64 bits) |
    // & --------------------------  deposit_id => chain id (32 bits) | identifier (32 bits) |
    let (deposit_chain_id, _) = split_felt(deposit_output.batched_deposit_info);

    if (deposit_chain_id != chain_id) {
        return get_accumulated_deposit_hash(
            chain_id,
            deposit_outputs_len - 1,
            deposit_outputs + DepositTransactionOutput.SIZE,
            accumulated_deposit_hash,
        );
    }

    // ? Get the Deposit hash
    let (local input_arr: felt*) = alloc();
    assert input_arr[0] = deposit_output.batched_deposit_info;
    assert input_arr[1] = deposit_output.stark_key;

    let (res: Uint256) = cairo_keccak_felts_bigend(2, input_arr);
    let deposit_hash = res.high * 2 ** 128 + res.low;

    // ? Get the new accumulated withdrawals hash
    let (local input_arr2: felt*) = alloc();
    assert input_arr2[0] = accumulated_deposit_hash;
    assert input_arr2[1] = deposit_hash;

    let (res2: Uint256) = cairo_keccak_felts_bigend(2, input_arr2);
    let accumulated_deposit_hash = res2.high * 2 ** 128 + res2.low;

    return get_accumulated_deposit_hash(
        chain_id,
        deposit_outputs_len - 1,
        deposit_outputs + DepositTransactionOutput.SIZE,
        accumulated_deposit_hash,
    );
}

func get_accumulated_withdraw_hash{
    range_check_ptr, poseidon_ptr: PoseidonBuiltin*, bitwise_ptr: BitwiseBuiltin*, keccak_ptr: felt*
}(
    chain_id: felt,
    withdraw_outputs_len: felt,
    withdraw_outputs: WithdrawalTransactionOutput*,
    accumulated_withdraw_hash: felt,
) -> felt {
    alloc_locals;

    if (withdraw_outputs_len == 0) {
        return accumulated_withdraw_hash;
    }

    let withdraw_output: WithdrawalTransactionOutput = withdraw_outputs[0];

    // & batched_note_info format: | is_automatic (8 bits) | withdrawal_chain_id (32 bits) | token (32 bits) | amount (64 bits) |
    let devisor: felt = 2 ** 96;
    let (result, _) = unsigned_div_rem(withdraw_output.batched_withdraw_info, devisor);
    let (is_automatic, withdraw_chain_id) = unsigned_div_rem(result, 2 ** 32);

    if (withdraw_chain_id != chain_id) {
        return get_accumulated_withdraw_hash(
            chain_id,
            withdraw_outputs_len - 1,
            withdraw_outputs + WithdrawalTransactionOutput.SIZE,
            accumulated_withdraw_hash,
        );
    }

    // ? Get the withdrawal hash
    let (local input_arr: felt*) = alloc();
    assert input_arr[0] = withdraw_output.batched_withdraw_info;
    assert input_arr[1] = withdraw_output.withdraw_address;

    let (res: Uint256) = cairo_keccak_felts_bigend(2, input_arr);
    let withdraw_hash = res.high * 2 ** 128 + res.low;

    // ? Get the new accumulated withdrawals hash
    let (local input_arr2: felt*) = alloc();
    assert input_arr2[0] = accumulated_withdraw_hash;
    assert input_arr2[1] = withdraw_hash;

    let (res2: Uint256) = cairo_keccak_felts_bigend(2, input_arr2);
    let accumulated_withdraw_hash = res2.high * 2 ** 128 + res2.low;

    return get_accumulated_withdraw_hash(
        chain_id,
        withdraw_outputs_len - 1,
        withdraw_outputs + WithdrawalTransactionOutput.SIZE,
        accumulated_withdraw_hash,
    );
}

// * ================================================================================================================================================================
// * HELPERS * //

// * Notes * //
func _write_new_note_to_output{
    poseidon_ptr: PoseidonBuiltin*, bitwise_ptr: BitwiseBuiltin*, note_output_ptr: felt*
}(note: Note, index: felt) {
    alloc_locals;

    let output: felt* = note_output_ptr;

    let (trimed_blinding: felt) = bitwise_and(note.blinding_factor, BIT_64_AMOUNT);
    let (hidden_amount: felt) = bitwise_xor(note.amount, trimed_blinding);

    // & batched_note_info format: | token (32 bits) | hidden amount (64 bits) | idx (64 bits) |
    assert output[0] = ((note.token * 2 ** 64) + hidden_amount) * 2 ** 64 + index;
    let (comm: felt) = poseidon_hash(note.amount, note.blinding_factor);
    assert output[1] = comm;
    assert output[2] = note.address.x;
    assert output[3] = note.address.y;

    let note_output_ptr = note_output_ptr + NoteDiffOutput.SIZE;

    return ();
}

// * Positions * //
func _write_position_info_to_output{position_output_ptr: felt*, poseidon_ptr: PoseidonBuiltin*}(
    position: PerpPosition, index: felt
) {
    alloc_locals;

    let output: felt* = position_output_ptr;

    // & | index (64 bits) | synthetic_token (32 bits) | position_size (64 bits) |  vlp_token (32 bits) |
    assert output[0] = (
        (position.index * 2 ** 32 + position.position_header.synthetic_token) * 2 ** 64 +
        position.position_size
    ) * 2 ** 32 + position.position_header.vlp_token;

    // & | entry_price (64 bits) | margin (64 bits) | vlp_supply (64 bits) | last_funding_idx (32 bits) | order_side (1 bits) | allow_partial_liquidations (1 bits) |
    assert output[1] = (
        (
            (((position.entry_price * 2 ** 64) + position.margin) * 2 ** 64 + position.vlp_supply) *
            2 ** 32 +
            position.last_funding_idx
        ) * 2 +
        position.order_side
    ) * 2 + position.position_header.allow_partial_liquidations;

    assert output[2] = position.position_header.position_address;

    let position_output_ptr = position_output_ptr + PerpPositionOutput.SIZE;

    return ();
}

// * Order Tabs * //
func _write_order_tab_info_to_output{
    bitwise_ptr: BitwiseBuiltin*,
    tab_output_ptr: felt*,
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
}(order_tab: OrderTab, index: felt) {
    alloc_locals;

    let output: felt* = tab_output_ptr;

    let tab_header: TabHeader* = &order_tab.tab_header;

    let (base_trimed_blinding: felt) = bitwise_and(tab_header.base_blinding, BIT_64_AMOUNT);
    let (base_hidden_amount: felt) = bitwise_xor(order_tab.base_amount, base_trimed_blinding);
    let (quote_trimed_blinding: felt) = bitwise_and(tab_header.quote_blinding, BIT_64_AMOUNT);
    let (quote_hidden_amount: felt) = bitwise_xor(order_tab.quote_amount, quote_trimed_blinding);

    // & format: | index (59 bits) | base_token (32 bits) | quote_token (32 bits) | base_hidden_amount (64 bits) | quote_hidden_amount (64 bits)
    let batched_info1 = (
        ((index * 2 ** 32 + tab_header.base_token) * 2 ** 32 + tab_header.quote_token) * 2 ** 64 +
        base_hidden_amount
    ) * 2 ** 64 + quote_hidden_amount;
    assert output[0] = batched_info1;

    let (base_commitment: felt) = poseidon_hash(order_tab.base_amount, tab_header.base_blinding);
    let (quote_commitment: felt) = poseidon_hash(order_tab.quote_amount, tab_header.quote_blinding);

    assert output[1] = base_commitment;
    assert output[2] = quote_commitment;
    assert output[3] = tab_header.pub_key;

    let tab_output_ptr = tab_output_ptr + OrderTabOutput.SIZE;

    return ();
}

// * Empty Outputs * //
func _write_zero_indexes_to_output{poseidon_ptr: PoseidonBuiltin*, empty_output_ptr: felt*}(
    zero_idxs_len: felt, zero_idxs: felt*
) {
    alloc_locals;

    // & Batch indexes by 3 to reduce calldata cost
    if (zero_idxs_len == 0) {
        return ();
    }

    if (zero_idxs_len == 1) {
        let output: felt* = empty_output_ptr;
        assert output[0] = zero_idxs[0];

        let empty_output_ptr = empty_output_ptr + ZeroOutput.SIZE;

        return ();
    }
    if (zero_idxs_len == 2) {
        let batched_zero_idxs = (zero_idxs[0] * 2 ** 64) + zero_idxs[1];

        let output: felt* = empty_output_ptr;
        assert output[0] = batched_zero_idxs;

        let empty_output_ptr = empty_output_ptr + ZeroOutput.SIZE;

        return ();
    } else {
        let batched_zero_idxs = ((zero_idxs[0] * 2 ** 64) + zero_idxs[1]) * 2 ** 64 + zero_idxs[2];

        let output: felt* = empty_output_ptr;
        assert output[0] = batched_zero_idxs;

        let empty_output_ptr = empty_output_ptr + ZeroOutput.SIZE;

        return _write_zero_indexes_to_output(zero_idxs_len - 3, &zero_idxs[3]);
    }
}
