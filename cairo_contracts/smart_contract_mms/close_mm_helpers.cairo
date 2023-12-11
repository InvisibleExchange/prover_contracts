from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash_many
from starkware.cairo.common.math import unsigned_div_rem
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.bool import TRUE

from perpetuals.order.order_structs import PerpPosition
from perpetuals.order.order_helpers import update_position_info

from rollup.global_config import GlobalConfig

// * =============================================================================================

func verify_mm_close_sig{
    poseidon_ptr: PoseidonBuiltin*, range_check_ptr, ecdsa_ptr: SignatureBuiltin*
}(position: PerpPosition, initial_value_sum: felt, vlp_amount_sum: felt) {
    alloc_locals;

    let msg_hash = _hash_mm_close_message(position.hash, initial_value_sum, vlp_amount_sum);

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

func _hash_mm_close_message{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    position_hash: felt, initial_value_sum: felt, vlp_amount_sum: felt
) -> felt {
    alloc_locals;

    // & hash = H({position.hash, initial_value_sum, vlp_amount_sum})

    let (local arr: felt*) = alloc();
    assert arr[0] = position_hash;
    assert arr[1] = initial_value_sum;
    assert arr[2] = vlp_amount_sum;

    let (res) = poseidon_hash_many(3, arr);
    return res;
}
