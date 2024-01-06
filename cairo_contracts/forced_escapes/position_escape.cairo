from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, EcOpBuiltin, BitwiseBuiltin
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.pow import pow
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.ec import EcPoint
from starkware.cairo.common.math import unsigned_div_rem
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.cairo_keccak.keccak import cairo_keccak_felts_bigend
from starkware.cairo.common.uint256 import Uint256
from starkware.cairo.common.bool import TRUE, FALSE

from perpetuals.order.perp_position import (
    construct_new_position,
    is_position_liquidatable,
    get_current_leverage,
    increase_position_size_internal,
    reduce_position_size_internal,
    flip_position_side_internal,
)
from perpetuals.order.order_structs import PerpPosition, OpenOrderFields
from perpetuals.order.order_hash import verify_position_hash, _hash_open_order_fields

from perpetuals.transaction.perp_transaction import get_perp_position, get_open_order_fields
from perpetuals.transaction.perp_transaction import close_position_internal

from perpetuals.funding.funding import FundingInfo

from rollup.global_config import GlobalConfig

from helpers.utils import (
    Note,
    verify_note_hashes,
    verify_note_hash,
    sum_notes,
    take_fee,
    get_collateral_amount,
)
from helpers.signatures import is_signature_valid, sum_pub_keys

from forced_escapes.escape_helpers import (
    write_position_escape_response_to_output,
    prove_invalid_leaf,
    PositionEscapeOutput,
)

from forced_escapes.position_escape_helpers import (
    validate_position_a,
    validate_counter_party_open_order,
    open_counter_party_position,
    update_state_after_open_swap,
    handle_counter_party_modify_order,
    update_state_after_modfiy_swap,
    close_user_position,
    _hash_position_escape_message_open,
    _hash_position_escape_message_close,
    are_signatures_valid_open,
    are_signatures_valid_close,
    verify_synthetic_token,
)

struct PositionEscape {
    escape_id: felt,
    //
    position_a: PerpPosition,
    close_price: felt,
    open_order_fields_b: felt,
}

func execute_forced_position_escape{
    poseidon_ptr: PoseidonBuiltin*,
    ec_op_ptr: EcOpBuiltin*,
    range_check_ptr,
    keccak_ptr: felt*,
    bitwise_ptr: BitwiseBuiltin*,
    state_dict: DictAccess*,
    global_config: GlobalConfig*,
    funding_info: FundingInfo*,
    fee_tracker_dict: DictAccess*,
    position_escape_output_ptr: PositionEscapeOutput*,
    note_updates: Note*,
}() {
    alloc_locals;

    let (__fp__, _) = get_fp_and_pc();

    // ? GET THE INPUT
    local escape_id: felt;
    local close_price: felt;
    local index_price: felt;
    local recipient: felt;
    %{
        position_escape = current_transaction["position_escape"]
        ids.escape_id = int(position_escape["escape_id"])
        ids.close_price = int(position_escape["close_price"])
        ids.index_price = int(position_escape["index_price"])

        recipient_ = position_escape["recipient"]
        if recipient_.startswith("0x"):
            ids.recipient = int( recipient_[2:], 16)
        else:
            ids.recipient = int(recipient_)

        prev_position = position_escape["position_a"]
    %}

    let position_a: PerpPosition = get_perp_position();

    // ? Verify hashes are valid
    verify_position_hash(position_a);

    // * VERIFY ORDER B -------------------------------------------------
    if (nondet %{ not not position_escape["open_order_fields_b"] %} != 0) {
        // ! ORDER B is an Open order (spend notes to open position) -------------
        %{ open_order_field_inputs = position_escape["open_order_fields_b"] %}

        local open_order_fields_b: OpenOrderFields;
        get_open_order_fields(&open_order_fields_b);

        let (escape_message_hash: felt) = _hash_position_escape_message_open(
            position_a, close_price, open_order_fields_b, recipient
        );

        let is_token_valid = verify_synthetic_token(position_a.position_header.synthetic_token);

        let (
            valid, signature_a_r, signature_a_s, signature_b_r, signature_b_s
        ) = are_signatures_valid_open(position_a, open_order_fields_b, escape_message_hash);
        if (valid * is_token_valid == FALSE) {
            write_position_escape_response_to_output(
                escape_id,
                escape_message_hash,
                recipient,
                FALSE,
                0,
                signature_a_r,
                signature_a_s,
                signature_b_r,
                signature_b_s,
            );
            return ();
        }

        let is_valid = validate_position_a(position_a, index_price);
        if (is_valid == FALSE) {
            // ? Position is liquidatable
            write_position_escape_response_to_output(
                escape_id,
                escape_message_hash,
                FALSE,
                recipient,
                0,
                signature_a_r,
                signature_a_s,
                signature_b_r,
                signature_b_s,
            );
            return ();
        }

        verify_note_hashes(open_order_fields_b.notes_in_len, open_order_fields_b.notes_in);
        verify_note_hash(open_order_fields_b.refund_note);

        if (nondet %{ not position_escape["is_valid_b"] %} != 0) {
            // ? All notes do not exist in the state

            local invalid_arr_position_idx: felt;
            local valid_leaf: felt;
            %{
                notes_in = position_escape["open_order_fields_b"]["notes_in"]
                for i in range(len(notes_in)):
                    if notes_in[i]["index"] == position_escape["invalid_note"][0] and notes_in[i]["hash"] != position_escape["invalid_note"][1]:
                        ids.invalid_arr_position_idx = i
                        break

                ids.valid_leaf = int(position_escape["invalid_note"][1])
            %}

            let invalid_note = open_order_fields_b.notes_in[invalid_arr_position_idx];
            prove_invalid_leaf(invalid_note.index, invalid_note.hash, valid_leaf);

            write_position_escape_response_to_output(
                escape_id,
                escape_message_hash,
                FALSE,
                recipient,
                0,
                signature_a_r,
                signature_a_s,
                signature_b_r,
                signature_b_s,
            );
            return ();
        }

        // ? Check the position is not liquidatable.

        let (leverage, is_valid) = validate_counter_party_open_order(
            position_a, close_price, open_order_fields_b
        );
        if (is_valid == FALSE) {
            write_position_escape_response_to_output(
                escape_id,
                escape_message_hash,
                FALSE,
                recipient,
                0,
                signature_a_r,
                signature_a_s,
                signature_b_r,
                signature_b_s,
            );
            return ();
        }

        let (new_position_b) = open_counter_party_position(
            position_a, open_order_fields_b, leverage
        );

        update_state_after_open_swap(position_a, open_order_fields_b, new_position_b);

        let (collateral_returned) = close_user_position(position_a, close_price);

        // * WRITE RESPONSE TO OUTPUT
        write_position_escape_response_to_output(
            escape_id,
            escape_message_hash,
            TRUE,
            recipient,
            collateral_returned,
            signature_a_r,
            signature_a_s,
            signature_b_r,
            signature_b_s,
        );
        return ();
    } else {
        // ! ORDER B is an Modify order (modify existing position) -------------
        %{ prev_position = position_escape["position_b"] %}

        let position_b: PerpPosition = get_perp_position();

        // ? Verify hashes are valid
        verify_position_hash(position_b);

        let is_token_valid = verify_synthetic_token(position_a.position_header.synthetic_token);

        let (escape_message_hash: felt) = _hash_position_escape_message_close(
            position_a, close_price, position_b, recipient
        );

        let (
            valid, signature_a_r, signature_a_s, signature_b_r, signature_b_s
        ) = are_signatures_valid_close(position_a, position_b, escape_message_hash);
        if (valid * is_token_valid == FALSE) {
            write_position_escape_response_to_output(
                escape_id,
                escape_message_hash,
                FALSE,
                recipient,
                0,
                signature_a_r,
                signature_a_s,
                signature_b_r,
                signature_b_s,
            );
            return ();
        }

        let is_valid = validate_position_a(position_a, index_price);
        if (is_valid == FALSE) {
            // ? Position is liquidatable
            write_position_escape_response_to_output(
                escape_id,
                escape_message_hash,
                FALSE,
                recipient,
                0,
                signature_a_r,
                signature_a_s,
                signature_b_r,
                signature_b_s,
            );
            return ();
        }

        if (nondet %{ not position_escape["is_position_valid_b"] %} != 0) {
            // ?Position does not exist in the state

            local valid_leaf: felt;
            %{ ids.valid_leaf = int(position_escape["valid_leaf_b"]) %}

            prove_invalid_leaf(position_b.index, position_b.hash, valid_leaf);

            write_position_escape_response_to_output(
                escape_id,
                escape_message_hash,
                FALSE,
                recipient,
                0,
                signature_a_r,
                signature_a_s,
                signature_b_r,
                signature_b_s,
            );
            return ();
        }

        let (is_valid, updated_position_b) = handle_counter_party_modify_order(
            position_a, position_b, close_price, index_price
        );
        if (is_valid == FALSE) {
            write_position_escape_response_to_output(
                escape_id,
                escape_message_hash,
                FALSE,
                recipient,
                0,
                signature_a_r,
                signature_a_s,
                signature_b_r,
                signature_b_s,
            );
            return ();
        }

        update_state_after_modfiy_swap(position_a, position_b.hash, updated_position_b);

        let (collateral_returned) = close_user_position(position_a, close_price);

        // * WRITE RESPONSE TO OUTPUT
        write_position_escape_response_to_output(
            escape_id,
            escape_message_hash,
            TRUE,
            recipient,
            collateral_returned,
            signature_a_r,
            signature_a_s,
            signature_b_r,
            signature_b_s,
        );
        return ();
    }
}
