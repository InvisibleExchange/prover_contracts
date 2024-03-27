// %builtins output pedersen range_check ecdsa

from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict import dict_new, dict_write, dict_update, dict_squash, dict_read
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.merkle_multi_update import merkle_multi_update
from starkware.cairo.common.math import unsigned_div_rem, assert_le
from starkware.cairo.common.squash_dict import squash_dict

from helpers.utils import Note
from deposits_withdrawals.withdrawals.withdraw_utils import (
    Withdrawal,
    get_withdraw_and_refund_notes,
    verify_withdraw_notes,
)
from helpers.spot_helpers.dict_updates import withdraw_state_dict_updates

from rollup.output_structs import (
    NoteDiffOutput,
    ZeroOutput,
    WithdrawalTransactionOutput,
    write_withdrawal_info_to_output,
    write_l2_withdrawal_info_to_output,
)

from rollup.global_config import GlobalConfig, verify_valid_chain_id

func verify_withdrawal{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    global_config: GlobalConfig*,
    withdraw_output_ptr: WithdrawalTransactionOutput*,
    l2_withdrawal_outputs: WithdrawalTransactionOutput*,
    state_dict: DictAccess*,
    note_updates: Note*,
}() {
    alloc_locals;

    // & This is the public on_chain withdraw information
    local withdrawal: Withdrawal;
    local execution_gas_fee;
    %{
        memory[ids.withdrawal.address_ + WITHDRAWAL_CHAIN_OFFSET] = int(current_withdrawal["chain_id"])
        memory[ids.withdrawal.address_ + WITHDRAWAL_TOKEN_OFFSET] = int(current_withdrawal["token"])
        memory[ids.withdrawal.address_ + WITHDRAWAL_AMOUNT_OFFSET] = int(current_withdrawal["amount"])
        memory[ids.withdrawal.address_ + WITHDRAWAL_ADDRESS_OFFSET] = int(current_withdrawal["recipient"])
        memory[ids.withdrawal.address_ + WITHDRAWAL_GAS_FEE_OFFSET] = int(current_withdrawal["max_gas_fee"])

        ids.execution_gas_fee = int(current_transaction["execution_gas_fee"])
    %}

    verify_valid_chain_id(withdrawal.withdrawal_chain);

    let (
        withdraw_notes_len: felt, withdraw_notes: Note*, refund_note: Note
    ) = get_withdraw_and_refund_notes();

    // & Verify the amount to be withdrawn is less or equal the sum of notes spent
    // & also verify all the notes were signed correctly
    verify_withdraw_notes(withdraw_notes_len, withdraw_notes, refund_note, withdrawal);

    // ? assert the execution gas fee is less than max gas fee
    assert_le(execution_gas_fee, withdrawal.max_gas_fee);

    // ? Update the note dict
    withdraw_state_dict_updates(withdraw_notes_len, withdraw_notes, refund_note);

    // ? Write the withdrawal to the output
    if (withdrawal.withdrawal_chain == global_config.chain_ids[0]) {
        write_withdrawal_info_to_output(withdrawal, execution_gas_fee);
        return ();
    } else {
        write_l2_withdrawal_info_to_output(withdrawal, execution_gas_fee);
        return ();
    }
}
