from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.math import assert_le, unsigned_div_rem, assert_not_equal
from starkware.cairo.common.pow import pow
from starkware.cairo.common.hash_state import (
    hash_init,
    hash_finalize,
    hash_update,
    hash_update_single,
)
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.ec import EcPoint

from rollup.global_config import price_decimals, token_decimals, GlobalConfig

struct Note {
    address: EcPoint,
    token: felt,
    amount: felt,
    blinding_factor: felt,
    index: felt,
    hash: felt,
}

func hash_note{pedersen_ptr: HashBuiltin*}(note: Note) -> (hash: felt) {
    alloc_locals;

    let (note_hash: felt) = _hash_note_inputs(
        note.address, note.token, note.amount, note.blinding_factor
    );

    assert note_hash = note.hash;

    return (note_hash,);
}

func hash_notes_array{pedersen_ptr: HashBuiltin*}(
    notes_len: felt, notes: Note*, arr_len: felt, arr: felt*
) -> (arr_len: felt, arr: felt*) {
    alloc_locals;
    if (notes_len == 0) {
        return (arr_len, arr);
    }

    let (note_hash: felt) = hash_note(notes[0]);

    assert arr[arr_len] = note_hash;

    return hash_notes_array(notes_len - 1, &notes[1], arr_len + 1, arr);
}

// & This function is used to generate a hash of a new note before actually creating the note
func _hash_note_inputs{pedersen_ptr: HashBuiltin*}(
    address: EcPoint, token: felt, amount: felt, blinding_factor: felt
) -> (hash: felt) {
    if (amount == 0) {
        return (0,);
    }

    let (commitment: felt) = hash2{hash_ptr=pedersen_ptr}(amount, blinding_factor);

    let hash_ptr = pedersen_ptr;
    with hash_ptr {
        let (hash_state_ptr) = hash_init();
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, address.x);
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, token);
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, commitment);

        let (res) = hash_finalize(hash_state_ptr);
        let pedersen_ptr = hash_ptr;
        return (hash=res);
    }
}

func sum_notes(notes_len: felt, notes: Note*, token: felt, sum: felt) -> (sum: felt) {
    alloc_locals;

    if (notes_len == 0) {
        return (sum,);
    }

    let note: Note = notes[0];
    assert note.token = token;

    let sum = sum + note.amount;

    return sum_notes(notes_len - 1, &notes[1], token, sum);
}

func construct_new_note{pedersen_ptr: HashBuiltin*}(
    address_x: felt, token: felt, amount: felt, blinding_factor: felt, index: felt
) -> (note: Note) {
    alloc_locals;

    let address = EcPoint(x=address_x, y=0);

    let (note_hash: felt) = _hash_note_inputs(address, token, amount, blinding_factor);

    let new_note: Note = Note(
        address=address,
        token=token,
        amount=amount,
        blinding_factor=blinding_factor,
        index=index,
        hash=note_hash,
    );

    return (new_note,);
}

func get_zero_note{pedersen_ptr: HashBuiltin*}(index: felt) -> (note: Note) {
    alloc_locals;

    let address = EcPoint(x=0, y=0);

    let zero_note: Note = Note(
        address=address, token=0, amount=0, blinding_factor=0, index=index, hash=0
    );

    return (zero_note,);
}

// * ================================================================================

func check_index_uniqueness{range_check_ptr}(notes_in_len: felt, notes_in: Note*) {
    if (notes_in_len == 1) {
        return ();
    }

    let idx = notes_in[0].index;

    _check_index_uniqueness_internal(notes_in_len - 1, &notes_in[1], idx);

    return check_index_uniqueness(notes_in_len - 1, &notes_in[1]);
}

func _check_index_uniqueness_internal{range_check_ptr}(
    notes_in_len: felt, notes_in: Note*, idx: felt
) {
    if (notes_in_len == 0) {
        return ();
    }

    let note = notes_in[0];

    assert_not_equal(note.index, idx);

    return _check_index_uniqueness_internal(notes_in_len - 1, &notes_in[1], idx);
}

func concat_arrays{output_ptr, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    arr1_len: felt, arr1: felt*, arr2_len: felt, arr2: felt*
) -> (arr_len: felt, arr: felt*) {
    alloc_locals;
    if (arr2_len == 0) {
        return (arr1_len, arr1);
    }

    assert arr1[arr1_len] = arr2[0];

    return concat_arrays(arr1_len + 1, arr1, arr2_len - 1, &arr2[1]);
}

// * ================================================================

func take_fee{fee_tracker_dict: DictAccess*}(token_received: felt, fee_taken: felt) {
    alloc_locals;

    local prev_fee_sum: felt;
    %{
        try:
            prev_fee_sum = fee_tracker_dict_manager[ids.token_received]
        except KeyError:
            prev_fee_sum = 0

        fee_tracker_dict_manager[ids.token_received] = prev_fee_sum + ids.fee_taken
        ids.prev_fee_sum = prev_fee_sum
    %}

    let fee_tracker_dict_ptr: DictAccess* = fee_tracker_dict;
    assert fee_tracker_dict_ptr.key = token_received;
    assert fee_tracker_dict_ptr.prev_value = prev_fee_sum;
    assert fee_tracker_dict_ptr.new_value = prev_fee_sum + fee_taken;

    let fee_tracker_dict = fee_tracker_dict + DictAccess.SIZE;

    return ();
}

func validate_fee_taken{range_check_ptr}(
    fee_taken: felt, fee_limit: felt, actual_received_amount: felt, order_received_amount: felt
) {
    tempvar x = fee_taken * order_received_amount;
    tempvar y = fee_limit * actual_received_amount;
    assert_le(x, y);
    return ();
}

// * =================================

func get_price{range_check_ptr, global_config: GlobalConfig*}(
    synthetic_token: felt, collateral_amount: felt, synthetic_amount: felt
) -> (price: felt) {
    alloc_locals;

    let (synthetic_decimals: felt) = token_decimals(synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(synthetic_token);

    tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals - 6;
    let (multiplier: felt) = pow(10, decimal_conversion);

    let (price: felt, _) = unsigned_div_rem(collateral_amount * multiplier, synthetic_amount);

    return (price,);
}


