from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.math import assert_le

from helpers.utils import Note, check_index_uniqueness

from perpetuals.order.order_structs import PerpOrder, OpenOrderFields

from rollup.global_config import get_dust_amount, GlobalConfig, token_decimals

func consistency_checks{range_check_ptr, global_config: GlobalConfig*}(
    order_a: PerpOrder,
    order_b: PerpOrder,
    spent_collateral: felt,
    spent_synthetic: felt,
    fee_taken_a: felt,
    fee_taken_b: felt,
) {
    alloc_locals;

    // ? Check that collateral and synthetic tokens are valid
    // Note: This is already done in the token_decimals function!

    // ? Check that the synthetic and collateral tokens are the same for both orders
    assert order_a.synthetic_token = order_b.synthetic_token;

    // ? for simplicity, we require order_a to be the "buyer" and order_b to be the "seller"
    assert order_a.order_side = 1;  // Long Order
    assert order_b.order_side = 0;  // Short Order

    // ? Check that the amounts swapped don't exceed the order amounts
    let (dust_amount1) = get_dust_amount(order_a.synthetic_token);
    let (dust_amount2) = get_dust_amount(global_config.collateral_token);
    assert_le(spent_collateral - dust_amount2, order_a.collateral_amount);
    assert_le(spent_synthetic - dust_amount1, order_b.synthetic_amount);

    // ? Verify consistency of amounts swaped
    // ? Check the price is consistent to 0.01% (1/10000)
    let a1 = spent_collateral * order_a.synthetic_amount * 9999;
    let a2 = spent_synthetic * order_a.collateral_amount * 10000;
    let b1 = spent_synthetic * order_b.collateral_amount * 10000;
    let b2 = spent_collateral * order_b.synthetic_amount * 10001;

    assert_le(a1, a2);
    assert_le(b1, b2);

    // ? Verify the fee taken is consistent with the order
    validate_fee_taken(fee_taken_a, order_a, spent_collateral);
    validate_fee_taken(fee_taken_b, order_b, spent_collateral);

    return ();
}

func validate_fee_taken{range_check_ptr}(
    fee_taken: felt, order: PerpOrder, spent_collateral: felt
) {
    // ? Check that the fees taken don't exceed the order fees
    assert_le(fee_taken * order.collateral_amount, order.fee_limit * spent_collateral);

    return ();
}

func checks_prev_fill_consistencies{range_check_ptr}(
    order: PerpOrder, open_order_fields: OpenOrderFields, init_margin: felt, pfr_note: Note
) {
    // TODO: Check that collateral token is valid (or the same as previous one?)
    // assert pfr_note.token = order.collateral_token;

    assert pfr_note.token = open_order_fields.collateral_token;

    assert_le(init_margin, pfr_note.amount);

    assert pfr_note.address.x = open_order_fields.notes_in[0].address.x;

    return ();
}

func range_checks{range_check_ptr}(order_a: PerpOrder, order_b: PerpOrder) {
    // assert_le(order_a.collateral_amount, MAX_AMOUNT);
    // assert_le(order_a.synthetic_amount, MAX_AMOUNT);
    // assert_le(order_b.collateral_amount, MAX_AMOUNT);
    // assert_le(order_b.synthetic_amount, MAX_AMOUNT);

    // assert_le(order_a.expiration_timestamp, MAX_EXPIRATION_TIMESTAMP);
    // assert_le(order_b.expiration_timestamp, MAX_EXPIRATION_TIMESTAMP);

    // assert_le(order_a.position_effect_type, 3);
    // assert_le(order_b.position_effect_type, 3);

    // assert_le(order_a.order_side, 1);
    // assert_le(order_b.order_side, 1);

    return ();
}

func open_order_specific_checks{range_check_ptr}(
    order: PerpOrder,
    open_order_fields: OpenOrderFields,
    spent_synthetic: felt,
    init_margin: felt,
    fee_taken: felt,
) {
    // // ? Check that the init_margin ratio is good enough
    // assert_le(
    //     init_margin * order.synthetic_amount, open_order_fields.initial_margin * spent_synthetic
    // );

    // ? Check that note indexes are unique
    check_index_uniqueness(open_order_fields.notes_in_len, open_order_fields.notes_in);

    // Todo: Maybe check max leverage consistency

    return ();
}
