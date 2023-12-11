from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, EcOpBuiltin
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash
from starkware.cairo.common.ec import EcPoint
from starkware.cairo.common.math import assert_not_equal
from starkware.cairo.common.bool import TRUE, FALSE

from helpers.utils import Note, hash_notes_array, verify_note_hashes
from helpers.signatures import is_signature_valid, sum_pub_keys
from helpers.spot_helpers.dict_updates import _update_multi_inner

from order_tabs.close_order_tab import handle_order_tab_input
from order_tabs.order_tab import OrderTab, verify_order_tab_hash
from order_tabs.update_dicts import remove_tab_from_state

from forced_escapes.escape_helpers import (
    write_escape_response_to_output,
    prove_invalid_leaf,
    EscapeOutput,
    ORDER_TAB_ESCAPE,
)

func execute_forced_tab_escape{
    poseidon_ptr: PoseidonBuiltin*,
    ec_op_ptr: EcOpBuiltin*,
    range_check_ptr,
    state_dict: DictAccess*,
    escape_output_ptr: EscapeOutput*,
    note_updates: Note*,
}() {
    alloc_locals;

    let (__fp__, _) = get_fp_and_pc();

    // ? GET THE INPUT
    local escape_id: felt;
    %{
        tab_escape = current_transaction["tab_escape"]
        ids.escape_id = int(tab_escape["escape_id"])

        order_tab_input = tab_escape["order_tab"]
    %}
    local order_tab: OrderTab;
    handle_order_tab_input(&order_tab);

    verify_order_tab_hash(order_tab);

    let (escape_message_hash: felt) = _hash_tab_escape_message(escape_id, order_tab.hash);

    local signature_r: felt;
    local signature_s: felt;
    %{
        signature = tab_escape["signature"]
        ids.signature_r = int(signature[0])
        ids.signature_s = int(signature[1])
    %}

    if (nondet %{ tab_escape["is_valid"] %} != 0) {
        // ! The escape is valid and can be executed

        let (valid: felt) = is_signature_valid(
            escape_message_hash, order_tab.tab_header.pub_key, signature_r, signature_s
        );

        if (valid == FALSE) {
            write_escape_response_to_output(
                escape_id, escape_message_hash, FALSE, ORDER_TAB_ESCAPE, signature_r, signature_s
            );
            return ();
        }

        remove_tab_from_state(order_tab);

        // ? Write the Escape info to the output ----------------
        write_escape_response_to_output(
            escape_id, escape_message_hash, TRUE, ORDER_TAB_ESCAPE, signature_r, signature_s
        );
        return ();
    } else {
        // ! The escape is invalid and should be rejected

        local valid_leaf: felt;
        %{ ids.valid_leaf = int(tab_escape["valid_leaf"]) %}

        prove_invalid_leaf(order_tab.tab_idx, order_tab.hash, valid_leaf);

        // ? Write the Escape info to the output ----------------
        write_escape_response_to_output(
            escape_id, escape_message_hash, FALSE, ORDER_TAB_ESCAPE, signature_r, signature_s
        );
        return ();
    }
}

// * --------------------
func _hash_tab_escape_message{poseidon_ptr: PoseidonBuiltin*}(escape_id: felt, tab_hash: felt) -> (
    res: felt
) {
    alloc_locals;

    let (message_hash: felt) = poseidon_hash(tab_hash, escape_id);

    return (message_hash,);
}
