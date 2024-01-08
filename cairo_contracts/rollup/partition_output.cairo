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

    return (
        accumulated_hashes,
        deposit_output_ptr,
        withdraw_output_ptr,
        onchain_mm_action_output_ptr,
        escape_output_ptr,
        position_escape_output_ptr,
    );
}

// assert output[0] = 36636218526285297354448002014395229700574155562974365876224;
// assert output[1] = 259401622558728448576186006637564770034896685737106709938187;
// assert output[2] = 3023736918698719093291411456633828535178694537555173214431264691846072323594;

// assert output[3] = 42913320261671978118283368359215069945113761482743606149120;
// assert output[4] = 259401622558728450694097469234277639142418060295408596287497;
// assert output[5] = 722398298752804971299597047252468542119685234477633699941138651141675297443;

// assert output[6] = 69711283583141489161181612305138915912151083312355701948416;
// assert output[7] = 13142484449898816628063614934573895529641521082329540329483;
// assert output[8] = 1641255107799178482612869373884043412164918131756239247343505151921661675392;

// assert output[9] = 119928097466234935271847653204012846996979738971176995651584;
// assert output[10] = 13135148594426404444200438316584911377659130375480606195721;
// assert output[11] = 1834897599728193794189896781444625701900400356064547707674442015221286917672;

// 31397566065441383768254127515908241415423938665803317245949
// 259401622558728448576186006637564770034896685737106709938187
// 3023736918698719093291411456633828535178694537555173214431264691846072323594

// 37666863382084717510506709262109202880201331430487859918845
// 259401622558728450694097469234277639142418060295408596287497
// 722398298752804971299597047252468542119685234477633699941138651141675297443

// 69652830006715522793629640291669019839338748538086583157416
// 13142484449898816628063614934573895529641521082329540329483
// 1641255107799178482612869373884043412164918131756239247343505151921661675392

// 119495645620815990847547632728638254343427638956051300860584
// 13135148594426404444200438316584911377659130375480606195721
// 1834897599728193794189896781444625701900400356064547707674442015221286917672
