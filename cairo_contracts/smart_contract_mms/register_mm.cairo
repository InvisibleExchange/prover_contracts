from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin, BitwiseBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.math import assert_le
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.squash_dict import squash_dict

from helpers.utils import Note, construct_new_note
from helpers.signatures import verify_close_order_tab_signature

from perpetuals.order.order_structs import CloseOrderFields
from perpetuals.transaction.perp_transaction import get_perp_position

from rollup.output_structs import write_mm_registration_to_output, OnChainMMActionOutput
from rollup.global_config import GlobalConfig

from perpetuals.order.order_hash import verify_position_hash

from smart_contract_mms.register_mm_helpers import (
    verify_register_mm_sig,
    get_updated_position,
    update_state_after_position_register,
)

func register_mm{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    onchain_mm_action_output_ptr: OnChainMMActionOutput*,
    global_config: GlobalConfig*,
}() {
    alloc_locals;

    let (__fp__, _) = get_fp_and_pc();

    // * Position

    // ? get position, close order fields
    %{ prev_position = current_order["prev_position"] %}
    let position = get_perp_position();
    verify_position_hash(position);

    local vlp_token: felt;
    %{ ids.vlp_token = current_order["vlp_token"] %}

    // ? hash the inputs and verify signature
    verify_register_mm_sig(position, vlp_token);

    // ? get vlp amount
    let vlp_amount = position.margin;

    // ? update the position
    let new_position = get_updated_position(position, vlp_amount, vlp_token);

    // ? update the state_dict
    update_state_after_position_register(position, new_position);

    // ? update the output
    write_mm_registration_to_output(
        position.position_header.position_address, vlp_token, vlp_amount
    );

    return ();
}
