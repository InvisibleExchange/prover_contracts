from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash_many
from helpers.utils import Note, hash_notes_array

struct Invisibl3Order {
    order_id: felt,
    expiration_timestamp: felt,
    token_spent: felt,
    token_received: felt,
    amount_spent: felt,
    amount_received: felt,
    fee_limit: felt,
    // spot_note_info: SpotNotesInfo,
    // order_tab: OrderTab,
}

struct SpotNotesInfo {
    notes_in_len: felt,
    notes_in: Note*,
    refund_note: Note,
    dest_received_address: felt,  // x coordinate of address
    dest_received_blinding: felt,
}

func hash_transaction{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    invisibl3_order: Invisibl3Order, extra_hash_input: felt
) -> (res: felt) {
    alloc_locals;

    // & extra_hash_input is either a hash of SpotNotesInfo or a public key of OrderTab
    let (local arr: felt*) = alloc();
    assert arr[0] = invisibl3_order.expiration_timestamp;
    assert arr[1] = invisibl3_order.token_spent;
    assert arr[2] = invisibl3_order.token_received;
    assert arr[3] = invisibl3_order.amount_spent;
    assert arr[4] = invisibl3_order.amount_received;
    assert arr[5] = invisibl3_order.fee_limit;
    assert arr[6] = extra_hash_input;

    let (res) = poseidon_hash_many(7, arr);

    return (res,);
}

func hash_spot_note_info{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    spot_note_info: SpotNotesInfo*
) -> felt {
    alloc_locals;

    let (local empty_arr) = alloc();
    let (hashed_notes_in_len: felt, hashed_notes_in: felt*) = hash_notes_array(
        spot_note_info.notes_in_len, spot_note_info.notes_in, 0, empty_arr
    );

    assert hashed_notes_in[hashed_notes_in_len] = spot_note_info.refund_note.hash;
    assert hashed_notes_in[hashed_notes_in_len + 1] = spot_note_info.dest_received_address;
    assert hashed_notes_in[hashed_notes_in_len + 2] = spot_note_info.dest_received_blinding;

    let (res) = poseidon_hash_many(hashed_notes_in_len + 3, hashed_notes_in);

    return res;
}
