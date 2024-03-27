from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.pow import pow
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash_many
from starkware.cairo.common.math import unsigned_div_rem

from perpetuals.order.order_structs import PerpPosition, PositionHeader
from perpetuals.order.order_hash import _hash_position_header, _hash_position_internal

from rollup.global_config import token_decimals, price_decimals, GlobalConfig

func get_vlp_amount{poseidon_ptr: PoseidonBuiltin*, range_check_ptr, global_config: GlobalConfig*}(
    base_token: felt, base_amount: felt, quote_amount: felt, index_price: felt
) -> felt {
    alloc_locals;

    // ? calculate the right amount of vLP tokens to mint using the index price
    let (collateral_decimals) = token_decimals(global_config.collateral_token);

    let (base_decimals: felt) = token_decimals(base_token);
    let (base_price_decimals: felt) = price_decimals(base_token);

    tempvar decimal_conversion = base_decimals + base_price_decimals - collateral_decimals;
    let (multiplier: felt) = pow(10, decimal_conversion);

    let (base_nominal: felt, _) = unsigned_div_rem(base_amount * index_price, multiplier);
    let vlp_amount = base_nominal + quote_amount;

    return vlp_amount;
}

// * ================================================================================================

func get_updated_position{
    poseidon_ptr: PoseidonBuiltin*, range_check_ptr, global_config: GlobalConfig*
}(prev_position: PerpPosition, vlp_amount: felt, vlp_token: felt) -> PerpPosition {
    alloc_locals;

    // ? Assert position is not yet registered
    assert prev_position.vlp_supply = 0;

    let prev_header = prev_position.position_header;

    let (new_header_hash) = _hash_position_header(
        prev_header.synthetic_token,
        prev_header.allow_partial_liquidations,
        prev_header.position_address,
        vlp_token,
    );

    let position_header = PositionHeader(
        prev_header.synthetic_token,
        prev_header.allow_partial_liquidations,
        prev_header.position_address,
        vlp_token,
        new_header_hash,
    );

    let (new_position_hash: felt) = _hash_position_internal(
        new_header_hash,
        prev_position.order_side,
        prev_position.position_size,
        prev_position.entry_price,
        prev_position.liquidation_price,
        prev_position.last_funding_idx,
        vlp_amount,
    );

    let new_position = PerpPosition(
        position_header,
        prev_position.order_side,
        prev_position.position_size,
        prev_position.margin,
        prev_position.entry_price,
        prev_position.liquidation_price,
        prev_position.bankruptcy_price,
        prev_position.last_funding_idx,
        vlp_amount,
        prev_position.index,
        new_position_hash,
    );

    return new_position;
}

func update_state_after_position_register{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    global_config: GlobalConfig*,
    state_dict: DictAccess*,
}(position: PerpPosition, new_position: PerpPosition) {
    alloc_locals;

    // * Update the order tab hash in the state
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = position.index;
    assert state_dict_ptr.prev_value = position.hash;
    assert state_dict_ptr.new_value = new_position.hash;

    let state_dict = state_dict + DictAccess.SIZE;

    %{ leaf_node_types[ids.position.index] = "position" %}

    %{ store_output_position(ids.new_position.address_, ids.new_position.index) %}

    return ();
}

// * ================================================================================================

func verify_register_mm_sig{
    poseidon_ptr: PoseidonBuiltin*, range_check_ptr, ecdsa_ptr: SignatureBuiltin*
}(position: PerpPosition, vlp_token: felt) {
    alloc_locals;

    let msg_hash = _hash_register_message(position.hash, vlp_token);

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

func _hash_register_message{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    position_hash: felt, vlp_token: felt
) -> felt {
    alloc_locals;
    // & hash = H({position.hash, vlp_token})

    let (local arr: felt*) = alloc();
    assert arr[0] = position_hash;
    assert arr[1] = vlp_token;

    let (hash) = poseidon_hash_many(2, arr);

    return hash;
}
