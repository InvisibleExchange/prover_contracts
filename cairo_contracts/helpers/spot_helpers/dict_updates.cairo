from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict import dict_new, dict_write, dict_update, dict_squash, dict_read
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.merkle_multi_update import merkle_multi_update
from starkware.cairo.common.math import unsigned_div_rem, assert_le
from starkware.cairo.common.math_cmp import is_le

from invisible_swaps.order.invisible_order import Invisibl3Order
from helpers.utils import (
    Note,
    construct_new_note,
    sum_notes,
    hash_note,
    validate_fee_taken,
    get_zero_note,
)

// ! NOTE DICT UPDATES FOR SWAPS =====================================================

func update_state_dict{pedersen_ptr: HashBuiltin*, state_dict: DictAccess*, note_updates: Note*}(
    notes_in_len: felt, notes_in: Note*, refund_note: Note, swap_note: Note
) {
    alloc_locals;

    if (notes_in_len == 1) {
        let note_in = notes_in[0];
        return update_one(note_in, refund_note, swap_note);
    }
    if (notes_in_len == 2) {
        let note_in1 = notes_in[0];
        let note_in2 = notes_in[1];
        return update_two(note_in1, note_in2, refund_note, swap_note);
    }

    return update_multi(notes_in_len, notes_in, refund_note, swap_note);
}

func update_one{pedersen_ptr: HashBuiltin*, state_dict: DictAccess*, note_updates: Note*}(
    note_in: Note, refund_note: Note, swap_note: Note
) {
    // * --- --- --- --- ---
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

    // * --- --- --- --- ---
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = swap_note.index;
    assert state_dict_ptr.prev_value = 0;
    assert state_dict_ptr.new_value = swap_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    // ? store to an array used for program outputs
    assert note_updates[0] = swap_note;
    let note_updates = &note_updates[1];

    %{ leaf_node_types[ids.swap_note.index] = "note" %}
    %{
        note_output_idxs[ids.swap_note.index] = note_outputs_len 
        note_outputs_len += 1
    %}

    return ();
}

func update_two{pedersen_ptr: HashBuiltin*, state_dict: DictAccess*, note_updates: Note*}(
    note_in1: Note, note_in2: Note, refund_note: Note, swap_note: Note
) {
    // * --- --- --- --- ---
    let state_dict_ptr = state_dict;
    state_dict_ptr.key = note_in1.index;
    state_dict_ptr.prev_value = note_in1.hash;
    state_dict_ptr.new_value = refund_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;
    %{ leaf_node_types[ids.note_in1.index] = "note" %}

    // ? store to an array used for program outputs
    if (refund_note.hash != 0) {
        %{
            note_output_idxs[ids.note_in1.index] = note_outputs_len 
            note_outputs_len += 1
        %}

        assert note_updates[0] = refund_note;
        let note_updates = &note_updates[1];

        return ();
    }

    // * --- --- --- --- ---
    let state_dict_ptr = state_dict;
    state_dict_ptr.key = swap_note.index;
    state_dict_ptr.prev_value = note_in2.hash;
    state_dict_ptr.new_value = swap_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    // ? store to an array used for program outputs
    assert note_updates[0] = swap_note;
    let note_updates = &note_updates[1];

    %{ leaf_node_types[ids.swap_note.index] = "note" %}
    %{
        note_output_idxs[ids.swap_note.index] = note_outputs_len 
        note_outputs_len += 1
    %}

    return ();
}

func update_multi{pedersen_ptr: HashBuiltin*, state_dict: DictAccess*, note_updates: Note*}(
    notes_in_len: felt, notes_in: Note*, refund_note: Note, swap_note: Note
) {
    let note_in1: Note = notes_in[0];
    let note_in2: Note = notes_in[1];

    update_two(note_in1, note_in2, refund_note, swap_note);

    return _update_multi_inner(notes_in_len - 2, &notes_in[2]);
}

func _update_multi_inner{pedersen_ptr: HashBuiltin*, state_dict: DictAccess*, note_updates: Note*}(
    notes_in_len: felt, notes_in: Note*
) {
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

// ! NOTE DICT UPDATES FOR DEPOSITS AND WITHDRAWALS =====================================================

func deposit_state_dict_updates{
    pedersen_ptr: HashBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(deposit_notes_len: felt, deposit_notes: Note*) {
    if (deposit_notes_len == 0) {
        return ();
    }

    // * Update the note dict
    let deposit_note: Note = deposit_notes[0];

    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = deposit_note.index;
    assert state_dict_ptr.prev_value = 0;
    assert state_dict_ptr.new_value = deposit_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    // ? store to an array used for program outputs
    assert note_updates[0] = deposit_note;
    let note_updates = &note_updates[1];

    %{ leaf_node_types[ids.deposit_note.index] = "note" %}
    %{
        note_output_idxs[ids.deposit_note.index] = note_outputs_len 
        note_outputs_len += 1
    %}

    return deposit_state_dict_updates(deposit_notes_len - 1, &deposit_notes[1]);
}

func withdraw_state_dict_updates{
    pedersen_ptr: HashBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(withdraw_notes_len: felt, withdraw_notes: Note*, refund_note: Note) {
    if (withdraw_notes_len == 0) {
        return ();
    }

    _update_one_withdraw(withdraw_notes[0], refund_note);
    return _update_multi_inner_withdraw(withdraw_notes_len - 1, &withdraw_notes[1]);
}

func _update_one_withdraw{pedersen_ptr: HashBuiltin*, state_dict: DictAccess*, note_updates: Note*}(
    note_in: Note, refund_note: Note
) {
    // * Update the note dict
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = note_in.index;
    assert state_dict_ptr.prev_value = note_in.hash;
    assert state_dict_ptr.new_value = refund_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;
    %{ leaf_node_types[ids.note_in.index] = "note" %}

    if (refund_note.hash != 0) {
        %{
            note_output_idxs[ids.note_in.index] = note_outputs_len 
            note_outputs_len += 1
        %}

        // ? store to an array used for program outputs
        assert note_updates[0] = refund_note;
        let note_updates = &note_updates[1];

        return ();
    }

    return ();
}

func _update_multi_inner_withdraw{
    pedersen_ptr: HashBuiltin*, state_dict: DictAccess*, note_updates: Note*
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
