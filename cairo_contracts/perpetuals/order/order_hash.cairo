from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash, poseidon_hash_many
from starkware.cairo.common.alloc import alloc

from helpers.utils import Note, hash_notes_array

from perpetuals.order.order_structs import (
    PerpOrder,
    OpenOrderFields,
    CloseOrderFields,
    PerpPosition,
    PositionHeader,
)

// * HASH VERIFICATION FUNCTIONS * #

func verify_open_order_hash{poseidon_ptr: PoseidonBuiltin*}(
    perp_order: PerpOrder, order_fields: OpenOrderFields
) {
    alloc_locals;

    assert perp_order.position_effect_type = 0;

    let (order_hash: felt) = _hash_perp_order_internal(perp_order);

    let (fields_hash: felt) = _hash_open_order_fields(order_fields);

    let (order_hash: felt) = poseidon_hash(order_hash, fields_hash);

    assert order_hash = perp_order.hash;

    return ();
}

func verify_order_hash{poseidon_ptr: PoseidonBuiltin*}(perp_order: PerpOrder) {
    let (order_hash: felt) = _hash_perp_order_internal(perp_order);

    assert order_hash = perp_order.hash;

    return ();
}

func verify_close_order_hash{poseidon_ptr: PoseidonBuiltin*}(
    perp_order: PerpOrder, close_order_fields: CloseOrderFields
) {
    alloc_locals;

    assert perp_order.position_effect_type = 2;

    let (order_hash: felt) = _hash_perp_order_internal(perp_order);

    let (fields_hash: felt) = _hash_close_order_fields(close_order_fields);

    let (final_hash: felt) = poseidon_hash(order_hash, fields_hash);

    assert final_hash = perp_order.hash;

    return ();
}

func verify_position_hash{poseidon_ptr: PoseidonBuiltin*}(position: PerpPosition) {
    let (header_hash) = _hash_position_header(
        position.position_header.synthetic_token,
        position.position_header.allow_partial_liquidations,
        position.position_header.position_address,
        position.position_header.vlp_token,
    );

    assert header_hash = position.position_header.hash;

    let (position_hash: felt) = _hash_position_internal(
        header_hash,
        position.order_side,
        position.position_size,
        position.entry_price,
        position.liquidation_price,
        position.last_funding_idx,
        position.vlp_supply,
    );

    assert position_hash = position.hash;

    return ();
}

// * HASH FUNCTION HELPERS * #
func _hash_position_internal{poseidon_ptr: PoseidonBuiltin*}(
    header_hash: felt,
    order_side: felt,
    position_size: felt,
    entry_price: felt,
    liquidation_price: felt,
    last_funding_idx: felt,
    vlp_supply: felt,
) -> (res: felt) {
    alloc_locals;

    let (local arr: felt*) = alloc();
    assert arr[0] = header_hash;
    assert arr[1] = order_side;
    assert arr[2] = position_size;
    assert arr[3] = entry_price;
    assert arr[4] = liquidation_price;
    assert arr[5] = last_funding_idx;
    assert arr[6] = vlp_supply;

    let (res) = poseidon_hash_many(7, arr);

    return (res=res);
}

func _hash_position_header{poseidon_ptr: PoseidonBuiltin*}(
    synthetic_token: felt, allow_partial_liquidations: felt, position_address: felt, vlp_token: felt
) -> (res: felt) {
    alloc_locals;

    // & hash = H({allow_partial_liquidations, synthetic_token, position_address, vlp_token})
    let (local arr: felt*) = alloc();
    assert arr[0] = allow_partial_liquidations;
    assert arr[1] = synthetic_token;
    assert arr[2] = position_address;
    assert arr[3] = vlp_token;

    let (res) = poseidon_hash_many(4, arr);

    return (res=res);
}

func _hash_open_order_fields{poseidon_ptr: PoseidonBuiltin*}(order_fields: OpenOrderFields) -> (
    res: felt
) {
    alloc_locals;

    let (local empty_arr) = alloc();
    let (hashed_notes_in_len: felt, hashed_notes_in: felt*) = hash_notes_array(
        order_fields.notes_in_len, order_fields.notes_in, 0, empty_arr
    );

    assert hashed_notes_in[hashed_notes_in_len] = order_fields.refund_note.hash;
    assert hashed_notes_in[hashed_notes_in_len + 1] = order_fields.initial_margin;
    assert hashed_notes_in[hashed_notes_in_len + 2] = order_fields.collateral_token;
    assert hashed_notes_in[hashed_notes_in_len + 3] = order_fields.position_address;
    assert hashed_notes_in[hashed_notes_in_len + 4] = order_fields.allow_partial_liquidations;

    let (res) = poseidon_hash_many(hashed_notes_in_len + 5, hashed_notes_in);

    return (res=res);
}

func _hash_close_order_fields{poseidon_ptr: PoseidonBuiltin*}(
    close_order_fields: CloseOrderFields
) -> (res: felt) {
    alloc_locals;

    let (hash: felt) = poseidon_hash(
        close_order_fields.dest_received_address_x, close_order_fields.dest_received_blinding
    );

    return (res=hash);
}

func _hash_perp_order_internal{poseidon_ptr: PoseidonBuiltin*}(perp_order: PerpOrder) -> (
    res: felt
) {
    alloc_locals;

    let (local arr: felt*) = alloc();
    assert arr[0] = perp_order.expiration_timestamp;
    assert arr[1] = perp_order.pos_addr_string;
    assert arr[2] = perp_order.position_effect_type;
    assert arr[3] = perp_order.order_side;
    assert arr[4] = perp_order.synthetic_token;
    assert arr[5] = perp_order.synthetic_amount;
    assert arr[6] = perp_order.collateral_amount;
    assert arr[7] = perp_order.fee_limit;

    let (res) = poseidon_hash_many(8, arr);

    return (res=res);
}

// * ===============================================================================
