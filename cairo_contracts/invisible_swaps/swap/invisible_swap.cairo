// %builtins output pedersen range_check

from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict_access import DictAccess

from invisible_swaps.order.invisible_order import (
    hash_transaction,
    Invisibl3Order,
    SpotNotesInfo,
    hash_spot_note_info,
)
from invisible_swaps.transaction.non_tab_order_tx import execute_non_tab_orders
from invisible_swaps.transaction.tab_order_tx import execute_tab_orders

from helpers.utils import Note
from helpers.spot_helpers.checks import consistency_checks

from order_tabs.close_order_tab import handle_order_tab_input
from order_tabs.order_tab import OrderTab

from rollup.global_config import GlobalConfig

func execute_swap{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    fee_tracker_dict: DictAccess*,
    global_config: GlobalConfig*,
    note_updates: Note*,
}() {
    alloc_locals;

    local invisibl3_order_A: Invisibl3Order;
    local invisibl3_order_B: Invisibl3Order;

    let (__fp__, _) = get_fp_and_pc();
    handle_inputs(&invisibl3_order_A, &invisibl3_order_B);

    local spend_amountA: felt;
    local spend_amountB: felt;
    local fee_takenA: felt;
    local fee_takenB: felt;

    %{
        swap_data = current_swap["swap_data"]

        spend_amountA = int(swap_data["spent_amount_a"]) 
        spend_amountB = int(swap_data["spent_amount_b"])

        ids.spend_amountA = spend_amountA
        ids.spend_amountB = spend_amountB

        ids.fee_takenA = int(swap_data["fee_taken_a"])
        ids.fee_takenB = int(swap_data["fee_taken_b"])
    %}

    consistency_checks(
        invisibl3_order_A, invisibl3_order_B, spend_amountA, spend_amountB, fee_takenA, fee_takenB
    );

    // * ORDER A =============================================================

    %{
        order_tab_input = current_swap["prev_order_tab_a"]
        is_tab_order = order_tab_input != None
        order_indexes = index_data["order_a"]
        current_order = swap_data["order_a"]
        signature = swap_data["signature_a"]
        prev_pfr_note = None
        if not is_tab_order:
            prev_pfr_note = current_swap["prev_pfr_note_a"]
    %}

    execute_transaction(invisibl3_order_A, spend_amountA, spend_amountB, fee_takenA);

    // * ORDER B =============================================================

    %{
        order_tab_input = current_swap["prev_order_tab_b"]
        is_tab_order = order_tab_input != None
        order_indexes = index_data["order_b"]
        current_order = swap_data["order_b"]
        signature = swap_data["signature_b"]
        prev_pfr_note = None 
        if not is_tab_order:
            prev_pfr_note = current_swap["prev_pfr_note_b"]
    %}

    execute_transaction(invisibl3_order_B, spend_amountB, spend_amountA, fee_takenB);

    return ();
}

func execute_transaction{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    fee_tracker_dict: DictAccess*,
    global_config: GlobalConfig*,
    note_updates: Note*,
}(invisibl3_order: Invisibl3Order, spend_amount_x: felt, spend_amount_y: felt, fee_taken_x: felt) {
    alloc_locals;

    let (__fp__, _) = get_fp_and_pc();

    if (nondet %{ not is_tab_order %} != 0) {
        // ? NON_TAB ORDER

        local spot_note_info: SpotNotesInfo;
        handle_spot_note_info_inputs(&spot_note_info);

        let note_info_hash = hash_spot_note_info(&spot_note_info);
        let (tx_hash: felt) = hash_transaction(invisibl3_order, note_info_hash);

        execute_non_tab_orders(
            tx_hash, spot_note_info, invisibl3_order, spend_amount_x, spend_amount_y, fee_taken_x
        );

        return ();
    } else {
        // ? tab order
        local order_tab: OrderTab;
        handle_order_tab_input(&order_tab);

        let order_tab_pub_key = order_tab.tab_header.pub_key;
        let (tx_hash) = hash_transaction(invisibl3_order, order_tab_pub_key);

        execute_tab_orders(
            tx_hash, order_tab, invisibl3_order, spend_amount_x, spend_amount_y, fee_taken_x
        );

        return ();
    }
}

func handle_inputs{poseidon_ptr: PoseidonBuiltin*}(
    invisibl3_order_A: Invisibl3Order*, invisibl3_order_B: Invisibl3Order*
) {
    %{
        ##* ORDER A =============================================================

        order_A_input = current_swap["swap_data"]["order_a"]

        order_A_addr = ids.invisibl3_order_A.address_

        memory[order_A_addr + ORDER_ID_OFFSET] = int(order_A_input["order_id"])
        memory[order_A_addr + EXPIRATION_TIMESTAMP_OFFSET] = int(order_A_input["expiration_timestamp"])
        memory[order_A_addr + TOKEN_SPENT_OFFSET] = int(order_A_input["token_spent"])
        memory[order_A_addr + TOKEN_RECEIVED_OFFSET] = int(order_A_input["token_received"])
        memory[order_A_addr + AMOUNT_SPENT_OFFSET] = int(order_A_input["amount_spent"])
        memory[order_A_addr + AMOUNT_RECEIVED_OFFSET] = int(order_A_input["amount_received"]) 
        memory[order_A_addr + FEE_LIMIT_OFFSET] = int(order_A_input["fee_limit"])


        ##* ORDER B =============================================================

        order_B_input = current_swap["swap_data"]["order_b"]

        order_B_addr = ids.invisibl3_order_B.address_

        memory[order_B_addr + ORDER_ID_OFFSET] = int(order_B_input["order_id"])
        memory[order_B_addr + EXPIRATION_TIMESTAMP_OFFSET] = int(order_B_input["expiration_timestamp"])
        memory[order_B_addr + TOKEN_SPENT_OFFSET] = int(order_B_input["token_spent"])
        memory[order_B_addr + TOKEN_RECEIVED_OFFSET] = int(order_B_input["token_received"])
        memory[order_B_addr + AMOUNT_SPENT_OFFSET] = int(order_B_input["amount_spent"])
        memory[order_B_addr + AMOUNT_RECEIVED_OFFSET] = int(order_B_input["amount_received"])
        memory[order_B_addr + FEE_LIMIT_OFFSET] = int(order_B_input["fee_limit"])


        index_data = current_swap["indexes"]
    %}

    return ();
}

func handle_spot_note_info_inputs{poseidon_ptr: PoseidonBuiltin*}(spot_note_info: SpotNotesInfo*) {
    %{
        input_notes = current_order["spot_note_info"]["notes_in"]

        notes_in_len_addr = ids.spot_note_info.address_ + ids.SpotNotesInfo.notes_in_len
        notes_in_addr = ids.spot_note_info.address_ + ids.SpotNotesInfo.notes_in
        refund_note_addr = ids.spot_note_info.address_ +   ids.SpotNotesInfo.refund_note
        dest_received_address_addr = ids.spot_note_info.address_ +   ids.SpotNotesInfo.dest_received_address
        dest_received_blinding_addr = ids.spot_note_info.address_ +   ids.SpotNotesInfo.dest_received_blinding

        memory[notes_in_len_addr] = len(input_notes)
        memory[notes_in_addr] = notes_ = segments.add()
        for i in range(len(input_notes)):
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET+0] = int(input_notes[i]["address"]["x"])
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET+1] = int(input_notes[i]["address"]["y"])
            memory[notes_ + i* NOTE_SIZE + TOKEN_OFFSET] = int(input_notes[i]["token"])
            memory[notes_ + i* NOTE_SIZE + AMOUNT_OFFSET] = int(input_notes[i]["amount"])
            memory[notes_ + i* NOTE_SIZE + BLINDING_FACTOR_OFFSET] = int(input_notes[i]["blinding"])
            memory[notes_ + i* NOTE_SIZE + INDEX_OFFSET] = int(input_notes[i]["index"])
            memory[notes_ + i* NOTE_SIZE + HASH_OFFSET] = int(input_notes[i]["hash"])

        refund_note__  = current_order["spot_note_info"]["refund_note"]
        if refund_note__ is not None:
            memory[refund_note_addr + ADDRESS_OFFSET+0] = int(refund_note__["address"]["x"])
            memory[refund_note_addr + ADDRESS_OFFSET+1] = int(refund_note__["address"]["y"])
            memory[refund_note_addr + TOKEN_OFFSET] = int(refund_note__["token"])
            memory[refund_note_addr + AMOUNT_OFFSET] = int(refund_note__["amount"])
            memory[refund_note_addr + BLINDING_FACTOR_OFFSET] = int(refund_note__["blinding"])
            memory[refund_note_addr + INDEX_OFFSET] = int(refund_note__["index"])
            memory[refund_note_addr + HASH_OFFSET] = int(refund_note__["hash"])
        else:
            memory[refund_note_addr + ADDRESS_OFFSET+0] = 0
            memory[refund_note_addr + ADDRESS_OFFSET+1] = 0
            memory[refund_note_addr + TOKEN_OFFSET] = 0
            memory[refund_note_addr + AMOUNT_OFFSET] = 0
            memory[refund_note_addr + BLINDING_FACTOR_OFFSET] = 0
            memory[refund_note_addr + INDEX_OFFSET] = 0
            memory[refund_note_addr + HASH_OFFSET] = 0


        memory[dest_received_address_addr] = int(current_order["spot_note_info"]["dest_received_address"]["x"]) # Need just the x coordinate
        memory[dest_received_blinding_addr] = int(current_order["spot_note_info"]["dest_received_blinding"])
    %}

    return ();
}
