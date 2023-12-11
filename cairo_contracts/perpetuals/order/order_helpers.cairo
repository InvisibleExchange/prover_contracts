from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.math import unsigned_div_rem
from starkware.cairo.common.math_cmp import is_nn, is_le
from starkware.cairo.common.pow import pow

from rollup.global_config import (
    token_decimals,
    price_decimals,
    get_min_partial_liquidation_size,
    GlobalConfig,
)

from perpetuals.order.order_hash import _hash_position_internal

// * CALCULATE PRICES * #

func _get_entry_price{range_check_ptr, global_config: GlobalConfig*}(
    size: felt, initial_margin: felt, leverage: felt, synthetic_token: felt
) -> (price: felt) {
    alloc_locals;

    let (collateral_decimals) = token_decimals(global_config.collateral_token);
    let leverage_decimals = global_config.leverage_decimals;

    let (synthetic_decimals: felt) = token_decimals(synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(synthetic_token);

    let decimal_conversion = synthetic_decimals + synthetic_price_decimals - (
        collateral_decimals + leverage_decimals
    );

    let (multiplier: felt) = pow(10, decimal_conversion);

    let (price: felt, _) = unsigned_div_rem(initial_margin * leverage * multiplier, size);

    return (price,);
}

func _get_liquidation_price{range_check_ptr, global_config: GlobalConfig*}(
    entry_price: felt,
    position_size: felt,
    margin: felt,
    order_side: felt,
    synthetic_token: felt,
    is_partial_liquidation_: felt,
) -> (price: felt) {
    alloc_locals;

    let (min_partial_liquidation_size) = get_min_partial_liquidation_size(synthetic_token);

    let size_partialy_liquidatable = is_nn(position_size - min_partial_liquidation_size - 1);
    let is_partial_liquidation = is_partial_liquidation_ * size_partialy_liquidatable;

    let mm_fraction = 3 + is_partial_liquidation;  // 3/4% of 100

    let (collateral_decimals) = token_decimals(global_config.collateral_token);

    let (synthetic_decimals: felt) = token_decimals(synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(synthetic_token);

    let decimal_conversion = synthetic_decimals + synthetic_price_decimals - collateral_decimals;
    let (multiplier) = pow(10, decimal_conversion);

    let d1 = margin * multiplier;
    let d2 = mm_fraction * entry_price * position_size / 100;

    if (order_side == 1) {
        if (position_size == 0) {
            return (0,);
        }

        let (price_delta, _) = unsigned_div_rem(
            (d1 - d2) * 100, (100 - mm_fraction) * position_size
        );

        let liquidation_price = entry_price - price_delta;

        let is_nn_ = is_nn(liquidation_price);
        if (is_nn_ == 1) {
            return (liquidation_price,);
        } else {
            return (0,);
        }
    } else {
        if (position_size == 0) {
            let (p) = pow(10, synthetic_price_decimals);

            return (1000000000 * p,);
        }

        let (price_delta, _) = unsigned_div_rem(
            (d1 - d2) * 100, (100 + mm_fraction) * position_size
        );

        let liquidation_price = entry_price + price_delta;

        return (liquidation_price,);
    }
}

func _get_bankruptcy_price{range_check_ptr, global_config: GlobalConfig*}(
    entry_price: felt, margin: felt, size: felt, order_side: felt, synthetic_token: felt
) -> (price: felt) {
    alloc_locals;

    let (collateral_decimals) = token_decimals(global_config.collateral_token);

    let (synthetic_decimals: felt) = token_decimals(synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(synthetic_token);

    tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals -
        collateral_decimals;
    let (multiplier: felt) = pow(10, decimal_conversion);

    if (order_side == 1) {
        if (size == 0) {
            return (0,);
        }

        let (t1: felt, _) = unsigned_div_rem(margin * multiplier, size);
        let bankruptcy_price = entry_price - t1;

        let c1: felt = is_nn(bankruptcy_price);
        if (c1 == 0) {
            return (0,);
        }

        return (bankruptcy_price,);
    } else {
        if (size == 0) {
            let (p) = pow(10, synthetic_price_decimals);

            return (1000000000 * p,);
        }

        let (t1: felt, _) = unsigned_div_rem(margin * multiplier, size);
        let bankruptcy_price = entry_price + t1;
        return (bankruptcy_price,);
    }
}

func _get_pnl{range_check_ptr, global_config: GlobalConfig*}(
    order_side: felt,
    position_size: felt,
    entry_price: felt,
    mark_price: felt,
    synthetic_token: felt,
) -> felt {
    alloc_locals;

    let (collateral_decimals) = token_decimals(global_config.collateral_token);

    let (synthetic_decimals: felt) = token_decimals(synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(synthetic_token);

    tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals -
        collateral_decimals;
    let (multiplier: felt) = pow(10, decimal_conversion);

    let (bound: felt) = pow(2, 64);

    let delta = entry_price - mark_price + 2 * order_side * mark_price - 2 * order_side *
        entry_price;

    let is_pnl_positive = is_le(0, delta);

    if (is_pnl_positive == 1) {
        let (pnl, _) = unsigned_div_rem(delta * position_size, multiplier);

        return pnl;
    } else {
        let (pnl, _) = unsigned_div_rem((-delta) * position_size, multiplier);

        return -pnl;
    }
}

func _get_leftover_value{range_check_ptr, global_config: GlobalConfig*}(
    order_side: felt,
    position_size: felt,
    bankruptcy_price: felt,
    close_price: felt,
    multiplier: felt,
) -> felt {
    alloc_locals;

    // let (collateral_decimals) = token_decimals(global_config.collateral_token);

    // let (synthetic_decimals: felt) = token_decimals(synthetic_token);
    // let (synthetic_price_decimals: felt) = price_decimals(synthetic_token);

    // tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals -
    //     collateral_decimals;
    // let (multiplier: felt) = pow(10, decimal_conversion);

    let (p1: felt, _) = unsigned_div_rem(position_size * close_price, multiplier);
    let (p2: felt, _) = unsigned_div_rem(position_size * bankruptcy_price, multiplier);
    if (order_side == 1) {
        let leftover_value = p1 - p2;

        return leftover_value;
    } else {
        let leftover_value = p2 - p1;

        return leftover_value;
    }
}

func update_position_info{
    range_check_ptr, global_config: GlobalConfig*, poseidon_ptr: PoseidonBuiltin*
}(
    header_hash: felt,
    order_side: felt,
    synthetic_token: felt,
    position_size: felt,
    margin: felt,
    average_entry_price: felt,
    funding_idx: felt,
    allow_partial_liquidations: felt,
    vlp_supply: felt,
) -> (felt, felt, felt) {
    alloc_locals;

    let (bankruptcy_price: felt) = _get_bankruptcy_price(
        average_entry_price, margin, position_size, order_side, synthetic_token
    );
    let (liquidation_price: felt) = _get_liquidation_price(
        average_entry_price,
        position_size,
        margin,
        order_side,
        synthetic_token,
        allow_partial_liquidations,
    );

    let (new_position_hash: felt) = _hash_position_internal(
        header_hash,
        order_side,
        position_size,
        average_entry_price,
        liquidation_price,
        funding_idx,
        vlp_supply,
    );

    return (bankruptcy_price, liquidation_price, new_position_hash);
}
