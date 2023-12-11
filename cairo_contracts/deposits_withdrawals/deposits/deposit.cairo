// %builtins output pedersen range_check ecdsa

from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.dict_access import DictAccess

from helpers.utils import Note
from deposits_withdrawals.deposits.deposit_utils import (
    Deposit,
    get_deposit_notes,
    verify_deposit_notes,
)
from helpers.spot_helpers.dict_updates import deposit_state_dict_updates

from rollup.output_structs import DepositTransactionOutput, write_deposit_info_to_output

from rollup.global_config import GlobalConfig

func verify_deposit{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    deposit_output_ptr: DepositTransactionOutput*,
    state_dict: DictAccess*,
    note_updates: Note*,
    global_config: GlobalConfig*,
}() {
    alloc_locals;

    // & This is the public on_chain deposit information
    local deposit: Deposit;
    %{
        # current_deposit = deposits.pop(0)

        memory[ids.deposit.address_ + DEPOSIT_ID_OFFSET] = int(current_deposit["deposit_id"])
        memory[ids.deposit.address_ + DEPOSIT_TOKEN_OFFSET] = int(current_deposit["deposit_token"])
        memory[ids.deposit.address_ + DEPOSIT_AMOUNT_OFFSET] = int(current_deposit["deposit_amount"])
        memory[ids.deposit.address_ + DEPOSIT_ADDRESS_OFFSET] = int(current_deposit["stark_key"])
    %}

    let (deposit_notes_len: felt, deposit_notes: Note*) = get_deposit_notes();

    // & Verify the newly minted deposit notes have the same amount and token as the on-chain deposit
    // & Also verify that the deposit was signed by the owner of the deposit address
    verify_deposit_notes(deposit_notes_len, deposit_notes, deposit);

    // Update the note dict
    deposit_state_dict_updates(deposit_notes_len, deposit_notes);

    // Write the deposit info to the output
    write_deposit_info_to_output(deposit);

    return ();
}
