from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, EcOpBuiltin
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.math import assert_not_equal

from rollup.global_config import GlobalConfig
from helpers.utils import Note
from perpetuals.funding.funding import FundingInfo

const NOTE_ESCAPE = 0;
const ORDER_TAB_ESCAPE = 1;

struct EscapeOutput {
    batched_escape_info: felt,  // escape_id (32 bits) | is_valid (8 bits) | escape_type (8 bits) |
    escape_message_hash: felt,
    signature_r: felt,
    signature_s: felt,
}

struct PositionEscapeOutput {
    batched_escape_info: felt,  // escape_value (64 bits) | escape_id (32 bits) | is_valid (8 bits) |
    escape_message_hash: felt,
    signature_a_r: felt,
    signature_a_s: felt,
    signature_b_r: felt,
    signature_b_s: felt,
}

// * --------------------
// ? We only need escape value when escaping positions
func write_escape_response_to_output{range_check_ptr, escape_output_ptr: EscapeOutput*}(
    escape_id: felt,
    escape_message_hash: felt,
    is_valid: felt,
    escape_type: felt,
    signature_r: felt,
    signature_s: felt,
) {
    // & batched_escape_info format: | escape_id (32 bits) | is_valid (8 bits) | escape_type (8 bits) |
    // & escape_message_hash:      | escape_hash (256 bits)

    let batched_escape_info = escape_id * 2 ** 16 + is_valid * 2 ** 8 + escape_type;

    let escape_output = escape_output_ptr;
    assert escape_output.batched_escape_info = batched_escape_info;
    assert escape_output.escape_message_hash = escape_message_hash;
    assert escape_output.signature_r = signature_r;
    assert escape_output.signature_s = signature_s;

    let escape_output_ptr = escape_output_ptr + EscapeOutput.SIZE;

    return ();
}

// * --------------------
func write_position_escape_response_to_output{
    range_check_ptr, position_escape_output_ptr: PositionEscapeOutput*
}(
    escape_id: felt,
    escape_message_hash: felt,
    is_valid: felt,
    escape_value: felt,
    signature_a_r: felt,
    signature_a_s: felt,
    signature_b_r: felt,
    signature_b_s: felt,
) {
    // & batched_escape_info format: | escape_value (64 bits) | escape_id (32 bits) | is_valid (8 bits) |
    // & escape_message_hash:       | escape_hash (256 bits)

    let batched_escape_info = ((escape_value * 2 ** 32) + escape_id) * 2 ** 8 + is_valid;

    let escape_output = position_escape_output_ptr;
    assert escape_output.batched_escape_info = batched_escape_info;
    assert escape_output.escape_message_hash = escape_message_hash;
    assert escape_output.signature_a_r = signature_a_r;
    assert escape_output.signature_a_s = signature_a_s;
    assert escape_output.signature_b_r = signature_b_r;
    assert escape_output.signature_b_s = signature_b_s;

    let position_escape_output_ptr = position_escape_output_ptr + PositionEscapeOutput.SIZE;

    return ();
}

// * --------------------

func prove_invalid_leaf{poseidon_ptr: PoseidonBuiltin*, range_check_ptr, state_dict: DictAccess*}(
    invalid_leaf_index: felt, invalid_leaf: felt, valid_leaf: felt
) {
    assert_not_equal(invalid_leaf, valid_leaf);

    // ? This doesn't update the state, it only proves that the valid leaf is in the state (not the invalid_note)
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = invalid_leaf_index;
    assert state_dict_ptr.prev_value = valid_leaf;
    assert state_dict_ptr.new_value = valid_leaf;

    let state_dict = state_dict + DictAccess.SIZE;

    %{ leaf_node_types[ids.invalid_leaf_index] = "existance_check" %}

    return ();
}
