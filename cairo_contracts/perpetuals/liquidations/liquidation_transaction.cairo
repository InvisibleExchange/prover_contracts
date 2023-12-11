from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.math import unsigned_div_rem, assert_le
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.pow import pow

from helpers.utils import Note

from helpers.signatures import verify_open_order_signature

from rollup.global_config import (
    GlobalConfig,
    get_dust_amount,
    get_min_partial_liquidation_size,
    token_decimals,
    price_decimals,
)
from perpetuals.prices.prices import PriceRange, validate_price_in_range
from perpetuals.funding.funding import FundingInfo

from perpetuals.order.order_structs import PerpPosition, OpenOrderFields
from perpetuals.transaction.perp_transaction import get_perp_position, get_open_order_fields

from perpetuals.liquidations.liquidation_order import (
    LiquidationOrder,
    verify_liquidation_order_hash,
)
from perpetuals.liquidations.helpers import (
    liquidation_consistency_checks,
    liquidation_note_state_updates,
)

from perpetuals.order.perp_position import (
    construct_new_position,
    is_position_liquidatable,
    get_liquidatable_value,
    liquidate_position_partialy_internal,
    liquidate_position_fully_internal,
)

func execute_liquidation_order{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}() {
    alloc_locals;

    let (__fp__, _) = get_fp_and_pc();

    %{ prev_position = current_order["position"] %}
    let position: PerpPosition = get_perp_position();

    local open_order_fields: OpenOrderFields;
    get_open_order_fields(&open_order_fields);

    local liquidation_order: LiquidationOrder;
    handle_inputs(&liquidation_order);

    with_attr error_message("Invaild Signature") {
        %{ signature = current_liquidation["signature"] %}
        verify_liquidation_order_hash(liquidation_order, open_order_fields, position);
        verify_open_order_signature(
            liquidation_order.hash, open_order_fields.notes_in_len, open_order_fields.notes_in
        );
    }

    local market_price: felt;
    local index_price: felt;
    local funding_idx: felt;
    %{
        ids.market_price = current_liquidation["market_price"]
        ids.index_price = current_liquidation["index_price"]
        ids.funding_idx = current_liquidation["indexes"]["new_funding_idx"]
    %}

    // ? Tx consistency checks
    liquidation_consistency_checks(liquidation_order, position, open_order_fields, market_price);

    // ? validate index price in range
    // TODO: validate_price_in_range(index_price, position.position_header.synthetic_token);

    // ? Check the position is liquidatable
    let (is_liquidatable: felt) = is_position_liquidatable(position, index_price);
    assert is_liquidatable = 1;
    let (liquidatable_size: felt) = get_liquidatable_value(position, market_price);

    assert_le(1, liquidatable_size);  // ? liquidatable_size > 0
    assert_le(liquidatable_size, liquidation_order.synthetic_amount);

    // ? Liquidate position
    let (min_partial_liq_size) = get_min_partial_liquidation_size(
        position.position_header.synthetic_token
    );
    let cond1 = is_le(min_partial_liq_size, position.position_size);

    if (position.position_header.allow_partial_liquidations * cond1 == 1) {
        // ? Fully liquidate the position
        let (
            updated_position: PerpPosition, liquidator_fee: felt
        ) = liquidate_position_partialy_internal(
            position, liquidatable_size, market_price, funding_idx
        );

        // ? Open new position
        let (new_position: PerpPosition) = open_new_position(
            &liquidation_order,
            &open_order_fields,
            liquidatable_size,
            position.position_header.synthetic_token,
            market_price,
            funding_idx,
            liquidator_fee,
        );

        // ? Update the state dicts
        liquidation_note_state_updates(open_order_fields, new_position);

        // ? Store the updated partially liquidated position
        let state_dict_ptr = state_dict;
        assert state_dict_ptr.key = updated_position.index;
        assert state_dict_ptr.prev_value = position.hash;
        assert state_dict_ptr.new_value = updated_position.hash;

        let state_dict = state_dict + DictAccess.SIZE;

        %{
            leaf_node_types[ids.updated_position.index] = "position"
            store_output_position(ids.updated_position.address_, ids.updated_position.index)
        %}

        return ();
    } else {
        // ? Fully liquidate the position
        let (leftover_value: felt, liquidator_fee: felt) = liquidate_position_fully_internal(
            position, market_price, funding_idx
        );

        // // ? Update the insurance fund
        // let insurance_fund = insurance_fund + leftover_value;

        // ? Open new position
        let (new_position: PerpPosition) = open_new_position(
            &liquidation_order,
            &open_order_fields,
            position.position_size,
            position.position_header.synthetic_token,
            market_price,
            funding_idx,
            liquidator_fee,
        );

        // ? Update the state dicts
        liquidation_note_state_updates(open_order_fields, new_position);

        // ? Remove the fully liquidated position
        let state_dict_ptr = state_dict;
        assert state_dict_ptr.key = position.index;
        assert state_dict_ptr.prev_value = position.hash;
        assert state_dict_ptr.new_value = 0;

        let state_dict = state_dict + DictAccess.SIZE;

        %{ leaf_node_types[ids.position.index] = "position" %}

        return ();
    }
}

//
func open_new_position{
    range_check_ptr, poseidon_ptr: PoseidonBuiltin*, global_config: GlobalConfig*
}(
    liquidation_order: LiquidationOrder*,
    open_order_fields: OpenOrderFields*,
    liquidatable_size: felt,
    synthetic_token: felt,
    market_price: felt,
    funding_idx: felt,
    liquidator_fee: felt,
) -> (new_position: PerpPosition) {
    alloc_locals;

    // ? Get the initial margin

    let init_margin = open_order_fields.initial_margin + liquidator_fee;

    let (collateral_decimals) = token_decimals(global_config.collateral_token);

    let (synthetic_decimals: felt) = token_decimals(synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(synthetic_token);

    tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals -
        collateral_decimals;
    let (multiplier: felt) = pow(10, decimal_conversion);

    // ? Calculate the leverage
    let (scaler) = pow(10, global_config.leverage_decimals);
    let (leverage: felt, _) = unsigned_div_rem(
        liquidatable_size * market_price * scaler, init_margin * multiplier
    );

    local position_idx: felt;
    %{ ids.position_idx = current_liquidation["indexes"]["new_position_index"] %}

    // TODO: Check max leverage

    let (new_position: PerpPosition) = construct_new_position(
        liquidation_order.order_side,
        liquidation_order.synthetic_token,
        global_config.collateral_token,
        liquidatable_size,
        init_margin,
        leverage,
        open_order_fields.position_address,
        funding_idx,
        position_idx,
        0,
        open_order_fields.allow_partial_liquidations,
    );

    return (new_position,);
}

func handle_inputs(liquidation_order: LiquidationOrder*) {
    %{
        order_addr = ids.liquidation_order.address_

        memory[order_addr + ids.LiquidationOrder.order_side] = 1 if current_order["order_side"] == "Long" else 0
        memory[order_addr + ids.LiquidationOrder.synthetic_token] = int(current_order["synthetic_token"])
        memory[order_addr + ids.LiquidationOrder.synthetic_amount] = int(current_order["synthetic_amount"])
        memory[order_addr + ids.LiquidationOrder.collateral_amount] = int(current_order["collateral_amount"])
        memory[order_addr + ids.LiquidationOrder.hash] =  int(current_order["hash"])
    %}

    return ();
}
