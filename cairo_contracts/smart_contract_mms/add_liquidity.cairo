from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.math import unsigned_div_rem

from perpetuals.transaction.perp_transaction import get_perp_position

from rollup.global_config import GlobalConfig
from rollup.output_structs import write_mm_add_liquidity_to_output, OnChainMMActionOutput

from smart_contract_mms.add_liquidity_helpers import (
    get_updated_position,
    verify_position_add_liq_sig,
)
from smart_contract_mms.register_mm_helpers import update_state_after_position_register

func add_liquidity_to_mm{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    global_config: GlobalConfig*,
    onchain_mm_action_output_ptr: OnChainMMActionOutput*,
}() {
    alloc_locals;

    // * Position

    // ? get position, close order fields
    %{ prev_position = current_order["prev_position"] %}
    let position = get_perp_position();

    local depositor: felt;
    local initial_value: felt;
    %{
        ids.depositor = int(current_order["depositor"])
        ids.initial_value = current_order["initial_value"]
    %}

    // ? hash the inputs and verify signature
    verify_position_add_liq_sig(position, depositor, initial_value);

    // ? get vlp amount
    let (vlp_amount, _) = unsigned_div_rem(initial_value * position.vlp_supply, position.margin);

    // ? update the position
    let new_position = get_updated_position(position, vlp_amount, initial_value);

    // ? update the state_dict
    update_state_after_position_register(position, new_position);

    // ? update the output
    write_mm_add_liquidity_to_output(
        new_position.position_header.position_address, depositor, initial_value, vlp_amount
    );

    return ();
}
