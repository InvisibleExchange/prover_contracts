// %builtins output pedersen range_check

from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict_access import DictAccess

from helpers.utils import Note, sum_notes
from helpers.signatures import verify_open_order_tab_signature

from rollup.global_config import GlobalConfig

from order_tabs.order_tab import OrderTab, verify_order_tab_hash, hash_order_tab_inner
from order_tabs.update_dicts import (
    open_tab_state_note_updates,
    add_new_tab_to_state,
    update_tab_in_state,
)
from order_tabs.close_order_tab import handle_order_tab_input

func open_order_tab{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    fee_tracker_dict: DictAccess*,
    global_config: GlobalConfig*,
}() {
    alloc_locals;

    let (__fp__, _) = get_fp_and_pc();

    // ? Handle inputs
    %{ order_tab_input = current_order["order_tab"] %}
    local order_tab: OrderTab;
    handle_order_tab_input(&order_tab);

    local base_notes_in_len: felt;
    local base_notes_in: Note*;
    local base_refund_note: Note;
    local quote_notes_in_len: felt;
    local quote_notes_in: Note*;
    local quote_refund_note: Note;
    handle_inputs(
        &base_notes_in_len,
        &base_notes_in,
        &base_refund_note,
        &quote_notes_in_len,
        &quote_notes_in,
        &quote_refund_note,
    );

    local add_only: felt;
    %{ ids.add_only = current_order["add_only"] %}

    // ?
    let (base_amounts_sum: felt) = sum_notes(
        base_notes_in_len, base_notes_in, order_tab.tab_header.base_token, 0
    );
    let base_refund_note_amount = base_refund_note.amount;
    if (base_refund_note.hash != 0) {
        assert base_refund_note.index = base_notes_in[0].index;
    }

    let (quote_amounts_sum: felt) = sum_notes(
        quote_notes_in_len, quote_notes_in, order_tab.tab_header.quote_token, 0
    );
    let quote_refund_note_amount = quote_refund_note.amount;
    if (quote_refund_note.hash != 0) {
        assert quote_refund_note.index = quote_notes_in[0].index;
    }

    let base_amount = base_amounts_sum - base_refund_note_amount;
    let quote_amount = quote_amounts_sum - quote_refund_note_amount;

    with_attr error_message("ORDER TAB HASH IS INVALID") {
        verify_order_tab_hash(order_tab);
    }

    // ? Update the dictionaries
    open_tab_state_note_updates(
        base_notes_in_len,
        base_notes_in,
        quote_notes_in_len,
        quote_notes_in,
        base_refund_note,
        quote_refund_note,
    );

    if (add_only == 1) {
        // & ADDING TO EXISTING ORDER TAB
        let prev_tab_hash = order_tab.hash;

        let updated_base_amount = order_tab.base_amount + base_amount;
        let updated_quote_amount = order_tab.quote_amount + quote_amount;

        let updated_tab_hash = hash_order_tab_inner(
            order_tab.tab_header, updated_base_amount, updated_quote_amount, order_tab.vlp_supply
        );

        // ? Verify the signature
        verify_open_order_tab_signature(
            prev_tab_hash,
            updated_tab_hash,
            base_notes_in_len,
            base_notes_in,
            base_refund_note.hash,
            quote_notes_in_len,
            quote_notes_in,
            quote_refund_note.hash,
        );

        // ? Update the dictionaries
        update_tab_in_state(order_tab, updated_base_amount, updated_quote_amount, updated_tab_hash);

        return ();
    } else {
        // & OPENING NEW ORDER TAB
        with_attr error_message("INVALID AMOUNTS IN OPEN ORDER TAB") {
            assert base_amount = order_tab.base_amount;
            assert quote_amount = order_tab.quote_amount;
        }

        // ? Verify the signature
        verify_open_order_tab_signature(
            0,
            order_tab.hash,
            base_notes_in_len,
            base_notes_in,
            base_refund_note.hash,
            quote_notes_in_len,
            quote_notes_in,
            quote_refund_note.hash,
        );

        // ? Update the dictionaries
        add_new_tab_to_state(order_tab);

        return ();
    }
}

func handle_inputs{poseidon_ptr: PoseidonBuiltin*}(
    base_notes_in_len: felt*,
    base_notes_in: Note**,
    base_refund_note: Note*,
    quote_notes_in_len: felt*,
    quote_notes_in: Note**,
    quote_refund_note: Note*,
) {
    %{
        ##* BASE INPUT NOTES =============================================================
        input_notes = current_order["base_notes_in"]

        memory[ids.base_notes_in_len] = len(input_notes)
        memory[ids.base_notes_in] = notes_ = segments.add()
        for i in range(len(input_notes)):
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET+0] = int(input_notes[i]["address"]["x"])
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET+1] = int(input_notes[i]["address"]["y"])
            memory[notes_ + i* NOTE_SIZE + TOKEN_OFFSET] = int(input_notes[i]["token"])
            memory[notes_ + i* NOTE_SIZE + AMOUNT_OFFSET] = int(input_notes[i]["amount"])
            memory[notes_ + i* NOTE_SIZE + BLINDING_FACTOR_OFFSET] = int(input_notes[i]["blinding"])
            memory[notes_ + i* NOTE_SIZE + INDEX_OFFSET] = int(input_notes[i]["index"])
            memory[notes_ + i* NOTE_SIZE + HASH_OFFSET] = int(input_notes[i]["hash"])

        refund_note__  = current_order["base_refund_note"]
        if refund_note__ is not None:
            memory[ids.base_refund_note.address_ + ADDRESS_OFFSET+0] = int(refund_note__["address"]["x"])
            memory[ids.base_refund_note.address_ + ADDRESS_OFFSET+1] = int(refund_note__["address"]["y"])
            memory[ids.base_refund_note.address_ + TOKEN_OFFSET] = int(refund_note__["token"])
            memory[ids.base_refund_note.address_ + AMOUNT_OFFSET] = int(refund_note__["amount"])
            memory[ids.base_refund_note.address_ + BLINDING_FACTOR_OFFSET] = int(refund_note__["blinding"])
            memory[ids.base_refund_note.address_ + INDEX_OFFSET] = int(refund_note__["index"])
            memory[ids.base_refund_note.address_ + HASH_OFFSET] = int(refund_note__["hash"])
        else:
            memory[ids.base_refund_note.address_ + ADDRESS_OFFSET+0] = 0
            memory[ids.base_refund_note.address_ + ADDRESS_OFFSET+1] = 0
            memory[ids.base_refund_note.address_ + TOKEN_OFFSET] = 0
            memory[ids.base_refund_note.address_ + AMOUNT_OFFSET] = 0
            memory[ids.base_refund_note.address_ + BLINDING_FACTOR_OFFSET] = 0
            memory[ids.base_refund_note.address_ + INDEX_OFFSET] = 0
            memory[ids.base_refund_note.address_ + HASH_OFFSET] = 0


        ##* QUOTE INPUT NOTES =============================================================
        input_notes = current_order["quote_notes_in"]

        memory[ids.quote_notes_in_len] = len(input_notes)
        memory[ids.quote_notes_in] = notes_ = segments.add()
        for i in range(len(input_notes)):
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET+0] = int(input_notes[i]["address"]["x"])
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET+1] = int(input_notes[i]["address"]["y"])
            memory[notes_ + i* NOTE_SIZE + TOKEN_OFFSET] = int(input_notes[i]["token"])
            memory[notes_ + i* NOTE_SIZE + AMOUNT_OFFSET] = int(input_notes[i]["amount"])
            memory[notes_ + i* NOTE_SIZE + BLINDING_FACTOR_OFFSET] = int(input_notes[i]["blinding"])
            memory[notes_ + i* NOTE_SIZE + INDEX_OFFSET] = int(input_notes[i]["index"])
            memory[notes_ + i* NOTE_SIZE + HASH_OFFSET] = int(input_notes[i]["hash"])

        refund_note__  = current_order["quote_refund_note"]
        if refund_note__ is not None:
            memory[ids.quote_refund_note.address_ + ADDRESS_OFFSET+0] = int(refund_note__["address"]["x"])
            memory[ids.quote_refund_note.address_ + ADDRESS_OFFSET+1] = int(refund_note__["address"]["y"])
            memory[ids.quote_refund_note.address_ + TOKEN_OFFSET] = int(refund_note__["token"])
            memory[ids.quote_refund_note.address_ + AMOUNT_OFFSET] = int(refund_note__["amount"])
            memory[ids.quote_refund_note.address_ + BLINDING_FACTOR_OFFSET] = int(refund_note__["blinding"])
            memory[ids.quote_refund_note.address_ + INDEX_OFFSET] = int(refund_note__["index"])
            memory[ids.quote_refund_note.address_ + HASH_OFFSET] = int(refund_note__["hash"])
        else:
            memory[ids.quote_refund_note.address_ + ADDRESS_OFFSET+0] = 0
            memory[ids.quote_refund_note.address_ + ADDRESS_OFFSET+1] = 0
            memory[ids.quote_refund_note.address_ + TOKEN_OFFSET] = 0
            memory[ids.quote_refund_note.address_ + AMOUNT_OFFSET] = 0
            memory[ids.quote_refund_note.address_ + BLINDING_FACTOR_OFFSET] = 0
            memory[ids.quote_refund_note.address_ + INDEX_OFFSET] = 0
            memory[ids.quote_refund_note.address_ + HASH_OFFSET] = 0
    %}

    return ();
}
