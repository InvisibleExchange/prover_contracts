from helpers.utils import Note
from invisible_swaps.order.invisible_order import Invisibl3Order
from perpetuals.order.order_structs import (
    PerpOrder,
    OpenOrderFields,
    CloseOrderFields,
    PerpPosition,
)
from deposits_withdrawals.deposits.deposit_utils import Deposit
from deposits_withdrawals.withdrawals.withdraw_utils import Withdrawal

from rollup.global_config import GlobalConfig

func python_define_utils() {
    %{
        output_notes = {}
        output_positions = {}
        fee_tracker_dict_manager = {}

        accumulated_deposit_hashes = {}
        accumulated_withdrawal_hashes = {}

        # * NOTES ====================================================================
        NOTE_SIZE = ids.Note.SIZE
        ADDRESS_OFFSET = ids.Note.address
        TOKEN_OFFSET = ids.Note.token
        AMOUNT_OFFSET = ids.Note.amount
        BLINDING_FACTOR_OFFSET = ids.Note.blinding_factor
        INDEX_OFFSET = ids.Note.index
        HASH_OFFSET = ids.Note.hash


        # * INVISIBLE ORDER ===========================================================
        INVISIBLE_ORDER_SIZE = ids.Invisibl3Order.SIZE
        ORDER_ID_OFFSET = ids.Invisibl3Order.order_id
        EXPIRATION_TIMESTAMP_OFFSET = ids.Invisibl3Order.expiration_timestamp
        TOKEN_SPENT_OFFSET = ids.Invisibl3Order.token_spent
        TOKEN_RECEIVED_OFFSET = ids.Invisibl3Order.token_received
        AMOUNT_SPENT_OFFSET = ids.Invisibl3Order.amount_spent
        AMOUNT_RECEIVED_OFFSET = ids.Invisibl3Order.amount_received
        FEE_LIMIT_OFFSET = ids.Invisibl3Order.fee_limit
        DEST_RECEIVED_ADDR_OFFSET = ids.Invisibl3Order.dest_received_address
        DEST_RECEIVED_BLINDING_OFFSET = ids.Invisibl3Order.dest_received_blinding

        # * PERPETUAL ORDER ==========================================================

        PERP_ORDER_SIZE = ids.PerpOrder.SIZE
        PERP_ORDER_ID_OFFSET = ids.PerpOrder.order_id
        PERP_EXPIRATION_TIMESTAMP_OFFSET = ids.PerpOrder.expiration_timestamp
        POSITION_EFFECT_TYPE_OFFSET = ids.PerpOrder.position_effect_type
        POS_ADDR_OFFSET = ids.PerpOrder.pos_addr_string
        ORDER_SIDE_OFFSET = ids.PerpOrder.order_side
        SYNTHETIC_TOKEN_OFFSET = ids.PerpOrder.synthetic_token
        SYNTHETIC_AMOUNT_OFFSET = ids.PerpOrder.synthetic_amount
        COLLATERAL_AMOUNT_OFFSET = ids.PerpOrder.collateral_amount
        PERP_FEE_LIMIT_OFFSET = ids.PerpOrder.fee_limit
        ORDER_HASH_OFFSET = ids.PerpOrder.hash

        OPEN_ORDER_FIELDS_SIZE = ids.OpenOrderFields.SIZE
        INITIAL_MARGIN_OFFSET = ids.OpenOrderFields.initial_margin
        OOF_COLLATERAL_TOKEN_OFFSET = ids.OpenOrderFields.collateral_token
        NOTES_IN_LEN_OFFSET = ids.OpenOrderFields.notes_in_len
        NOTES_IN_OFFSET = ids.OpenOrderFields.notes_in
        REFUND_NOTE_OFFSET = ids.OpenOrderFields.refund_note
        POSITION_ADDRESS_OFFSET = ids.OpenOrderFields.position_address
        ALLOW_PARTIAL_LIQUIDATIONS_OFFSET = ids.OpenOrderFields.allow_partial_liquidations

        CLOSE_ORDER_FIELDS_SIZE = ids.CloseOrderFields.SIZE
        RETURN_COLLATERAL_ADDRESS_OFFSET = ids.CloseOrderFields.return_collateral_address
        RETURN_COLLATERAL_BLINDING_OFFSET = ids.CloseOrderFields.return_collateral_blinding

        # * PERPETUAL POSITION =======================================================
        PERP_POSITION_SIZE = ids.PerpPosition.SIZE
        PERP_POSITION_ORDER_SIDE_OFFSET = ids.PerpPosition.order_side
        PERP_POSITION_SYNTHETIC_TOKEN_OFFSET = ids.PerpPosition.synthetic_token
        PERP_POSITION_COLLATERAL_TOKEN_OFFSET = ids.PerpPosition.collateral_token
        PERP_POSITION_POSITION_SIZE_OFFSET = ids.PerpPosition.position_size
        PERP_POSITION_MARGIN_OFFSET = ids.PerpPosition.margin
        PERP_POSITION_ENTRY_PRICE_OFFSET = ids.PerpPosition.entry_price
        PERP_POSITION_LIQUIDATION_PRICE_OFFSET = ids.PerpPosition.liquidation_price
        PERP_POSITION_BANKRUPTCY_PRICE_OFFSET = ids.PerpPosition.bankruptcy_price
        PERP_POSITION_ADDRESS_OFFSET = ids.PerpPosition.position_address
        PERP_POSITION_LAST_FUNDING_IDX_OFFSET = ids.PerpPosition.last_funding_idx
        PERP_POSITION_INDEX_OFFSET = ids.PerpPosition.index
        PERP_POSITION_HASH_OFFSET = ids.PerpPosition.hash
        PERP_POSITION_PARTIAL_LIQUIDATIONS_OFFSET = ids.PerpPosition.allow_partial_liquidations

        # * WITHDRAWAL ================================================================
        WITHDRAWAL_SIZE = ids.Withdrawal.SIZE
        WITHDRAWAL_CHAIN_OFFSET = ids.Withdrawal.withdrawal_chain
        WITHDRAWAL_TOKEN_OFFSET = ids.Withdrawal.token
        WITHDRAWAL_AMOUNT_OFFSET = ids.Withdrawal.amount
        WITHDRAWAL_ADDRESS_OFFSET = ids.Withdrawal.withdrawal_address

        # * DEPOSIT  ==================================================================
        DEPOSIT_SIZE = ids.Deposit.SIZE
        DEPOSIT_ID_OFFSET = ids.Deposit.deposit_id
        DEPOSIT_TOKEN_OFFSET = ids.Deposit.token
        DEPOSIT_AMOUNT_OFFSET = ids.Deposit.amount
        DEPOSIT_ADDRESS_OFFSET = ids.Deposit.deposit_address


        # * GLOBAL STATE ==============================================================
        ASSETS_LEN_OFFSET = ids.GlobalConfig.assets_len
        ASSETS_OFFSET = ids.GlobalConfig.assets
        COLLATERAL_TOKEN_OFFSET = ids.GlobalConfig.collateral_token
        DECIMALS_PER_ASSET_OFFSET = ids.GlobalConfig.decimals_per_asset
        PRICE_DECIMALS_PER_ASSET_OFFSET = ids.GlobalConfig.price_decimals_per_asset
        LEVERAGE_DECIMALS_OFFSET = ids.GlobalConfig.leverage_decimals
        LEVERAGE_BOUNDS_PER_ASSET_OFFSET = ids.GlobalConfig.leverage_bounds_per_asset
        DUST_AMOUNT_PER_ASSET_OFFSET = ids.GlobalConfig.dust_amount_per_asset
        OBSERVERS_LEN_OFFSET = ids.GlobalConfig.observers_len
        OBSERVERS_OFFSET = ids.GlobalConfig.observers
        MIN_PARTIAL_LIQUIDATION_SIZE_OFFSET = ids.GlobalConfig.min_partial_liquidation_size



        # // * FUNCTIONS * //

        def print_position(position_address):
            print("order_side: ", memory[position_address + 0])
            print("synthetic_token: ", memory[position_address + 1])
            print("collateral_token: ", memory[position_address + 2])
            print("position_size: ", memory[position_address + 3])
            print("margin: ", memory[position_address + 4])
            print("entry_price: ", memory[position_address + 5])
            print("liquidation_price: ", memory[position_address + 6])
            print("bankruptcy_price: ", memory[position_address + 7])
            print("position_address x: ", memory[position_address + 8])
            print("last_funding_idx: ", memory[position_address + 9])
            print("index: ", memory[position_address + 10])
            print("hash: ", memory[position_address + 11])
            print("allow_partial_liquidations: ", memory[position_address + 12])

        def print_note(note_address):
            print("address: ", memory[note_address + 0])
            print("token: ", memory[note_address + 2])
            print("amount: ", memory[note_address + 3])
            print("blinding_factor: ", memory[note_address + 4])
            print("index: ", memory[note_address + 5])
            print("hash: ", memory[note_address + 6])
    %}

    return ();
}
