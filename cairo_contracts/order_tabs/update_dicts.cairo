from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.dict_access import DictAccess

from helpers.utils import Note
from helpers.spot_helpers.dict_updates import _update_multi_inner

from order_tabs.order_tab import OrderTab

func open_tab_state_note_updates{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(
    base_notes_in_len: felt,
    base_notes_in: Note*,
    quote_notes_in_len: felt,
    quote_notes_in: Note*,
    base_refund_note: Note,
    quote_refund_note: Note,
) {
    alloc_locals;

    // ? Remove the notes from the state
    _update_multi_inner(base_notes_in_len, base_notes_in);
    _update_multi_inner(quote_notes_in_len, quote_notes_in);

    // ? add the refund notes
    if (base_refund_note.hash != 0) {
        add_refund_note(base_notes_in[0].index, base_refund_note);

        if (quote_refund_note.hash != 0) {
            add_refund_note(quote_notes_in[0].index, quote_refund_note);
            return ();
        } else {
            return ();
        }
    } else {
        if (quote_refund_note.hash != 0) {
            add_refund_note(quote_notes_in[0].index, quote_refund_note);

            return ();
        } else {
            return ();
        }
    }
}

func add_refund_note{poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*}(
    index: felt, refund_note: Note
) {
    alloc_locals;

    // * Update the note dict
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = index;
    assert state_dict_ptr.prev_value = 0;
    assert state_dict_ptr.new_value = refund_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    // ? store to an array used for program outputs
    %{ leaf_node_types[ids.index] = "note" %}
    %{
        note_output_idxs[ids.index] = note_outputs_len 
        note_outputs_len += 1
    %}

    assert note_updates[0] = refund_note;
    let note_updates = &note_updates[1];

    return ();
}

func close_tab_note_state_updates{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(base_return_note: Note, quote_return_note: Note) {
    // * Update the note dict
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = base_return_note.index;
    assert state_dict_ptr.prev_value = 0;
    assert state_dict_ptr.new_value = base_return_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    // ? store to an array used for program outputs
    assert note_updates[0] = base_return_note;
    let note_updates = &note_updates[1];

    %{ leaf_node_types[ids.base_return_note.index] = "note" %}
    %{
        note_output_idxs[ids.base_return_note.index] = note_outputs_len 
        note_outputs_len += 1
    %}

    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = quote_return_note.index;
    assert state_dict_ptr.prev_value = 0;
    assert state_dict_ptr.new_value = quote_return_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    // ? store to an array used for program outputs
    assert note_updates[0] = quote_return_note;
    let note_updates = &note_updates[1];

    %{ leaf_node_types[ids.quote_return_note.index] = "note" %}
    %{
        note_output_idxs[ids.quote_return_note.index] = note_outputs_len 
        note_outputs_len += 1
    %}

    return ();
}

// ? ORDER TAB UPDATES ===================================================
func add_new_tab_to_state{poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*}(
    order_tab: OrderTab
) {
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = order_tab.tab_idx;
    assert state_dict_ptr.prev_value = 0;
    assert state_dict_ptr.new_value = order_tab.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    %{ leaf_node_types[ids.order_tab.tab_idx] = "order_tab" %}
    %{ store_output_order_tab(ids.order_tab.address_, ids.order_tab.tab_idx, ids.order_tab.base_amount, ids.order_tab.quote_amount, ids.order_tab.vlp_supply, ids.order_tab.hash ) %}

    return ();
}

func remove_tab_from_state{poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*}(
    order_tab: OrderTab
) {
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = order_tab.tab_idx;
    assert state_dict_ptr.prev_value = order_tab.hash;
    assert state_dict_ptr.new_value = 0;

    let state_dict = state_dict + DictAccess.SIZE;

    %{ leaf_node_types[ids.order_tab.tab_idx] = "order_tab" %}

    return ();
}

func update_tab_in_state{poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*}(
    prev_order_tab: OrderTab, new_base_amount: felt, new_quote_amount: felt, updated_tab_hash: felt
) {
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = prev_order_tab.tab_idx;
    assert state_dict_ptr.prev_value = prev_order_tab.hash;
    assert state_dict_ptr.new_value = updated_tab_hash;

    let state_dict = state_dict + DictAccess.SIZE;

    %{ leaf_node_types[ids.prev_order_tab.tab_idx] = "order_tab" %}
    %{ store_output_order_tab(ids.prev_order_tab.address_, ids.prev_order_tab.tab_idx, ids.new_base_amount, ids.new_quote_amount, ids.prev_order_tab.vlp_supply, ids.updated_tab_hash) %}

    return ();
}
