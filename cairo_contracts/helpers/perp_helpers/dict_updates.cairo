from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict import dict_new, dict_write, dict_update, dict_squash, dict_read
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.merkle_multi_update import merkle_multi_update
from starkware.cairo.common.math import unsigned_div_rem, assert_le
from starkware.cairo.common.math_cmp import is_le

from perpetuals.order.order_structs import PerpOrder, PerpPosition, PositionHeader
from helpers.utils import Note

func update_state_dict{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(notes_in_len: felt, notes_in: Note*, refund_note: Note) {
    alloc_locals;

    let note_in = notes_in[0];
    update_one(note_in, refund_note);

    if (notes_in_len == 1) {
        return ();
    }

    return _update_multi_inner(notes_in_len - 1, &notes_in[1]);
}

func update_one{poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*}(
    note_in: Note, refund_note: Note
) {
    // * Update the note dict
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = note_in.index;
    assert state_dict_ptr.prev_value = note_in.hash;
    assert state_dict_ptr.new_value = refund_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;
    %{ leaf_node_types[ids.note_in.index] = "note" %}

    // ? store to an array used for program outputs
    if (refund_note.hash != 0) {
        %{
            note_output_idxs[ids.note_in.index] = note_outputs_len 
            note_outputs_len += 1
        %}

        assert note_updates[0] = refund_note;
        let note_updates = &note_updates[1];

        return ();
    }

    %{ leaf_node_types[ids.note_in.index] = "note" %}

    return ();
}

func _update_multi_inner{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(notes_in_len: felt, notes_in: Note*) {
    if (notes_in_len == 0) {
        return ();
    }

    // * Update the note dict
    let note_in: Note = notes_in[0];

    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = note_in.index;
    assert state_dict_ptr.prev_value = note_in.hash;
    assert state_dict_ptr.new_value = 0;

    let state_dict = state_dict + DictAccess.SIZE;

    %{ leaf_node_types[ids.note_in.index] = "note" %}

    return _update_multi_inner(notes_in_len - 1, &notes_in[1]);
}

func update_rc_state_dict{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(rc_note: Note) {
    // * Update the note dict
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = rc_note.index;
    assert state_dict_ptr.prev_value = 0;
    assert state_dict_ptr.new_value = rc_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    // ? store to an array used for program outputs
    assert note_updates[0] = rc_note;
    let note_updates = &note_updates[1];

    %{ leaf_node_types[ids.rc_note.index] = "note" %}
    %{
        note_output_idxs[ids.rc_note.index] = note_outputs_len 
        note_outputs_len += 1
    %}

    return ();
}

// * UPDATE

func update_position_state{poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*}(
    prev_position_hash: felt, position: PerpPosition
) {
    // * Update the position dict
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = position.index;
    assert state_dict_ptr.prev_value = prev_position_hash;
    assert state_dict_ptr.new_value = position.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    %{ leaf_node_types[ids.position.index] = "position" %}

    %{ store_output_position(ids.position.address_, ids.position.index) %}

    return ();
}

func update_position_state_on_close{poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*}(
    prev_position_hash: felt, idx: felt
) {
    // * Update the note dict
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = idx;
    assert state_dict_ptr.prev_value = prev_position_hash;
    assert state_dict_ptr.new_value = 0;

    %{ leaf_node_types[ids.idx] = "position" %}

    let state_dict = state_dict + DictAccess.SIZE;

    return ();
}
