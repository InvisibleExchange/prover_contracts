from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash_many

from perpetuals.order.order_structs import PerpPosition, OpenOrderFields
from perpetuals.order.order_hash import _hash_open_order_fields

struct LiquidationOrder {
    order_side: felt,
    synthetic_token: felt,
    synthetic_amount: felt,
    collateral_amount: felt,
    //
    hash: felt,
}

func verify_liquidation_order_hash{poseidon_ptr: PoseidonBuiltin*}(
    liquidation_order: LiquidationOrder, open_order_fields: OpenOrderFields, position: PerpPosition
) {
    let (fields_hash: felt) = _hash_open_order_fields(open_order_fields);

    let hash = hash_liquidation_order(
        position.position_header.position_address,
        liquidation_order.order_side,
        liquidation_order.synthetic_token,
        liquidation_order.synthetic_amount,
        liquidation_order.collateral_amount,
        fields_hash,
    );

    assert hash = liquidation_order.hash;

    return ();
}

func hash_liquidation_order{poseidon_ptr: PoseidonBuiltin*}(
    position_address: felt,
    order_side: felt,
    synthetic_token: felt,
    synthetic_amount: felt,
    collateral_amount: felt,
    open_order_fields_hash: felt,
) -> felt {
    alloc_locals;

    let (local arr: felt*) = alloc();
    assert arr[0] = position_address;
    assert arr[1] = order_side;
    assert arr[2] = synthetic_token;
    assert arr[3] = synthetic_amount;
    assert arr[4] = collateral_amount;
    assert arr[5] = open_order_fields_hash;

    let (res) = poseidon_hash_many(6, arr);
    return res;
}
