from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin, BitwiseBuiltin
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.registers import get_fp_and_pc

from helpers.utils import Note, sum_notes
from helpers.spot_helpers.dict_updates import _update_multi_inner

func execute_note_split{
    poseidon_ptr: PoseidonBuiltin*, range_check_ptr, state_dict: DictAccess*, note_updates: Note*
}() {
    alloc_locals;

    local token: felt;
    local notes_in_len: felt;
    local notes_in: Note*;
    local new_note: Note;
    local refund_note: Note;

    let (__fp__, _) = get_fp_and_pc();
    handle_inputs(&token, &notes_in_len, &notes_in, &new_note, &refund_note);

    verify_notes_consistencies(notes_in_len, notes_in, new_note, refund_note, token);

    // ? Update the state
    _update_multi_inner(notes_in_len, notes_in);

    store_output_notes(new_note, refund_note);

    return ();
}

func verify_notes_consistencies{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(notes_in_len: felt, notes_in: Note*, new_note: Note, refund_note: Note, token: felt) {
    let (notes_in_sum: felt) = sum_notes(notes_in_len, notes_in, token, 0);
    let notes_out_sum: felt = new_note.amount + refund_note.amount;

    assert notes_out_sum = notes_in_sum;
    assert new_note.token = token;

    let note_in1 = notes_in[0];
    let note_in2 = notes_in[notes_in_len - 1];

    assert note_in1.address.x = new_note.address.x;
    assert note_in1.blinding_factor = new_note.blinding_factor;

    if (refund_note.amount != 0) {
        assert note_in2.address.x = refund_note.address.x;
        assert note_in2.blinding_factor = refund_note.blinding_factor;

        return ();
    } else {
        return ();
    }
}

func store_output_notes{
    poseidon_ptr: PoseidonBuiltin*, state_dict: DictAccess*, note_updates: Note*
}(new_note: Note, refund_note: Note) {
    alloc_locals;

    // * Add the new note to the state dict
    let state_dict_ptr = state_dict;
    assert state_dict_ptr.key = new_note.index;
    assert state_dict_ptr.prev_value = 0;
    assert state_dict_ptr.new_value = new_note.hash;

    // ? store to an array used for program outputs
    assert note_updates[0] = new_note;
    let note_updates = &note_updates[1];

    %{ leaf_node_types[ids.new_note.index] = "note" %}
    %{
        note_output_idxs[ids.new_note.index] = note_outputs_len 
        note_outputs_len += 1
    %}

    let state_dict = state_dict + DictAccess.SIZE;

    // * if refund_note.amount != 0 add to the state dict
    if (refund_note.amount != 0) {
        let state_dict_ptr = state_dict;
        assert state_dict_ptr.key = refund_note.index;
        assert state_dict_ptr.prev_value = 0;
        assert state_dict_ptr.new_value = refund_note.hash;

        // ? store to an array used for program outputs
        assert note_updates[0] = refund_note;
        let note_updates = &note_updates[1];

        %{ leaf_node_types[ids.refund_note.index] = "note" %}
        %{
            note_output_idxs[ids.refund_note.index] = note_outputs_len 
            note_outputs_len += 1
        %}

        let state_dict = state_dict + DictAccess.SIZE;

        return ();
    } else {
        return ();
    }
}

//

func handle_inputs{poseidon_ptr: PoseidonBuiltin*}(
    token: felt*, notes_in_len: felt*, notes_in: Note**, new_note: Note*, refund_note: Note*
) {
    %{
        memory[ids.token] = int(current_split_info["token"])

        input_notes = current_split_info["notes_in"]

        memory[ids.notes_in_len] = len(input_notes)
        memory[ids.notes_in] = notes_ = segments.add()
        for i in range(len(input_notes)):
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET+0] = int(input_notes[i]["address"]["x"])
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET+1] = int(input_notes[i]["address"]["y"])
            memory[notes_ + i* NOTE_SIZE + TOKEN_OFFSET] = int(input_notes[i]["token"])
            memory[notes_ + i* NOTE_SIZE + AMOUNT_OFFSET] = int(input_notes[i]["amount"])
            memory[notes_ + i* NOTE_SIZE + BLINDING_FACTOR_OFFSET] = int(input_notes[i]["blinding"])
            memory[notes_ + i* NOTE_SIZE + INDEX_OFFSET] = int(input_notes[i]["index"])
            memory[notes_ + i* NOTE_SIZE + HASH_OFFSET] = int(input_notes[i]["hash"])


        new_note = current_split_info["new_note"]
        memory[ids.new_note.address_ + ADDRESS_OFFSET+0] = int(new_note["address"]["x"])
        memory[ids.new_note.address_ + ADDRESS_OFFSET+1] = int(new_note["address"]["y"])
        memory[ids.new_note.address_ + TOKEN_OFFSET] = int(new_note["token"])
        memory[ids.new_note.address_ + AMOUNT_OFFSET] = int(new_note["amount"])
        memory[ids.new_note.address_ + BLINDING_FACTOR_OFFSET] = int(new_note["blinding"])
        memory[ids.new_note.address_ + INDEX_OFFSET] = int(new_note["index"])
        memory[ids.new_note.address_ + HASH_OFFSET] = int(new_note["hash"])


        refund_note_addr = ids.refund_note.address_
        refund_note__  = current_split_info["refund_note"]
        if refund_note__ is not None:
            memory[refund_note_addr + ADDRESS_OFFSET+0] = int(refund_note__["address"]["x"])
            memory[refund_note_addr + ADDRESS_OFFSET+1] = int(refund_note__["address"]["y"])
            memory[refund_note_addr + TOKEN_OFFSET] = int(refund_note__["token"])
            memory[refund_note_addr + AMOUNT_OFFSET] = int(refund_note__["amount"])
            memory[refund_note_addr + BLINDING_FACTOR_OFFSET] = int(refund_note__["blinding"])
            memory[refund_note_addr + INDEX_OFFSET] = int(refund_note__["index"])
            memory[refund_note_addr + HASH_OFFSET] = int(refund_note__["hash"])
        else:
            memory[refund_note_addr + ADDRESS_OFFSET+0] = 0
            memory[refund_note_addr + ADDRESS_OFFSET+1] = 0
            memory[refund_note_addr + TOKEN_OFFSET] = 0
            memory[refund_note_addr + AMOUNT_OFFSET] = 0
            memory[refund_note_addr + BLINDING_FACTOR_OFFSET] = 0
            memory[refund_note_addr + INDEX_OFFSET] = 0
            memory[refund_note_addr + HASH_OFFSET] = 0
    %}

    return ();
}

//

//
