// %builtins output pedersen range_check

from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.math import assert_le
from starkware.cairo.common.math_cmp import is_le

from helpers.utils import Note, construct_new_note
from helpers.signatures import verify_close_order_tab_signature

from perpetuals.order.order_structs import CloseOrderFields

from rollup.global_config import GlobalConfig, get_dust_amount

from order_tabs.order_tab import OrderTab, TabHeader, verify_order_tab_hash, hash_order_tab_inner
from order_tabs.update_dicts import (
    close_tab_note_state_updates,
    remove_tab_from_state,
    update_tab_in_state,
)

func close_order_tab{
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

    local base_close_order_fields: CloseOrderFields;
    local quote_close_order_fields: CloseOrderFields;
    get_close_order_fields(&base_close_order_fields, &quote_close_order_fields);

    local base_amount_change: felt;
    local quote_amount_change: felt;
    %{
        ids.base_amount_change = int(current_order["base_amount_change"])
        ids.quote_amount_change = int(current_order["quote_amount_change"])
    %}

    with_attr error_message("ORDER TAB HASH IS INVALID") {
        verify_order_tab_hash(order_tab);
    }

    // ? Verify the signature
    verify_close_order_tab_signature(
        order_tab.hash,
        base_amount_change,
        quote_amount_change,
        base_close_order_fields,
        quote_close_order_fields,
        order_tab.tab_header.pub_key,
    );

    let base_token = order_tab.tab_header.base_token;
    let quote_token = order_tab.tab_header.quote_token;

    with_attr error_message("AMOUNT TO CLOSE TO LARGE FOR ORDER TAB AMOUNT") {
        assert_le(base_amount_change, order_tab.base_amount);
        assert_le(quote_amount_change, order_tab.quote_amount);
    }

    local base_idx: felt;
    local quote_idx: felt;
    %{
        ids.base_idx = current_order ["base_return_note_idx"]
        ids.quote_idx = current_order ["quote_return_note_idx"]
    %}

    let (base_return_note: Note) = construct_new_note(
        base_close_order_fields.dest_received_address,
        base_token,
        base_amount_change,
        base_close_order_fields.dest_received_blinding,
        base_idx,
    );

    let (quote_return_note: Note) = construct_new_note(
        quote_close_order_fields.dest_received_address,
        quote_token,
        quote_amount_change,
        quote_close_order_fields.dest_received_blinding,
        quote_idx,
    );

    let (base_dust_amount) = get_dust_amount(base_token);
    let (quote_dust_amount) = get_dust_amount(quote_token);
    let is_closable_1 = is_le(order_tab.base_amount - base_amount_change, base_dust_amount);
    let is_closable_2 = is_le(order_tab.quote_amount - quote_amount_change, quote_dust_amount);
    let is_closable = is_closable_1 * is_closable_2;

    // ? Update the state dicts
    close_tab_note_state_updates(base_return_note, quote_return_note);

    if (is_closable == 1) {
        // ? Position is closable

        // ? Update the tab dict
        remove_tab_from_state(order_tab);

        return ();
    } else {

        // ? Update the order tab
        let updated_base_amount = order_tab.base_amount - base_amount_change;
        let updated_quote_amount = order_tab.quote_amount - quote_amount_change;

        let updated_tab_hash = hash_order_tab_inner(
            order_tab.tab_header, updated_base_amount, updated_quote_amount
        );

        // ? Update the tab dict
        update_tab_in_state(order_tab, updated_base_amount, updated_quote_amount, updated_tab_hash);

        return ();
    }
}

func handle_order_tab_input{poseidon_ptr: PoseidonBuiltin*}(order_tab: OrderTab*) {
    %{
        order_tab_addr = ids.order_tab.address_
        tab_header_addr = order_tab_addr + ids.OrderTab.tab_header

        memory[order_tab_addr + ids.OrderTab.tab_idx] = int(order_tab_input["tab_idx"])
        memory[order_tab_addr + ids.OrderTab.base_amount] = int(order_tab_input["base_amount"])
        memory[order_tab_addr + ids.OrderTab.quote_amount] = int(order_tab_input["quote_amount"])
        memory[order_tab_addr + ids.OrderTab.hash] = int(order_tab_input["hash"])

        tab_header = order_tab_input["tab_header"]
        memory[tab_header_addr + ids.TabHeader.base_token] = int(tab_header["base_token"])
        memory[tab_header_addr +  ids.TabHeader.quote_token] = int(tab_header["quote_token"])
        memory[tab_header_addr + ids.TabHeader.base_blinding] = int(tab_header["base_blinding"])
        memory[tab_header_addr + ids.TabHeader.quote_blinding] = int(tab_header["quote_blinding"])
        memory[tab_header_addr + ids.TabHeader.pub_key] = int(tab_header["pub_key"])
        memory[tab_header_addr + ids.TabHeader.hash] = int(tab_header["hash"])
    %}

    return ();
}

func get_close_order_fields{poseidon_ptr: PoseidonBuiltin*}(
    base_close_order_fields: CloseOrderFields*, quote_close_order_fields: CloseOrderFields*
) {
    %{
        base_close_order_field_inputs = current_order["base_close_order_fields"]
        quote_close_order_field_inputs = current_order["quote_close_order_fields"]

        memory[ids.base_close_order_fields.address_ + ids.CloseOrderFields.dest_received_address] = int(base_close_order_field_inputs["dest_received_address"]["x"])
        memory[ids.base_close_order_fields.address_ + ids.CloseOrderFields.dest_received_blinding] = int(base_close_order_field_inputs["dest_received_blinding"])

        memory[ids.quote_close_order_fields.address_ + ids.CloseOrderFields.dest_received_address] = int(quote_close_order_field_inputs["dest_received_address"]["x"])
        memory[ids.quote_close_order_fields.address_ + ids.CloseOrderFields.dest_received_blinding] = int(quote_close_order_field_inputs["dest_received_blinding"])
    %}

    return ();
}
