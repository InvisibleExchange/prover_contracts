from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash_many
from starkware.cairo.common.math import unsigned_div_rem
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.bool import TRUE

from perpetuals.order.order_structs import PerpPosition
from perpetuals.order.order_helpers import update_position_info

from rollup.global_config import GlobalConfig

// * =============================================================================================

func get_return_collateral_amount{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    vlp_amount: felt, margin: felt, vlp_supply: felt
) -> felt {
    alloc_locals;

    let (return_collateral, _) = unsigned_div_rem(vlp_amount * margin, vlp_supply);

    return return_collateral;
}

func get_fee_amount{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    return_collateral_amount: felt, initial_value: felt
) -> felt {
    alloc_locals;

    let is_profitable = is_le(initial_value, return_collateral_amount);
    if (is_profitable == TRUE) {
        let (mm_fee, _) = unsigned_div_rem((return_collateral_amount - initial_value) * 20, 100);
        return mm_fee;
    } else {
        return 0;
    }
}

// *

func get_updated_position{
    poseidon_ptr: PoseidonBuiltin*, range_check_ptr, global_config: GlobalConfig*
}(
    prev_position: PerpPosition, removed_vlp_amount: felt, removed_collateral_amount: felt
) -> PerpPosition {
    alloc_locals;

    let updated_margin = prev_position.margin - removed_collateral_amount;
    let updated_vlp_supply = prev_position.vlp_supply - removed_vlp_amount;

    let (bankruptcy_price, liquidation_price, new_position_hash) = update_position_info(
        prev_position.position_header.hash,
        prev_position.order_side,
        prev_position.position_header.synthetic_token,
        prev_position.position_size,
        updated_margin,
        prev_position.entry_price,
        prev_position.last_funding_idx,
        prev_position.position_header.allow_partial_liquidations,
        updated_vlp_supply,
    );

    let new_position = PerpPosition(
        prev_position.position_header,
        prev_position.order_side,
        prev_position.position_size,
        updated_margin,
        prev_position.entry_price,
        liquidation_price,
        bankruptcy_price,
        prev_position.last_funding_idx,
        updated_vlp_supply,
        prev_position.index,
        new_position_hash,
    );

    return new_position;
}

// * =============================================================================================

func verify_position_remove_liq_sig{
    poseidon_ptr: PoseidonBuiltin*, range_check_ptr, ecdsa_ptr: SignatureBuiltin*
}(position: PerpPosition, depositor: felt, initial_value: felt, vlp_amount: felt) {
    alloc_locals;

    let msg_hash = _hash_position_remove_liq_message(
        position.hash, depositor, initial_value, vlp_amount
    );

    local sig_r: felt;
    local sig_s: felt;
    %{
        signature = current_order["signature"]
        ids.sig_r = int(signature[0])
        ids.sig_s = int(signature[1])
    %}

    verify_ecdsa_signature(
        message=msg_hash,
        public_key=position.position_header.position_address,
        signature_r=sig_r,
        signature_s=sig_s,
    );

    return ();
}

func _hash_position_remove_liq_message{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    position_hash: felt, depositor: felt, initial_value: felt, vlp_amount: felt
) -> felt {
    alloc_locals;

    // & hash = H({position.hash, depositor, initial_value, vlp_amount})

    let (local arr: felt*) = alloc();
    assert arr[0] = position_hash;
    assert arr[1] = depositor;
    assert arr[2] = initial_value;
    assert arr[3] = vlp_amount;

    let (hash) = poseidon_hash_many(4, arr);
    return hash;
}
