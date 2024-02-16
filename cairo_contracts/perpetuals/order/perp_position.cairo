from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.math import unsigned_div_rem, assert_le
from starkware.cairo.common.math_cmp import is_not_zero, is_le
from starkware.cairo.common.pow import pow

from rollup.global_config import token_decimals, price_decimals, GlobalConfig

from perpetuals.order.order_structs import PerpPosition, PositionHeader

from perpetuals.order.order_hash import _hash_position_internal, _hash_position_header

from perpetuals.prices.prices import validate_price_in_range
from perpetuals.funding.funding import FundingInfo, apply_funding

from perpetuals.order.order_helpers import (
    _get_entry_price,
    _get_liquidation_price,
    _get_bankruptcy_price,
    _get_pnl,
    _get_leftover_value,
    _should_partially_liquidate,
    update_position_info,
)

// * ====================================================================================

func construct_new_position{
    range_check_ptr, poseidon_ptr: PoseidonBuiltin*, global_config: GlobalConfig*
}(
    order_side: felt,
    synthetic_token: felt,
    collateral_token: felt,
    position_size: felt,
    margin: felt,
    leverage: felt,
    position_address: felt,
    funding_idx: felt,
    idx: felt,
    fee_taken: felt,
    allow_partial_liquidations: felt,
) -> (position: PerpPosition) {
    alloc_locals;

    let (entry_price: felt) = _get_entry_price(position_size, margin, leverage, synthetic_token);

    let (bankruptcy_price: felt) = _get_bankruptcy_price(
        entry_price, margin - fee_taken, position_size, order_side, synthetic_token
    );

    let (liquidation_price: felt) = _get_liquidation_price(
        entry_price,
        position_size,
        margin - fee_taken,
        order_side,
        synthetic_token,
        allow_partial_liquidations,
    );

    let (header_hash: felt) = _hash_position_header(
        synthetic_token, allow_partial_liquidations, position_address, 0
    );
    let position_header: PositionHeader = PositionHeader(
        synthetic_token, allow_partial_liquidations, position_address, 0, header_hash
    );

    let (hash: felt) = _hash_position_internal(
        header_hash, order_side, position_size, entry_price, liquidation_price, funding_idx, 0
    );

    let position: PerpPosition = PerpPosition(
        position_header,
        order_side,
        position_size,
        margin - fee_taken,
        entry_price,
        liquidation_price,
        bankruptcy_price,
        funding_idx,
        0,
        idx,
        hash,
    );

    return (position,);
}

// * ====================================================================================

func add_margin_to_position_internal{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    position: PerpPosition,
    added_margin: felt,
    added_size: felt,
    added_leverage: felt,
    fee_taken: felt,
) -> (position: PerpPosition) {
    alloc_locals;

    let (collateral_decimals) = token_decimals(global_config.collateral_token);
    let leverage_decimals = global_config.leverage_decimals;

    let (synthetic_decimals: felt) = token_decimals(position.position_header.synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(position.position_header.synthetic_token);

    tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals - (
        collateral_decimals + leverage_decimals
    );
    let (multiplier: felt) = pow(10, decimal_conversion);

    let (added_entry_price, _) = unsigned_div_rem(
        added_margin * added_leverage * multiplier, added_size
    );

    let added_margin = added_margin - fee_taken;

    let prev_nominal = position.position_size * position.entry_price;
    let added_nominal = added_size * added_entry_price;

    let (average_entry_price, _) = unsigned_div_rem(
        prev_nominal + added_nominal, position.position_size + added_size
    );

    // TODO: Should we apply funding?
    // let (margin_after_funding) = apply_funding(position, funding_idx);
    // let margin = margin_after_funding + added_margin;

    let margin = position.margin + added_margin;

    let updated_size = position.position_size + added_size;

    let (bankruptcy_price, liquidation_price, new_position_hash) = update_position_info(
        position.position_header.hash,
        position.order_side,
        position.position_header.synthetic_token,
        updated_size,
        margin,
        average_entry_price,
        position.last_funding_idx,
        position.position_header.allow_partial_liquidations,
        position.vlp_supply,
    );

    let new_position = PerpPosition(
        position.position_header,
        position.order_side,
        updated_size,
        margin,
        average_entry_price,
        liquidation_price,
        bankruptcy_price,
        position.last_funding_idx,
        position.vlp_supply,
        position.index,
        new_position_hash,
    );

    return (new_position,);
}

func increase_position_size_internal{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    position: PerpPosition, added_size: felt, added_price: felt, fee_taken: felt, funding_idx: felt
) -> (position: PerpPosition) {
    alloc_locals;

    let (collateral_decimals) = token_decimals(global_config.collateral_token);

    let (synthetic_decimals: felt) = token_decimals(position.position_header.synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(position.position_header.synthetic_token);

    let prev_nominal = position.position_size * position.entry_price;
    let new_nominal = added_size * added_price;

    let (average_entry_price, _) = unsigned_div_rem(
        prev_nominal + new_nominal, position.position_size + added_size
    );

    let mm_rate = 3;  // 2% of 100
    // let maintnance_margin = (prev_nominal + new_nominal) * mm_rate

    tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals -
        collateral_decimals;
    let (multiplier: felt) = pow(10, decimal_conversion);

    // & apply funding
    let (margin_after_funding) = apply_funding(position, funding_idx);

    let updated_size = position.position_size + added_size;

    let (bankruptcy_price, liquidation_price, new_position_hash) = update_position_info(
        position.position_header.hash,
        position.order_side,
        position.position_header.synthetic_token,
        updated_size,
        margin_after_funding - fee_taken,
        average_entry_price,
        funding_idx,
        position.position_header.allow_partial_liquidations,
        position.vlp_supply,
    );

    // let (bankruptcy_price: felt) = _get_bankruptcy_price(
    //     average_entry_price,
    //     margin_after_funding - fee_taken,
    //     updated_size,
    //     position.order_side,
    //     position.position_header.synthetic_token,
    // );
    // let (liquidation_price: felt) = _get_liquidation_price(
    //     average_entry_price,
    //     updated_size,
    //     margin_after_funding - fee_taken,
    //     position.order_side,
    //     position.position_header.synthetic_token,
    //     position.position_header.allow_partial_liquidations,
    // );

    // let (new_position_hash: felt) = _hash_position_internal(
    //     position.position_header.hash,
    //     position.order_side,
    //     updated_size,
    //     average_entry_price,
    //     liquidation_price,
    //     funding_idx,
    //     position.vlp_supply,
    // );

    let new_position = PerpPosition(
        position.position_header,
        position.order_side,
        updated_size,
        margin_after_funding - fee_taken,
        average_entry_price,
        liquidation_price,
        bankruptcy_price,
        funding_idx,
        position.vlp_supply,
        position.index,
        new_position_hash,
    );

    return (new_position,);
}

func reduce_position_size_internal{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    position: PerpPosition, reduction_size: felt, price: felt, fee_taken: felt, funding_idx: felt
) -> (position: PerpPosition) {
    alloc_locals;

    let new_size = position.position_size - reduction_size;

    let realized_pnl = _get_pnl(
        position.order_side,
        reduction_size,
        position.entry_price,
        price,
        position.position_header.synthetic_token,
    );

    // & apply funding
    let (margin_after_funding) = apply_funding(position, funding_idx);

    let updated_margin = margin_after_funding + realized_pnl - fee_taken;

    let (bankruptcy_price, liquidation_price, new_position_hash) = update_position_info(
        position.position_header.hash,
        position.order_side,
        position.position_header.synthetic_token,
        new_size,
        updated_margin,
        position.entry_price,
        funding_idx,
        position.position_header.allow_partial_liquidations,
        position.vlp_supply,
    );

    let new_position = PerpPosition(
        position.position_header,
        position.order_side,
        new_size,
        updated_margin,
        position.entry_price,
        liquidation_price,
        bankruptcy_price,
        funding_idx,
        position.vlp_supply,
        position.index,
        new_position_hash,
    );

    return (new_position,);
}

func flip_position_side_internal{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    position: PerpPosition, reduction_size: felt, price: felt, fee_taken: felt, funding_idx: felt
) -> (position: PerpPosition) {
    alloc_locals;

    let new_size = reduction_size - position.position_size;

    let realized_pnl = _get_pnl(
        position.order_side,
        position.position_size,
        position.entry_price,
        price,
        position.position_header.synthetic_token,
    );

    // & apply funding
    let (margin_after_funding) = apply_funding(position, funding_idx);

    let updated_margin = margin_after_funding + realized_pnl - fee_taken;

    let new_order_side = is_not_zero(1 - position.order_side);

    let (bankruptcy_price, liquidation_price, new_position_hash) = update_position_info(
        position.position_header.hash,
        new_order_side,
        position.position_header.synthetic_token,
        new_size,
        updated_margin,
        price,
        funding_idx,
        position.position_header.allow_partial_liquidations,
        position.vlp_supply,
    );

    let new_position = PerpPosition(
        position.position_header,
        new_order_side,
        new_size,
        updated_margin,
        price,
        liquidation_price,
        bankruptcy_price,
        funding_idx,
        position.vlp_supply,
        position.index,
        new_position_hash,
    );

    return (new_position,);
}

func close_position_partialy_internal{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    position: PerpPosition,
    reduction_size: felt,
    close_price: felt,
    fee_taken: felt,
    funding_idx: felt,
) -> (position: PerpPosition, return_collateral: felt) {
    alloc_locals;

    let updated_size = position.position_size - reduction_size;

    // & apply funding
    let (margin_after_funding) = apply_funding(position, funding_idx);

    let (reduction_margin: felt, _) = unsigned_div_rem(
        reduction_size * margin_after_funding, position.position_size
    );

    let realized_pnl = _get_pnl(
        position.order_side,
        reduction_size,
        position.entry_price,
        close_price,
        position.position_header.synthetic_token,
    );

    let return_collateral = reduction_margin + realized_pnl - fee_taken;

    assert_le(0, return_collateral);

    let margin = margin_after_funding - reduction_margin;

    let (new_position_hash: felt) = _hash_position_internal(
        position.position_header.hash,
        position.order_side,
        updated_size,
        position.entry_price,
        position.liquidation_price,
        funding_idx,
        position.vlp_supply,
    );

    let updated_position = PerpPosition(
        position.position_header,
        position.order_side,
        updated_size,
        margin,
        position.entry_price,
        position.liquidation_price,
        position.bankruptcy_price,
        funding_idx,
        position.vlp_supply,
        position.index,
        new_position_hash,
    );

    return (updated_position, return_collateral);
}

func close_position_internal{
    range_check_ptr, funding_info: FundingInfo*, global_config: GlobalConfig*
}(position: PerpPosition, close_price: felt, fee_taken: felt, funding_idx: felt) -> (
    collateral_returned: felt
) {
    alloc_locals;

    // & apply funding
    let (margin_after_funding) = apply_funding(position, funding_idx);

    let realized_pnl = _get_pnl(
        position.order_side,
        position.position_size,
        position.entry_price,
        close_price,
        position.position_header.synthetic_token,
    );

    let return_collateral = margin_after_funding + realized_pnl - fee_taken;

    assert_le(0, return_collateral);

    return (return_collateral,);
}

// * ====================================================================================

func is_position_liquidatable{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    position: PerpPosition, index_price: felt
) -> (is_liquidatable: felt) {
    alloc_locals;

    // TODO: VERIFY THE INDEX PRICE IS WITHIN PRICE RANGES

    if (position.order_side == 1) {
        let is_liquidatable = is_le(index_price + 1, position.liquidation_price);
        return (is_liquidatable,);
    } else {
        let is_liquidatable = is_le(position.liquidation_price + 1, index_price);
        return (is_liquidatable,);
    }
}

func get_liquidatable_value{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(position: PerpPosition, market_price: felt, funding_idx: felt) -> (
    leftover_value: felt, should_partially_liquidate: felt
) {
    alloc_locals;

    let should_partially_liquidate = _should_partially_liquidate(
        position.position_header.synthetic_token,
        position.position_size,
        position.order_side,
        position.position_header.allow_partial_liquidations,
        position.bankruptcy_price,
        market_price,
    );

    if (should_partially_liquidate == 1) {
        let (collateral_decimals) = token_decimals(global_config.collateral_token);

        let (synthetic_decimals: felt) = token_decimals(position.position_header.synthetic_token);
        let (synthetic_price_decimals: felt) = price_decimals(
            position.position_header.synthetic_token
        );

        tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals -
            collateral_decimals;
        let (multiplier: felt) = pow(10, decimal_conversion);

        // & apply funding
        let (margin_after_funding) = apply_funding(position, funding_idx);

        let im_rate = 67;  // 6.7 %
        let liquidator_fee_rate = 5;  // 0.5 %

        let price_delta = market_price - position.entry_price + 2 * position.order_side *
            position.entry_price - 2 * position.order_side * market_price;

        let s1 = margin_after_funding * multiplier;
        let s2 = position.position_size * price_delta;

        let (new_size, _) = unsigned_div_rem(
            (s1 - s2) * 1000, market_price * (im_rate + liquidator_fee_rate)
        );

        let liquidatable_size = position.position_size - new_size;

        return (liquidatable_size, should_partially_liquidate);
    } else {
        return (position.position_size, should_partially_liquidate);
    }
}

// =======================================================================================================

// Todo: Liquidate position  (use validate_price_in_range)
func liquidate_position_partialy_internal{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(position: PerpPosition, liquidation_size: felt, close_price: felt, funding_idx: felt) -> (
    position: PerpPosition, liquidator_fee: felt
) {
    alloc_locals;

    let (collateral_decimals) = token_decimals(global_config.collateral_token);

    let (synthetic_decimals: felt) = token_decimals(position.position_header.synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(position.position_header.synthetic_token);

    tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals -
        collateral_decimals;
    let (multiplier: felt) = pow(10, decimal_conversion);

    // & apply funding
    let (margin_after_funding) = apply_funding(position, funding_idx);

    let liquidator_fee_rate = 5;  // 0.5 %
    let (liquidator_fee, _) = unsigned_div_rem(
        liquidation_size * close_price * liquidator_fee_rate, multiplier * 1000
    );

    let new_size = position.position_size - liquidation_size;

    let margin = margin_after_funding - liquidator_fee;

    let (bankruptcy_price, liquidation_price, new_position_hash) = update_position_info(
        position.position_header.hash,
        position.order_side,
        position.position_header.synthetic_token,
        new_size,
        margin,
        position.entry_price,
        funding_idx,
        position.position_header.allow_partial_liquidations,
        position.vlp_supply,
    );

    let new_position = PerpPosition(
        position.position_header,
        position.order_side,
        new_size,
        margin,
        position.entry_price,
        liquidation_price,
        bankruptcy_price,
        funding_idx,
        position.vlp_supply,
        position.index,
        new_position_hash,
    );

    return (new_position, liquidator_fee);
}

func liquidate_position_fully_internal{
    range_check_ptr, funding_info: FundingInfo*, global_config: GlobalConfig*
}(position: PerpPosition, close_price: felt, funding_idx: felt) -> (
    leftover_value: felt, liquidator_fee: felt
) {
    alloc_locals;

    let (collateral_decimals) = token_decimals(global_config.collateral_token);

    let (synthetic_decimals: felt) = token_decimals(position.position_header.synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(position.position_header.synthetic_token);

    tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals -
        collateral_decimals;
    let (multiplier: felt) = pow(10, decimal_conversion);

    // & apply funding
    let (margin_after_funding) = apply_funding(position, funding_idx);

    let liquidator_fee_rate = 5;  // 0.5 %
    let (liquidator_fee, _) = unsigned_div_rem(
        position.position_size * close_price * liquidator_fee_rate, multiplier * 1000
    );

    let leftover_value = _get_leftover_value(
        position.order_side,
        position.position_size,
        position.bankruptcy_price,
        close_price,
        multiplier,
    );

    // ? if this is less than zero it should come out of the insurance fund else add it to insurance fund

    return (leftover_value, liquidator_fee);
}

// -----------------------------------------------------------------------

func modify_margin{range_check_ptr, poseidon_ptr: PoseidonBuiltin*, global_config: GlobalConfig*}(
    position: PerpPosition, margin_change: felt
) -> (position: PerpPosition) {
    alloc_locals;

    // Todo: Maybe have a constant fee here (like 5 cents or something)

    let margin = position.margin + margin_change;

    assert_le(1, margin);

    let (bankruptcy_price, liquidation_price, new_position_hash) = update_position_info(
        position.position_header.hash,
        position.order_side,
        position.position_header.synthetic_token,
        position.position_size,
        margin,
        position.entry_price,
        position.last_funding_idx,
        position.position_header.allow_partial_liquidations,
        position.vlp_supply,
    );

    let new_position = PerpPosition(
        position.position_header,
        position.order_side,
        position.position_size,
        margin,
        position.entry_price,
        liquidation_price,
        bankruptcy_price,
        position.last_funding_idx,
        position.vlp_supply,
        position.index,
        new_position_hash,
    );

    return (new_position,);
}

// ---------------------------------------------------
func get_current_leverage{range_check_ptr, global_config: GlobalConfig*}(
    position: PerpPosition, index_price: felt
) -> (felt, felt) {
    alloc_locals;

    if (index_price == 0) {
        return (0, 0);
    }

    let synthetic_token = position.position_header.synthetic_token;

    let pnl = _get_pnl(
        position.order_side,
        position.position_size,
        position.entry_price,
        index_price,
        synthetic_token,
    );

    let (collateral_decimals) = token_decimals(global_config.collateral_token);

    let (synthetic_decimals: felt) = token_decimals(synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(synthetic_token);

    tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals -
        collateral_decimals - global_config.leverage_decimals;
    let (multiplier: felt) = pow(10, decimal_conversion);

    let is_liquidatable = is_le(pnl, -position.margin);
    if (is_liquidatable == 1) {
        return (0, 0);
    }

    let (current_leverage: felt, _) = unsigned_div_rem(
        index_price * position.position_size, (position.margin + pnl) * multiplier
    );

    return (1, current_leverage);
}
