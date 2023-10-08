from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin, BitwiseBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.math import assert_le
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.squash_dict import squash_dict

from helpers.utils import Note, construct_new_note
from helpers.signatures.signatures import verify_close_order_tab_signature

from perpetuals.order.order_structs import CloseOrderFields
from perpetuals.transaction.perp_transaction import get_perp_position

from rollup.output_structs import write_mm_registration_to_output, MMRegistrationOutput
from rollup.global_config import GlobalConfig, get_dust_amount

from order_tabs.order_tab import OrderTab, verify_order_tab_hash
from order_tabs.update_dicts import (
    close_tab_note_state_updates,
    remove_tab_from_state,
    update_tab_in_state,
)

from order_tabs.close_order_tab import handle_order_tab_input

from smart_contract_mms.register_mm_helpers import (
    verify_register_mm_sig,
    get_vlp_amount,
    get_updated_order_tab,
    get_updated_position,
    update_state_after_tab_register,
    update_state_after_position_register,
)

func register_mm{
    pedersen_ptr: HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    registration_output_ptr: MMRegistrationOutput*,
    note_updates: Note*,
    fee_tracker_dict: DictAccess*,
    global_config: GlobalConfig*,
}() {
    alloc_locals;

    let (__fp__, _) = get_fp_and_pc();

    if (nondet %{ current_order["is_order_tab"] == True %} != 0) {
        // * Order tab

        // ? get order tab, close order fields
        %{ order_tab_input = current_order["prev_order_tab"] %}
        local order_tab: OrderTab;
        handle_order_tab_input(&order_tab);

        local vlp_close_order_fields: CloseOrderFields;
        local vlp_token: felt;
        local max_vlp_supply: felt;
        local index_price: felt;
        %{
            vlp_close_order_field_inputs = current_order["vlp_close_order_fields"]

            memory[ids.vlp_close_order_fields.address_ + ids.CloseOrderFields.dest_received_address] = int(vlp_close_order_field_inputs["dest_received_address"]["x"])
            memory[ids.vlp_close_order_fields.address_ + ids.CloseOrderFields.dest_received_blinding] = int(vlp_close_order_field_inputs["dest_received_blinding"])

            ids.vlp_token = current_order["vlp_token"]
            ids.max_vlp_supply = current_order["max_vlp_supply"]
            ids.index_price = current_order["index_price"]
        %}

        // ? verify order_tab validity
        assert order_tab.tab_header.is_smart_contract = 0;
        verify_order_tab_hash(order_tab);

        // ? hash the inputs and verify signature
        verify_register_mm_sig(
            order_tab.tab_header.pub_key,
            order_tab.hash,
            vlp_token,
            max_vlp_supply,
            vlp_close_order_fields,
        );

        // ? calculate vlp amount
        let vlp_amount = get_vlp_amount(
            order_tab.tab_header.base_token,
            order_tab.base_amount,
            order_tab.quote_amount,
            index_price,
        );

        // ? update the order tab
        let updated_order_tab = get_updated_order_tab(
            order_tab, vlp_amount, vlp_token, max_vlp_supply
        );

        // ? construct the new vlp_note
        local vlp_index: felt;
        %{ ids.vlp_index = current_order["vlp_note_idx"] %}

        let (vlp_note) = construct_new_note(
            vlp_close_order_fields.dest_received_address,
            vlp_token,
            vlp_amount,
            vlp_close_order_fields.dest_received_blinding,
            vlp_index,
        );

        // ? update the state_dict
        update_state_after_tab_register(vlp_note, order_tab, updated_order_tab);

        // ? update the output
        write_mm_registration_to_output(order_tab.tab_header.pub_key, vlp_token, max_vlp_supply, 0);

        return ();
    } else {
        // * Position

        // ? get position, close order fields
        %{ prev_position = current_order["prev_position"] %}
        let position = get_perp_position();

        local vlp_close_order_fields: CloseOrderFields;
        local vlp_token: felt;
        local max_vlp_supply: felt;
        %{
            vlp_close_order_field_inputs = current_order["vlp_close_order_fields"]

            memory[ids.vlp_close_order_fields.address_ + ids.CloseOrderFields.dest_received_address] = int(vlp_close_order_field_inputs["dest_received_address"]["x"])
            memory[ids.vlp_close_order_fields.address_ + ids.CloseOrderFields.dest_received_blinding] = int(vlp_close_order_field_inputs["dest_received_blinding"])

            ids.vlp_token = current_order["vlp_token"]
            ids.max_vlp_supply = current_order["max_vlp_supply"]
        %}

        // ? hash the inputs and verify signature
        verify_register_mm_sig(
            position.position_header.position_address,
            position.hash,
            vlp_token,
            max_vlp_supply,
            vlp_close_order_fields,
        );

        // ? get vlp amount
        let vlp_amount = position.margin;

        // ? update the position
        let new_position = get_updated_position(position, vlp_amount, vlp_token, max_vlp_supply);

        %{ print(ids.new_position.hash) %}

        // ? construct the new vlp_note
        local vlp_index: felt;
        %{ ids.vlp_index = current_order["vlp_note_idx"] %}

        let (vlp_note) = construct_new_note(
            vlp_close_order_fields.dest_received_address,
            vlp_token,
            vlp_amount,
            vlp_close_order_fields.dest_received_blinding,
            vlp_index,
        );

        // ? update the state_dict
        update_state_after_position_register(vlp_note, position, new_position);

        // ? update the output
        write_mm_registration_to_output(
            position.position_header.position_address, vlp_token, max_vlp_supply, 1
        );

        return ();
    }
}

func get_vlp_close_order_fields{pedersen_ptr: HashBuiltin*}(
    base_close_order_fields: CloseOrderFields*, quote_close_order_fields: CloseOrderFields*
) {
    %{
        base_close_order_field_inputs = current_order["base_close_order_fields"]

        memory[ids.base_close_order_fields.address_ + ids.CloseOrderFields.dest_received_address] = int(base_close_order_field_inputs["dest_received_address"]["x"])
        memory[ids.base_close_order_fields.address_ + ids.CloseOrderFields.dest_received_blinding] = int(base_close_order_field_inputs["dest_received_blinding"])
    %}

    return ();
}
