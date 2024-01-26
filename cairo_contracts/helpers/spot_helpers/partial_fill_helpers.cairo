from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict import dict_new, dict_write, dict_update, dict_squash, dict_read
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.merkle_multi_update import merkle_multi_update
from starkware.cairo.common.ec_point import EcPoint
from starkware.cairo.common.uint256 import Uint256
from starkware.cairo.common.math import unsigned_div_rem, assert_le
from starkware.cairo.common.math_cmp import is_le

from invisible_swaps.order.invisible_order import Invisibl3Order

from helpers.utils import Note, construct_new_note, sum_notes, validate_fee_taken

func refund_partial_fill{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(order: Invisibl3Order, address_x: felt, address_y: felt, blinding: felt, unspent_amount: felt) {
    //

    let (pfr_note: Note) = partial_fill_updates(
        order, address_x, address_y, blinding, unspent_amount
    );

    // * Update the note dict with the new notes

    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = pfr_note.index;
    assert state_dict_ptr.prev_value = 0;
    assert state_dict_ptr.new_value = pfr_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    // ? store to an array used for program outputs
    assert note_updates[0] = pfr_note;
    let note_updates = &note_updates[1];

    %{ leaf_node_types[ids.pfr_note.index] = "note" %}
    %{
        note_output_idxs[ids.pfr_note.index] = note_outputs_len 
        note_outputs_len += 1
    %}

    return ();
}

func partial_fill_updates{poseidon_ptr: PoseidonBuiltin*}(
    invisible_order: Invisibl3Order,
    address_x: felt,
    address_y: felt,
    blinding: felt,
    unspent_amount: felt,
) -> (pf_note: Note) {
    alloc_locals;

    local new_fill_refund_note_idx: felt;
    %{ ids.new_fill_refund_note_idx = order_indexes["partial_fill_idx"] %}

    // ? This is the refund note of the leftover amount that wasn't spent in the swap
    let (partial_fill_note: Note) = construct_new_note(
        address_x,
        address_y,
        invisible_order.token_spent,
        unspent_amount,
        blinding,
        new_fill_refund_note_idx,
    );

    return (partial_fill_note,);
}

// ========================================================================================
