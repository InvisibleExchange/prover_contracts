from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, EcOpBuiltin, BitwiseBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash_many
from starkware.cairo.common.ec import EcPoint
from starkware.cairo.common.uint256 import Uint256
from starkware.cairo.common.math import assert_not_equal
from starkware.cairo.common.cairo_keccak.keccak import cairo_keccak_felts_bigend
from starkware.cairo.common.bool import TRUE, FALSE

from helpers.utils import Note, hash_notes_array_solidity, verify_note_hashes
from helpers.signatures import is_signature_valid, sum_pub_keys
from helpers.spot_helpers.dict_updates import _update_multi_inner

from forced_escapes.escape_helpers import (
    write_escape_response_to_output,
    prove_invalid_leaf,
    EscapeOutput,
    NOTE_ESCAPE,
)

struct NoteEscape {
    escape_id: felt,
    //
    escape_notes_len: felt,
    escape_notes: Note*,
}

func execute_forced_note_escape{
    poseidon_ptr: PoseidonBuiltin*,
    ec_op_ptr: EcOpBuiltin*,
    range_check_ptr,
    keccak_ptr: felt*,
    bitwise_ptr: BitwiseBuiltin*,
    state_dict: DictAccess*,
    escape_output_ptr: EscapeOutput*,
    note_updates: Note*,
}() {
    alloc_locals;

    let (__fp__, _) = get_fp_and_pc();

    // ? GET THE INPUT
    local escape_info: NoteEscape;
    handle_note_escape_input(&escape_info);

    let (escape_message_hash: felt) = _hash_note_escape_message(
        escape_info.escape_id, escape_info.escape_notes_len, escape_info.escape_notes
    );

    verify_note_hashes(escape_info.escape_notes_len, escape_info.escape_notes);

    local signature_r: felt;
    local signature_s: felt;
    %{
        signature = note_escape["signature"]
        ids.signature_r = int(signature[0])
        ids.signature_s = int(signature[1])
    %}

    if (nondet %{ not note_escape["invalid_note"] %} != 0) {
        // ! The escape is valid and can be executed

        let (pub_key_sum: EcPoint) = sum_pub_keys(
            escape_info.escape_notes_len, escape_info.escape_notes, EcPoint(0, 0)
        );

        let (valid: felt) = is_signature_valid(
            escape_message_hash, pub_key_sum.x, signature_r, signature_s
        );
        if (valid == FALSE) {
            write_escape_response_to_output(
                escape_info.escape_id,
                escape_message_hash,
                FALSE,
                NOTE_ESCAPE,
                signature_r,
                signature_s,
            );
            return ();
        }

        // ? Remove the valid notes from the state --------------
        _update_multi_inner(escape_info.escape_notes_len, escape_info.escape_notes);

        // ? Write the Escape info to the output ----------------
        write_escape_response_to_output(
            escape_info.escape_id, escape_message_hash, TRUE, NOTE_ESCAPE, signature_r, signature_s
        );
        return ();
    } else {
        // ! The escape is invalid and should be rejected

        local invalid_arr_position_idx: felt;
        local valid_leaf: felt;
        %{
            for i in range(len(escape_notes)):
                if escape_notes[i]["index"] == note_escape["invalid_note"][0] and escape_notes[i]["hash"] != note_escape["invalid_note"][1]:
                    ids.invalid_arr_position_idx = i
                    break

            ids.valid_leaf = int(note_escape["invalid_note"][1])
        %}

        let invalid_note = escape_info.escape_notes[invalid_arr_position_idx];
        prove_invalid_leaf(invalid_note.index, invalid_note.hash, valid_leaf);

        write_escape_response_to_output(
            escape_info.escape_id, escape_message_hash, FALSE, NOTE_ESCAPE, signature_r, signature_s
        );
        return ();
    }
}

// * --------------------
func _hash_note_escape_message{range_check_ptr, keccak_ptr: felt*, bitwise_ptr: BitwiseBuiltin*}(
    escape_id: felt, escape_notes_len: felt, escape_notes: Note*
) -> (res: felt) {
    alloc_locals;

    let (local empty_arr: felt*) = alloc();
    assert empty_arr[0] = escape_id;

    let (hashes_arr_len: felt, hashes_arr: felt*) = hash_notes_array_solidity(
        escape_notes_len, escape_notes, 1, empty_arr
    );

    let (res: Uint256) = cairo_keccak_felts_bigend(hashes_arr_len, hashes_arr);

    let hash = res.high * 2 ** 128 + res.low;

    return (hash,);
}

// * --------------------
// * --------------------
func handle_note_escape_input{poseidon_ptr: PoseidonBuiltin*}(escape_info: NoteEscape*) {
    %{
        ##* ORDER A =============================================================

        note_escape = current_transaction["note_escape"]

        escape_info_addr = ids.escape_info.address_
        memory[escape_info_addr + ids.NoteEscape.escape_id] = int(note_escape["escape_id"])

        escape_notes = note_escape["escape_notes"]
        memory[escape_info_addr +  ids.NoteEscape.escape_notes_len] = len(escape_notes)
        memory[escape_info_addr +  ids.NoteEscape.escape_notes] = notes_ = segments.add()
        for i in range(len(escape_notes)):
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET+0] = int(escape_notes[i]["address"]["x"])
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET+1] = int(escape_notes[i]["address"]["y"])
            memory[notes_ + i* NOTE_SIZE + TOKEN_OFFSET] = int(escape_notes[i]["token"])
            memory[notes_ + i* NOTE_SIZE + AMOUNT_OFFSET] = int(escape_notes[i]["amount"])
            memory[notes_ + i* NOTE_SIZE + BLINDING_FACTOR_OFFSET] = int(escape_notes[i]["blinding"])
            memory[notes_ + i* NOTE_SIZE + INDEX_OFFSET] = int(escape_notes[i]["index"])
            memory[notes_ + i* NOTE_SIZE + HASH_OFFSET] = int(escape_notes[i]["hash"])
    %}

    return ();
}
