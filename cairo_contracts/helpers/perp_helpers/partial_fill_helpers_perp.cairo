from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict import dict_new, dict_write, dict_update, dict_squash, dict_read
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.ec_point import EcPoint
from starkware.cairo.common.math import unsigned_div_rem, assert_le
from starkware.cairo.common.math_cmp import is_le

from helpers.utils import Note, construct_new_note, sum_notes
from perpetuals.order.order_structs import PerpOrder

func refund_partial_fill{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(
    order: PerpOrder,
    address_x: felt,
    address_y: felt,
    blinding: felt,
    collateral_token: felt,
    unspent_margin: felt,
) {
    let (pfr_note: Note) = partial_fill_updates(
        order, address_x, address_y, blinding, collateral_token, unspent_margin
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

func partial_fill_updates{poseidon_ptr: PoseidonBuiltin*, note_updates: Note*}(
    order: PerpOrder,
    address_x: felt,
    address_y: felt,
    blinding: felt,
    token: felt,
    unspent_margin: felt,
) -> (pfr_note: Note) {
    alloc_locals;

    // pfr_note -> refund partial fill note
    local new_pfr_note_idx: felt;
    %{ ids.new_pfr_note_idx = order_indexes["new_pfr_idx"] %}

    // Todo: change dummy blinding factor
    let (pfr_note: Note) = construct_new_note(
        address_x, address_y, token, unspent_margin, blinding, new_pfr_note_idx
    );

    return (pfr_note,);
}

func remove_prev_pfr_note{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(prev_pfr_note: Note) {
    alloc_locals;

    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = prev_pfr_note.index;
    assert state_dict_ptr.prev_value = prev_pfr_note.hash;
    assert state_dict_ptr.new_value = 0;

    let state_dict = state_dict + DictAccess.SIZE;

    %{ leaf_node_types[ids.prev_pfr_note.index] = "note" %}

    return ();
}
