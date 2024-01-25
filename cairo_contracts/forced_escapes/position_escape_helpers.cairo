from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, EcOpBuiltin, BitwiseBuiltin
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.pow import pow
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.ec import EcPoint
from starkware.cairo.common.math import unsigned_div_rem, split_felt
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.cairo_keccak.keccak import cairo_keccak_felts_bigend
from starkware.cairo.common.uint256 import Uint256
from starkware.cairo.common.bool import TRUE, FALSE

from perpetuals.order.perp_position import (
    construct_new_position,
    is_position_liquidatable,
    get_current_leverage,
    increase_position_size_internal,
    reduce_position_size_internal,
    flip_position_side_internal,
)
from perpetuals.order.order_structs import PerpPosition, OpenOrderFields
from perpetuals.order.order_hash import verify_position_hash, _hash_open_order_fields

from perpetuals.transaction.perp_transaction import get_perp_position, get_open_order_fields
from perpetuals.transaction.perp_transaction import close_position_internal

from perpetuals.funding.funding import FundingInfo

from rollup.global_config import GlobalConfig

from helpers.perp_helpers.dict_updates import (
    update_state_dict,
    update_position_state,
    update_position_state_on_close,
)
from helpers.utils import (
    Note,
    verify_note_hashes,
    verify_note_hash,
    sum_notes,
    take_fee,
    get_collateral_amount,
    hash_notes_array_solidity,
    _hash_note_inputs_solidity,
)
from helpers.signatures import is_signature_valid, sum_pub_keys

from forced_escapes.escape_helpers import prove_invalid_leaf, PositionEscapeOutput

struct PositionEscape {
    escape_id: felt,
    //
    position_a: PerpPosition,
    close_price: felt,
    open_order_fields_b: felt,
}

// * --------------------
func validate_position_a{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    global_config: GlobalConfig*,
    state_dict: DictAccess*,
}(position_a: PerpPosition, index_price: felt) -> felt {
    alloc_locals;

    let (is_liquidatable: felt) = is_position_liquidatable(position_a, index_price);
    if (is_liquidatable == TRUE) {
        return FALSE;
    }

    if (nondet %{ not position_escape["is_valid_a"] %} != 0) {
        // ? Position does not exist in the state

        local valid_leaf: felt;
        %{ ids.valid_leaf = int(position_escape["valid_leaf_a"]) %}

        prove_invalid_leaf(position_a.index, position_a.hash, valid_leaf);

        return FALSE;
    }

    return TRUE;
}

// * --------------------
func validate_counter_party_open_order{range_check_ptr, global_config: GlobalConfig*}(
    position_a: PerpPosition, close_price: felt, open_order_fields_b: OpenOrderFields
) -> (felt, felt) {
    alloc_locals;

    let synthetic_token = position_a.position_header.synthetic_token;
    let synthetic_amount = position_a.position_size;

    let (sum: felt) = sum_notes(
        open_order_fields_b.notes_in_len,
        open_order_fields_b.notes_in,
        open_order_fields_b.collateral_token,
        0,
    );
    if (sum != open_order_fields_b.refund_note.amount + open_order_fields_b.initial_margin) {
        let refund_amount = open_order_fields_b.refund_note.amount;
        let init_margin = open_order_fields_b.initial_margin;

        return (0, FALSE);
    }

    let (local nominal_collateral_amount: felt) = get_collateral_amount(
        synthetic_token, synthetic_amount, close_price
    );

    let (multiplier: felt) = pow(10, global_config.leverage_decimals);
    let (leverage, _) = unsigned_div_rem(
        nominal_collateral_amount * multiplier, open_order_fields_b.initial_margin
    );

    // if leverage > 15: return FALSE
    if (is_le(15 * multiplier + 1, leverage) == 1) {
        return (0, FALSE);
    }

    return (leverage, TRUE);
}

// * --------------------
func open_counter_party_position{
    range_check_ptr, poseidon_ptr: PoseidonBuiltin*, global_config: GlobalConfig*
}(position_a: PerpPosition, open_order_fields: OpenOrderFields, leverage: felt) -> (
    position: PerpPosition
) {
    alloc_locals;

    let synthetic_token = position_a.position_header.synthetic_token;
    let synthetic_amount = position_a.position_size;

    local position_idx: felt;
    %{ ids.position_idx = int(current_transaction["new_position_b"]["index"]) %}

    local funding_idx: felt;
    %{ ids.funding_idx = int(position_escape["new_funding_idx"]) %}

    let (position: PerpPosition) = construct_new_position(
        position_a.order_side,
        synthetic_token,
        global_config.collateral_token,
        synthetic_amount,
        open_order_fields.initial_margin,
        leverage,
        open_order_fields.position_address,
        funding_idx,
        position_idx,
        0,
        open_order_fields.allow_partial_liquidations,
    );

    return (position,);
}

// * --------------------
func handle_counter_party_modify_order{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    global_config: GlobalConfig*,
    funding_info: FundingInfo*,
}(position_a: PerpPosition, position_b: PerpPosition, close_price: felt, index_price: felt) -> (
    is_valid: felt, position: PerpPosition
) {
    alloc_locals;

    let (is_liquidatable: felt) = is_position_liquidatable(position_b, index_price);
    if (is_liquidatable == TRUE) {
        return (FALSE, position_b);
    }

    if (position_a.position_header.synthetic_token != position_b.position_header.synthetic_token) {
        // ? Synthetic tokens do not match
        return (FALSE, position_b);
    }

    local funding_idx: felt;
    %{ ids.funding_idx = order_indexes["new_funding_idx"] %}

    if (position_a.order_side == position_b.order_side) {
        let (position_b: PerpPosition) = increase_position_size_internal(
            position_b, position_a.position_size, close_price, 0, funding_idx
        );

        let (is_valid, leverage) = get_current_leverage(position_b, close_price);

        let (leverage_scaler) = pow(10, global_config.leverage_decimals);
        let is_leverage_too_high = is_le(15 * leverage_scaler, leverage - 1);
        if (is_valid * is_leverage_too_high == 0) {
            // ? If position is liquidatable or the leverage is to high
            return (FALSE, position_b);
        }

        return (TRUE, position_b);
    } else {
        // if position_a.position_size < position_b.position_size {
        // ? Decrease position_b size

        let cond1 = is_le(position_a.position_size, position_b.position_size);
        if (cond1 == TRUE) {
            // ? Decreas position_b size
            let (position_b: PerpPosition) = reduce_position_size_internal(
                position_b, position_a.position_size, close_price, 0, funding_idx
            );

            return (TRUE, position_b);
        } else {
            // ? Flip position_b side
            let (position_b: PerpPosition) = flip_position_side_internal(
                position_b, position_a.position_size, close_price, 0, funding_idx
            );

            let (is_valid, leverage) = get_current_leverage(position_b, close_price);

            let (leverage_scaler) = pow(10, global_config.leverage_decimals);
            let is_leverage_too_high = is_le(15 * leverage_scaler, leverage - 1);
            if (is_valid * is_leverage_too_high == 0) {
                // ? If position is liquidatable or the leverage is to high
                return (FALSE, position_b);
            }

            return (TRUE, position_b);
        }
    }
}

// * --------------------
func close_user_position{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
    fee_tracker_dict: DictAccess*,
}(position_a: PerpPosition, close_price: felt) -> (collateral_returned: felt) {
    alloc_locals;

    local funding_idx: felt;
    %{ ids.funding_idx = int(position_escape["new_funding_idx"]) %}

    let (nominal_collateral_amount: felt) = get_collateral_amount(
        position_a.position_header.synthetic_token, position_a.position_size, close_price
    );
    let (fee_taken, _) = unsigned_div_rem(nominal_collateral_amount * 5, 10000);  // 0.05%

    let (collateral_returned: felt) = close_position_internal(
        position_a, close_price, fee_taken, funding_idx
    );
    take_fee(global_config.collateral_token, fee_taken);

    return (collateral_returned,);
}

// * --------------------
func _hash_position_escape_message_open{
    range_check_ptr, keccak_ptr: felt*, bitwise_ptr: BitwiseBuiltin*
}(
    position_a: PerpPosition, close_price: felt, open_order_fields: OpenOrderFields, recipient: felt
) -> (res: felt) {
    alloc_locals;

    // & H = pedersen(position_a.hash, close_price, open_order_fields_b.hash, recipient)
    let (local arr: felt*) = alloc();

    let position_a_hash: felt = _hash_position_solidity(position_a);
    assert arr[0] = position_a_hash;
    assert arr[1] = close_price;
    let fields_hash: felt = _hash_open_order_fields_solidity(open_order_fields);
    assert arr[2] = fields_hash;
    assert arr[3] = recipient;

    let (res: Uint256) = cairo_keccak_felts_bigend(4, arr);

    let hash = res.high * 2 ** 128 + res.low;

    return (hash,);
}

func _hash_position_escape_message_close{
    range_check_ptr, keccak_ptr: felt*, bitwise_ptr: BitwiseBuiltin*
}(position_a: PerpPosition, close_price: felt, position_b: PerpPosition, recipient: felt) -> (
    res: felt
) {
    alloc_locals;

    // & H = pedersen(position_a.hash, close_price, position_b.hash, recipient)
    let (local arr: felt*) = alloc();

    let position_a_hash: felt = _hash_position_solidity(position_a);
    assert arr[0] = position_a_hash;
    assert arr[1] = close_price;
    let position_b_hash: felt = _hash_position_solidity(position_b);
    assert arr[2] = position_b_hash;
    assert arr[3] = recipient;

    let (res: Uint256) = cairo_keccak_felts_bigend(4, arr);

    let hash = res.high * 2 ** 128 + res.low;

    return (hash,);
}

func _hash_position_solidity{range_check_ptr, keccak_ptr: felt*, bitwise_ptr: BitwiseBuiltin*}(
    position: PerpPosition
) -> felt {
    alloc_locals;

    // & hash = H({allow_partial_liquidations, synthetic_token, position_address, vlp_token,
    // &           order_side, position_size, entry_price, liquidation_price, last_funding_idx, vlp_supply})
    let (local input_arr: felt*) = alloc();
    assert input_arr[0] = position.position_header.allow_partial_liquidations;
    assert input_arr[1] = position.position_header.synthetic_token;
    assert input_arr[2] = position.position_header.position_address;
    assert input_arr[3] = position.position_header.vlp_token;
    assert input_arr[5] = position.order_side;
    assert input_arr[6] = position.position_size;
    assert input_arr[7] = position.entry_price;
    assert input_arr[8] = position.liquidation_price;
    assert input_arr[9] = position.last_funding_idx;
    assert input_arr[10] = position.vlp_supply;

    let (res: Uint256) = cairo_keccak_felts_bigend(11, input_arr);

    let hash = res.high * 2 ** 128 + res.low;

    return hash;
}

func _hash_open_order_fields_solidity{
    range_check_ptr, keccak_ptr: felt*, bitwise_ptr: BitwiseBuiltin*
}(open_order_fields: OpenOrderFields) -> felt {
    alloc_locals;

    // & H = (note_hashes, refund_note_hash, initial_margin, collateral_token, position_address, allow_partial_liquidations)
    let (local empty_arr: felt*) = alloc();
    let (hashes_arr_len: felt, hashes_arr: felt*) = hash_notes_array_solidity(
        open_order_fields.notes_in_len, open_order_fields.notes_in, 0, empty_arr
    );
    let refund_note_hash: felt = _hash_note_inputs_solidity(open_order_fields.refund_note);
    assert hashes_arr[hashes_arr_len] = refund_note_hash;

    assert hashes_arr[hashes_arr_len + 1] = open_order_fields.initial_margin;
    assert hashes_arr[hashes_arr_len + 2] = open_order_fields.collateral_token;
    assert hashes_arr[hashes_arr_len + 3] = open_order_fields.position_address;
    assert hashes_arr[hashes_arr_len + 4] = open_order_fields.allow_partial_liquidations;

    let (res: Uint256) = cairo_keccak_felts_bigend(hashes_arr_len + 5, hashes_arr);

    let hash = res.high * 2 ** 128 + res.low;

    return hash;
}

// * -------------------- ------------------------- ---------------------- -----------------------
func update_state_after_open_swap{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(position_a: PerpPosition, open_order_fields: OpenOrderFields, new_position_b: PerpPosition) {
    alloc_locals;

    // ? Removes the position to the position dict and program output
    update_position_state_on_close(position_a.hash, position_a.index);

    // ? Remove notes
    update_state_dict(
        open_order_fields.notes_in_len, open_order_fields.notes_in, open_order_fields.refund_note
    );

    // ? Add the newly opened position
    update_position_state(0, new_position_b);

    return ();
}

func update_state_after_modfiy_swap{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(position_a: PerpPosition, prev_position_b_hash: felt, new_position_b: PerpPosition) {
    alloc_locals;

    // ? Removes the position to the position dict and program output
    update_position_state_on_close(position_a.hash, position_a.index);

    // ? Add the newly opened position
    update_position_state(prev_position_b_hash, new_position_b);

    return ();
}

// * --------------------
func are_signatures_valid_open{poseidon_ptr: PoseidonBuiltin*, ec_op_ptr: EcOpBuiltin*}(
    position_a: PerpPosition, open_order_fields: OpenOrderFields, escape_message_hash: felt
) -> (
    res: felt, signature_a_r: felt, signature_a_s: felt, signature_b_r: felt, signature_b_s: felt
) {
    alloc_locals;

    // * Verify signature a -----
    local signature_a_r: felt;
    local signature_a_s: felt;
    %{
        signature = position_escape["signature_a"]
        ids.signature_a_r = int(signature[0])
        ids.signature_a_s = int(signature[1])
    %}
    let (valid_a: felt) = is_signature_valid(
        escape_message_hash,
        position_a.position_header.position_address,
        signature_a_r,
        signature_a_s,
    );

    // * Verify signature b -----
    local signature_b_r: felt;
    local signature_b_s: felt;
    %{
        signature = position_escape["signature_b"]
        ids.signature_b_r = int(signature[0])
        ids.signature_b_s = int(signature[1])
    %}

    let (pub_key_sum: EcPoint) = sum_pub_keys(
        open_order_fields.notes_in_len, open_order_fields.notes_in, EcPoint(0, 0)
    );
    let (valid_b: felt) = is_signature_valid(
        escape_message_hash, pub_key_sum.x, signature_b_r, signature_b_s
    );

    return (valid_a * valid_b, signature_a_r, signature_a_s, signature_b_r, signature_b_s);  // true AND true
}

// * --------------------
func are_signatures_valid_close{poseidon_ptr: PoseidonBuiltin*, ec_op_ptr: EcOpBuiltin*}(
    position_a: PerpPosition, position_b: PerpPosition, escape_message_hash: felt
) -> (
    res: felt, signature_a_r: felt, signature_a_s: felt, signature_b_r: felt, signature_b_s: felt
) {
    alloc_locals;

    // * Verify signature a -----
    local signature_a_r: felt;
    local signature_a_s: felt;
    %{
        signature = position_escape["signature_a"]
        ids.signature_a_r = int(signature[0])
        ids.signature_a_s = int(signature[1])
    %}
    let (valid_a: felt) = is_signature_valid(
        escape_message_hash,
        position_a.position_header.position_address,
        signature_a_r,
        signature_a_s,
    );

    // * Verify signature b -----
    local signature_b_r: felt;
    local signature_b_s: felt;
    %{
        signature = position_escape["signature_b"]
        ids.signature_b_r = int(signature[0])
        ids.signature_b_s = int(signature[1])
    %}

    let (valid_b: felt) = is_signature_valid(
        escape_message_hash,
        position_b.position_header.position_address,
        signature_b_r,
        signature_b_s,
    );

    return (valid_a * valid_b, signature_a_r, signature_a_s, signature_b_r, signature_b_s);  // true AND true
}

// -------------------------------------------
func verify_synthetic_token{global_config: GlobalConfig*}(synthetic_token: felt) -> felt {
    let is_valid = _verify_synthetic_token_inner(
        global_config.synthetic_assets_len, global_config.synthetic_assets, synthetic_token
    );

    return is_valid;
}

func _verify_synthetic_token_inner(
    synthetic_assets_len: felt, synthetic_assets: felt*, synthetic_token: felt
) -> felt {
    alloc_locals;
    if (synthetic_assets_len == 0) {
        return FALSE;
    }

    if (synthetic_assets[0] == synthetic_token) {
        return TRUE;
    }

    return _verify_synthetic_token_inner(
        synthetic_assets_len - 1, &synthetic_assets[1], synthetic_token
    );
}
