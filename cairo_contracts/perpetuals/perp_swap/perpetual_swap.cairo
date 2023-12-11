// %builtins output pedersen range_check ecdsa

from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict_access import DictAccess

from helpers.utils import Note

from rollup.global_config import GlobalConfig

from helpers.perp_helpers.checks import consistency_checks, range_checks

from perpetuals.funding.funding import FundingInfo

from perpetuals.transaction.perp_transaction import execute_perpetual_transaction
from perpetuals.order.order_structs import PerpOrder

func execute_perpetual_swap{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    fee_tracker_dict: DictAccess*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}() {
    alloc_locals;

    local perp_order_a: PerpOrder;
    local perp_order_b: PerpOrder;

    let (__fp__, _) = get_fp_and_pc();
    handle_inputs(&perp_order_a, &perp_order_b);

    local spent_collateral: felt;  // this is the collateral amount being swaped
    local spent_synthetic: felt;  // This is the synthetic amount being swaped
    local fee_taken_a: felt;
    local fee_taken_b: felt;

    %{
        spent_collateral = int(current_swap["swap_data"]["spent_collateral"]) 
        spent_synthetic = int(current_swap["swap_data"]["spent_synthetic"])

        ids.spent_collateral = spent_collateral
        ids.spent_synthetic = spent_synthetic

        ids.fee_taken_a = int(current_swap["swap_data"]["fee_taken_a"])
        ids.fee_taken_b = int(current_swap["swap_data"]["fee_taken_b"])
    %}

    // ? verify consistency checks
    consistency_checks(
        perp_order_a, perp_order_b, spent_collateral, spent_synthetic, fee_taken_a, fee_taken_b
    );

    range_checks(perp_order_a, perp_order_b);

    %{
        current_order = order_a_input
        order_indexes = current_swap["indexes"]["order_a"]
        prev_pfr_note = current_swap["prev_pfr_note_a"]
        prev_position = current_swap["prev_position_a"]
        signature = current_swap["swap_data"]["signature_a"]
        is_first_fill = current_swap["is_first_fill_a"]
    %}

    // ? Execute order_a transaction
    execute_perpetual_transaction(
        perp_order_a, perp_order_b, spent_collateral, spent_synthetic, fee_taken_a
    );

    %{
        current_order = order_b_input
        order_indexes = current_swap["indexes"]["order_b"]
        prev_pfr_note = current_swap["prev_pfr_note_b"]
        prev_position = current_swap["prev_position_b"]
        signature = current_swap["swap_data"]["signature_b"]
        is_first_fill = current_swap["is_first_fill_b"]
    %}

    // ? Execute order_b transaction
    execute_perpetual_transaction(
        perp_order_b, perp_order_a, spent_collateral, spent_synthetic, fee_taken_b
    );

    return ();
}

func handle_inputs(perp_order_a: PerpOrder*, perp_order_b: PerpOrder*) {
    %{
        ##* ORDER A =============================================================

        order_a_input = current_swap["order_a"]

        order_a_addr = ids.perp_order_a.address_

        memory[order_a_addr + PERP_ORDER_ID_OFFSET] = int(order_a_input["order_id"])
        memory[order_a_addr + PERP_EXPIRATION_TIMESTAMP_OFFSET] = int(order_a_input["expiration_timestamp"])
        # Open
        pos_effect_type = None
        if order_a_input["position_effect_type"] =="Open":
            pos_effect_type = 0
        elif order_a_input["position_effect_type"] =="Modify":
                pos_effect_type = 1
        elif order_a_input["position_effect_type"] =="Close":
                pos_effect_type = 2
        else:
            raise Exception("Invalid position effect type")
        memory[order_a_addr + POSITION_EFFECT_TYPE_OFFSET] = pos_effect_type
        memory[order_a_addr + POS_ADDR_OFFSET] = int(order_a_input["pos_addr"])
        memory[order_a_addr + ORDER_SIDE_OFFSET] = 1 if order_a_input["order_side"] == "Long" else 0
        memory[order_a_addr + SYNTHETIC_TOKEN_OFFSET] = int(order_a_input["synthetic_token"])
        memory[order_a_addr + SYNTHETIC_AMOUNT_OFFSET] = int(order_a_input["synthetic_amount"])
        memory[order_a_addr + COLLATERAL_AMOUNT_OFFSET] = int(order_a_input["collateral_amount"])
        memory[order_a_addr + PERP_FEE_LIMIT_OFFSET] = int(order_a_input["fee_limit"])
        memory[order_a_addr + ORDER_HASH_OFFSET] =  int(order_a_input["hash"])



        ##* ORDER B =============================================================

        order_b_input = current_swap["order_b"]

        order_b_addr = ids.perp_order_b.address_

        memory[order_b_addr + PERP_ORDER_ID_OFFSET] = int(order_b_input["order_id"])
        memory[order_b_addr + PERP_EXPIRATION_TIMESTAMP_OFFSET] = int(order_b_input["expiration_timestamp"])
        # Open
        pos_effect_type = None
        if order_b_input["position_effect_type"] =="Open":
            pos_effect_type = 0
        elif order_b_input["position_effect_type"] =="Modify":
                pos_effect_type = 1
        elif order_b_input["position_effect_type"] =="Close":
                pos_effect_type = 2
        elif order_b_input["position_effect_type"] =="Liquidation":
                pos_effect_type = 3
        else:
            raise Exception("Invalid position effect type")
        memory[order_b_addr + POSITION_EFFECT_TYPE_OFFSET] = pos_effect_type
        memory[order_b_addr + POS_ADDR_OFFSET] = int(order_b_input["pos_addr"])
        memory[order_b_addr + ORDER_SIDE_OFFSET] = 1 if order_b_input["order_side"] == "Long" else 0
        memory[order_b_addr + SYNTHETIC_TOKEN_OFFSET] = int(order_b_input["synthetic_token"])
        memory[order_b_addr + SYNTHETIC_AMOUNT_OFFSET] = int(order_b_input["synthetic_amount"])
        memory[order_b_addr + COLLATERAL_AMOUNT_OFFSET] = int(order_b_input["collateral_amount"])
        memory[order_b_addr + PERP_FEE_LIMIT_OFFSET] = int(order_b_input["fee_limit"])
        memory[order_b_addr + ORDER_HASH_OFFSET] = int(order_b_input["hash"])
    %}

    return ();
}
