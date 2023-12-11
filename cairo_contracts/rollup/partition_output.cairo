from starkware.cairo.common.cairo_builtins import PoseidonBuiltin

from rollup.output_structs import (
    NoteDiffOutput,
    PerpPositionOutput,
    OrderTabOutput,
    ZeroOutput,
    OnChainMMActionOutput,
    WithdrawalTransactionOutput,
    DepositTransactionOutput,
    AccumulatedHashesOutput,
)
from rollup.global_config import GlobalConfig, init_output_structs

from forced_escapes.escape_helpers import EscapeOutput, PositionEscapeOutput

func partition_output{output_ptr, range_check_ptr, poseidon_ptr: PoseidonBuiltin*}(
    global_config: GlobalConfig*
) -> (
    accumulated_hashes: AccumulatedHashesOutput*,
    deposit_output_ptr: DepositTransactionOutput*,
    withdraw_output_ptr: WithdrawalTransactionOutput*,
    onchain_mm_action_output_ptr: OnChainMMActionOutput*,
    escape_output_ptr: EscapeOutput*,
    position_escape_output_ptr: PositionEscapeOutput*,
    note_output_ptr: NoteDiffOutput*,
    position_output_ptr: PerpPositionOutput*,
    tab_output_ptr: OrderTabOutput*,
    empty_output_ptr: ZeroOutput*,
) {
    alloc_locals;

    // ? DexState and GlobalConfig
    local config_output_ptr: felt* = cast(output_ptr, felt*);
    let (config_output_ptr: felt*) = init_output_structs(config_output_ptr, global_config);

    // ? Accumulated hashes
    local accumulated_hashes: AccumulatedHashesOutput* = cast(
        config_output_ptr, AccumulatedHashesOutput*
    );
    // ? Deposits
    local deposit_output_ptr: DepositTransactionOutput* = cast(
        accumulated_hashes + global_config.chain_ids_len * AccumulatedHashesOutput.SIZE,
        DepositTransactionOutput*,
    );
    // ? Withdrawals
    local withdraw_output_ptr: WithdrawalTransactionOutput* = cast(
        deposit_output_ptr + global_config.dex_state.n_deposits * DepositTransactionOutput.SIZE,
        WithdrawalTransactionOutput*,
    );
    // ? MM Actions
    local onchain_mm_action_output_ptr: OnChainMMActionOutput* = cast(
        withdraw_output_ptr + global_config.dex_state.n_withdrawals *
        WithdrawalTransactionOutput.SIZE,
        OnChainMMActionOutput*,
    );
    // ? Escape Outputs
    local escape_output_ptr: EscapeOutput* = cast(
        onchain_mm_action_output_ptr + global_config.dex_state.n_onchain_mm_actions *
        OnChainMMActionOutput.SIZE,
        EscapeOutput*,
    );
    // ? Position Escape Outputs
    local position_escape_output_ptr: PositionEscapeOutput* = cast(
        escape_output_ptr + (
            global_config.dex_state.n_note_escapes + global_config.dex_state.n_tab_escapes
        ) * EscapeOutput.SIZE,
        PositionEscapeOutput*,
    );
    // ? Note updates
    local note_output_ptr: NoteDiffOutput* = cast(
        position_escape_output_ptr + global_config.dex_state.n_position_escapes *
        PositionEscapeOutput.SIZE,
        NoteDiffOutput*,
    );
    // ? Positon updates
    local position_output_ptr: PerpPositionOutput* = cast(
        note_output_ptr + global_config.dex_state.n_output_notes * NoteDiffOutput.SIZE,
        PerpPositionOutput*,
    );
    // ? Order tab updates
    local tab_output_ptr: OrderTabOutput* = cast(
        position_output_ptr + global_config.dex_state.n_output_positions * PerpPositionOutput.SIZE,
        OrderTabOutput*,
    );
    // ? Zero outputs
    local empty_output_ptr: ZeroOutput* = cast(
        tab_output_ptr + global_config.dex_state.n_output_tabs * OrderTabOutput.SIZE, ZeroOutput*
    );

    return (
        accumulated_hashes,
        deposit_output_ptr,
        withdraw_output_ptr,
        onchain_mm_action_output_ptr,
        escape_output_ptr,
        position_escape_output_ptr,
        note_output_ptr,
        position_output_ptr,
        tab_output_ptr,
        empty_output_ptr,
    );
}
