from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.dict_access import DictAccess

from helpers.utils import Note, construct_new_note, sum_notes
from helpers.signatures import verify_close_order_tab_signature

from perpetuals.order.order_structs import CloseOrderFields
from perpetuals.transaction.perp_transaction import get_perp_position

from rollup.global_config import GlobalConfig, get_dust_amount

from rollup.output_structs import write_mm_remove_liquidity_to_output, OnChainMMActionOutput

from smart_contract_mms.register_mm_helpers import update_state_after_position_register

from smart_contract_mms.remove_liquidity_helpers import (
    get_return_collateral_amount,
    get_updated_position,
    verify_position_remove_liq_sig,
    get_fee_amount,
)

func remove_liquidity_from_mm{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    global_config: GlobalConfig*,
    onchain_mm_action_output_ptr: OnChainMMActionOutput*,
}() {
    alloc_locals;

    // ? get position, close order fields
    %{ prev_position = current_order["prev_position"] %}
    let position = get_perp_position();

    local depositor: felt;
    local initial_value: felt;
    local vlp_amount: felt;
    %{
        depositor_ = current_order["depositor"]
        if depositor_.startswith("0x"):
            ids.depositor = int( depositor_[2:], 16)
        else:
            ids.depositor = int(depositor_)

        ids.initial_value = current_order["initial_value"]
        ids.vlp_amount = current_order["vlp_amount"]
    %}

    // ? Verify the signature
    verify_position_remove_liq_sig(position, depositor, initial_value, vlp_amount);

    let return_collateral_amount = get_return_collateral_amount(
        vlp_amount, position.margin, position.vlp_supply
    );

    // let fee = get_fee_amount(return_collateral_amount, initial_value);

    let updated_position = get_updated_position(position, vlp_amount, return_collateral_amount);

    // ? update the state_dict
    update_state_after_position_register(position, updated_position);

    // ? update the output
    write_mm_remove_liquidity_to_output(
        position.position_header.position_address,
        depositor,
        initial_value,
        vlp_amount,
        return_collateral_amount,
    );

    return ();
}
