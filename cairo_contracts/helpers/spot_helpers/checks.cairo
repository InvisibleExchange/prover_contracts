from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.math import assert_le, assert_lt, unsigned_div_rem
from starkware.cairo.common.pow import pow

from rollup.global_config import price_decimals, token_decimals, GlobalConfig, get_dust_amount
from helpers.utils import Note, check_index_uniqueness, validate_fee_taken, sum_notes

from invisible_swaps.order.invisible_order import Invisibl3Order

// --------------------------------------------------------------------------------------------------

func consistency_checks{range_check_ptr, global_config: GlobalConfig*}(
    invisibl3_order_A: Invisibl3Order,
    invisibl3_order_B: Invisibl3Order,
    spend_amountA: felt,
    spend_amountB: felt,
    fee_takenA: felt,
    fee_takenB: felt,
) {
    alloc_locals;

    // ? Check that the tokens swapped match
    assert invisibl3_order_A.token_spent = invisibl3_order_B.token_received;
    assert invisibl3_order_A.token_received = invisibl3_order_B.token_spent;

    // ? Check that the amounts swapped dont exceed the order amounts
    let (dust_amount_a) = get_dust_amount(invisibl3_order_A.token_spent);
    let (dust_amount_b) = get_dust_amount(invisibl3_order_B.token_spent);
    assert_le(spend_amountA - dust_amount_a, invisibl3_order_A.amount_spent);
    assert_le(spend_amountB - dust_amount_b, invisibl3_order_B.amount_spent);

    // ? Verify consistency of amounts swaped
    // ? Check the price is consistent to 0.01% (1/10000)
    let a1 = spend_amountA * invisibl3_order_A.amount_received * 10000;
    let a2 = spend_amountB * invisibl3_order_A.amount_spent * 10001;
    let b1 = spend_amountB * invisibl3_order_B.amount_received * 10000;
    let b2 = spend_amountA * invisibl3_order_B.amount_spent * 10001;

    assert_le(a1, a2);
    assert_le(b1, b2);

    // ? Verify the fee taken is consistent with the order
    validate_fee_taken(
        fee_takenA, invisibl3_order_A.fee_limit, spend_amountB, invisibl3_order_A.amount_received
    );
    validate_fee_taken(
        fee_takenB, invisibl3_order_B.fee_limit, spend_amountA, invisibl3_order_B.amount_received
    );

    return ();
}

func not_tab_order_check{range_check_ptr}(
    invisibl3_order: Invisibl3Order, notes_in_len: felt, notes_in: Note*, refund_note: Note
) {
    alloc_locals;

    // ? Verify note uniqueness
    check_index_uniqueness(notes_in_len, notes_in);

    // ? verify the sums match the refund and spend amounts
    let (sum_inputs: felt) = sum_notes(notes_in_len, notes_in, invisibl3_order.token_spent, 0);
    assert_le(invisibl3_order.amount_spent + refund_note.amount, sum_inputs);

    return ();
}
