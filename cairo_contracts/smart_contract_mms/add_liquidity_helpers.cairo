from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash_many

from perpetuals.order.order_structs import PerpPosition
from perpetuals.order.order_helpers import update_position_info

from starkware.cairo.common.ec import EcPoint

from rollup.global_config import GlobalConfig

// * ================================================================================================

func get_updated_position{
    poseidon_ptr: PoseidonBuiltin*, range_check_ptr, global_config: GlobalConfig*
}(
    prev_position: PerpPosition, added_vlp_amount: felt, added_collateral_amount: felt
) -> PerpPosition {
    alloc_locals;

    let updated_margin = prev_position.margin + added_collateral_amount;
    let updated_vlp_supply = prev_position.vlp_supply + added_vlp_amount;

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

// * ================================================================================================

func verify_position_add_liq_sig{
    poseidon_ptr: PoseidonBuiltin*, range_check_ptr, ecdsa_ptr: SignatureBuiltin*
}(position: PerpPosition, depositor: felt, collateral_amount: felt) {
    alloc_locals;

    let msg_hash = _hash_position_add_liq_message(position.hash, depositor, collateral_amount);

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

func _hash_position_add_liq_message{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    pos_hash: felt, depositor: felt, collateral_amount: felt
) -> felt {
    alloc_locals;

    // & header_hash = H({pos_hash, depositor, collateral_amount})
    let (local arr: felt*) = alloc();
    arr[0] = pos_hash;
    arr[1] = depositor;
    arr[2] = collateral_amount;

    let (hash) = poseidon_hash_many(3, arr);

    return hash;
}
