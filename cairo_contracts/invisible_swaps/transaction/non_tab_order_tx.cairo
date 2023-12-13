from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.ec_point import EcPoint
from starkware.cairo.common.math import assert_le
from starkware.cairo.common.math_cmp import is_le

from helpers.utils import Note, construct_new_note, take_fee, verify_note_hashes, verify_note_hash
from helpers.signatures import verify_spot_signature
from helpers.spot_helpers.dict_updates import update_state_dict

from helpers.spot_helpers.checks import not_tab_order_check

from helpers.spot_helpers.partial_fill_helpers import refund_partial_fill

from rollup.global_config import get_dust_amount, GlobalConfig

from invisible_swaps.order.invisible_order import Invisibl3Order, SpotNotesInfo

func execute_non_tab_orders{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    fee_tracker_dict: DictAccess*,
    global_config: GlobalConfig*,
    note_updates: Note*,
}(
    order_hash: felt,
    spot_note_info: SpotNotesInfo,
    invisibl3_order: Invisibl3Order,
    spend_amount: felt,
    receive_amount: felt,
    fee_taken: felt,
) {
    alloc_locals;

    // * ORDER ============================================================
    // If this is not the first fill return the last partial fill note hash else return 0

    %{ is_first_fill = not prev_pfr_note %}

    if (nondet %{ is_first_fill %} != 0) {
        // ! if this is the first fill
        first_fill(
            spot_note_info, invisibl3_order, spend_amount, receive_amount, order_hash, fee_taken
        );

        return ();
    } else {
        // ! if the order was filled partially before this
        later_fills(
            spot_note_info, order_hash, invisibl3_order, receive_amount, spend_amount, fee_taken
        );

        return ();
    }
}

// ==================================================================================

func first_fill{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    fee_tracker_dict: DictAccess*,
    global_config: GlobalConfig*,
}(
    spot_note_info: SpotNotesInfo,
    invisibl3_order: Invisibl3Order,
    spend_amount: felt,
    receive_amount: felt,
    order_hash: felt,
    fee_taken: felt,
) {
    alloc_locals;

    let notes_in_len = spot_note_info.notes_in_len;
    let notes_in = spot_note_info.notes_in;
    let refund_note = spot_note_info.refund_note;

    verify_note_hashes(notes_in_len, notes_in);
    verify_note_hash(refund_note);

    not_tab_order_check(invisibl3_order, notes_in_len, notes_in, refund_note);

    // ? take a fee
    take_fee(invisibl3_order.token_received, fee_taken);

    // ? verify the signatures for the notes spent
    let (pub_key_sum: EcPoint) = verify_spot_signature(order_hash, notes_in_len, notes_in);

    local swap_note_idx: felt;
    %{
        ids.swap_note_idx = int(order_indexes["swap_note_idx"])
        if ids.notes_in_len > 1:
            note_in2_idx = memory[ids.notes_in.address_ + NOTE_SIZE + INDEX_OFFSET]
            assert ids.swap_note_idx == note_in2_idx, "something funky happening with the swap note index"
    %}

    // let swap_received_amount = amount - fee
    // ? This is the note receiveing the funds of this swap
    let (swap_note: Note) = construct_new_note(
        spot_note_info.dest_received_address,
        invisibl3_order.token_received,
        receive_amount - fee_taken,
        spot_note_info.dest_received_blinding,
        swap_note_idx,
    );

    // ? update the note dict with the new notes
    update_state_dict{state_dict=state_dict}(notes_in_len, notes_in, refund_note, swap_note);

    // ! Only executed  if the order was filled partialy not completely ------------------
    let (dust_amount) = get_dust_amount(invisibl3_order.token_spent);
    let is_partialy_filled: felt = is_le(dust_amount, invisibl3_order.amount_spent - spend_amount);
    if (is_partialy_filled == 0) {
        return ();
    }

    let notes_in_0 = notes_in[0];
    let unspent_amount = invisibl3_order.amount_spent - spend_amount;
    refund_partial_fill(
        invisibl3_order, notes_in_0.address.x, notes_in_0.blinding_factor, unspent_amount
    );

    return ();
}

func later_fills{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    fee_tracker_dict: DictAccess*,
    global_config: GlobalConfig*,
    note_updates: Note*,
}(
    spot_note_info: SpotNotesInfo,
    order_hash: felt,
    invisibl3_order: Invisibl3Order,
    receive_amount: felt,
    spend_amount: felt,
    fee_taken: felt,
) {
    alloc_locals;

    // ? This is the note that was refunded (leftover) from the previous fill
    local prev_fill_refund_note: Note;
    %{
        note_data = prev_pfr_note
        address_x = note_data["address"]["x"]
        address_y = note_data["address"]["y"]
        token = note_data["token"]
        amount = note_data["amount"]
        blinding_factor = note_data["blinding"]
        index = note_data["index"]
        note_hash = note_data["hash"]

        addr_ = ids.prev_fill_refund_note.address_
        memory[addr_ + ADDRESS_OFFSET + 0] = int(address_x)
        memory[addr_ + ADDRESS_OFFSET + 1] = int(address_y)
        memory[addr_ + TOKEN_OFFSET] = int(token)
        memory[addr_ + AMOUNT_OFFSET] = int(amount)
        memory[addr_ + BLINDING_FACTOR_OFFSET] = int(blinding_factor)
        memory[addr_ + INDEX_OFFSET] = int(index)
        memory[addr_ + HASH_OFFSET] = int(note_hash)
    %}

    verify_note_hash(prev_fill_refund_note);

    // ? Check for valid token
    assert prev_fill_refund_note.token = invisibl3_order.token_spent;

    // ? Check for valid address
    assert prev_fill_refund_note.address.x = spot_note_info.notes_in[0].address.x;

    // ? Verify the signature for the refund note
    verify_spot_signature(order_hash, spot_note_info.notes_in_len, spot_note_info.notes_in);

    // ? take a fee
    take_fee(invisibl3_order.token_received, fee_taken);

    // ? prevent spending more than the previous refund note
    assert_le(spend_amount, prev_fill_refund_note.amount);

    local swap_note_idx: felt;
    %{ ids.swap_note_idx = int(order_indexes["swap_note_idx"]) %}

    // ? This is the note receiveing the funds of this swap
    let (swap_note: Note) = construct_new_note(
        spot_note_info.dest_received_address,
        invisibl3_order.token_received,
        receive_amount - fee_taken,
        spot_note_info.dest_received_blinding,
        swap_note_idx,
    );

    // * Update the note dict with the new notes
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = prev_fill_refund_note.index;
    assert state_dict_ptr.prev_value = prev_fill_refund_note.hash;
    assert state_dict_ptr.new_value = swap_note.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    // ? store to an array used for program outputs
    assert note_updates[0] = swap_note;
    let note_updates = &note_updates[1];

    %{ leaf_node_types[ids.prev_fill_refund_note.index] = "note" %}
    %{
        note_output_idxs[ids.prev_fill_refund_note.index] = note_outputs_len 
        note_outputs_len += 1
    %}

    // ! if the order was filled partialy not completely ---------------------------
    let spend_amount_left = prev_fill_refund_note.amount;

    let (dust_amount) = get_dust_amount(invisibl3_order.token_spent);
    let is_partialy_filled: felt = is_le(dust_amount, spend_amount_left - spend_amount);
    if (is_partialy_filled == 0) {
        return ();
    }

    let unspent_amount = prev_fill_refund_note.amount - spend_amount;
    refund_partial_fill(
        invisibl3_order,
        prev_fill_refund_note.address.x,
        prev_fill_refund_note.blinding_factor,
        unspent_amount,
    );

    return ();
}
