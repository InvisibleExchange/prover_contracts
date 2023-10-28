from helpers.utils import Note
from invisible_swaps.order.invisible_order import Invisibl3Order
from perpetuals.order.order_structs import (
    PerpOrder,
    OpenOrderFields,
    CloseOrderFields,
    PerpPosition,
    PositionHeader,
)
from deposits_withdrawals.deposits.deposit_utils import Deposit
from deposits_withdrawals.withdrawals.withdraw_utils import Withdrawal

from rollup.global_config import GlobalConfig

from order_tabs.order_tab import OrderTab, TabHeader

func python_define_utils() {
    %{
        leaf_node_types = {}

        note_outputs_len = 0
        note_output_idxs = {}

        output_positions = {}
        output_tabs = {}

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

        POS_HEADER_SYNTHETIC_TOKEN_OFFSET = ids.PositionHeader.synthetic_token
        POS_HEADER_POSITION_ADDRESS_OFFSET = ids.PositionHeader.position_address
        POS_HEADER_ALLOW_PARTIAL_LIQUIDATIONS_OFFSET = ids.PositionHeader.allow_partial_liquidations
        POS_HEADER_VLP_TOKEN_OFFSET = ids.PositionHeader.vlp_token
        POS_HEADER_MAX_VLP_SUPPLY_OFFSET = ids.PositionHeader.max_vlp_supply
        POS_HEADER_HASH_OFFSET = ids.PositionHeader.hash


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
        SYNTHETIC_ASSETS_LEN_OFFSET = ids.GlobalConfig.synthetic_assets_len
        SYNTHETIC_ASSETS_OFFSET = ids.GlobalConfig.synthetic_assets
        CHAIN_IDS_LEN_OFFSET = ids.GlobalConfig.chain_ids_len
        CHAIN_IDS_OFFSET = ids.GlobalConfig.chain_ids
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
        def store_output_position(position_address, index):
            header_address = position_address + ids.PerpPosition.position_header
            output_positions[index] = {
                "order_side": memory[position_address + ids.PerpPosition.order_side],
                "position_size": memory[position_address + ids.PerpPosition.position_size],
                "margin": memory[position_address + ids.PerpPosition.margin],
                "entry_price": memory[position_address + ids.PerpPosition.entry_price],
                "liquidation_price": memory[position_address + ids.PerpPosition.liquidation_price],
                "bankruptcy_price": memory[position_address + ids.PerpPosition.bankruptcy_price],
                "last_funding_idx": memory[position_address + ids.PerpPosition.last_funding_idx],
                "vlp_supply": memory[position_address + ids.PerpPosition.vlp_supply],
                "index": memory[position_address + ids.PerpPosition.index],
                "hash": memory[position_address + ids.PerpPosition.hash],
                "synthetic_token": memory[header_address + POS_HEADER_SYNTHETIC_TOKEN_OFFSET],
                "position_address": memory[header_address + POS_HEADER_POSITION_ADDRESS_OFFSET],
                "allow_partial_liquidations": memory[header_address + POS_HEADER_ALLOW_PARTIAL_LIQUIDATIONS_OFFSET],
                "vlp_token": memory[header_address + POS_HEADER_VLP_TOKEN_OFFSET],
                "max_vlp_supply": memory[header_address + POS_HEADER_MAX_VLP_SUPPLY_OFFSET],
                "header_hash": memory[header_address + POS_HEADER_HASH_OFFSET],
            }


        def read_output_position(position_address, index):
            position_ = output_positions[index]
            
            memory[position_address + ids.PerpPosition.order_side] = int(position_["order_side"])
            memory[position_address + ids.PerpPosition.position_size] = int(position_["position_size"])
            memory[position_address + ids.PerpPosition.margin] = int(position_["margin"])
            memory[position_address + ids.PerpPosition.entry_price] = int(position_["entry_price"])
            memory[position_address + ids.PerpPosition.liquidation_price] = int(position_["liquidation_price"])
            memory[position_address + ids.PerpPosition.bankruptcy_price] = int(position_["bankruptcy_price"])
            memory[position_address + ids.PerpPosition.last_funding_idx] = int(position_["last_funding_idx"])
            memory[position_address + ids.PerpPosition.vlp_supply] = int(position_["vlp_supply"])
            memory[position_address + ids.PerpPosition.index] = int(position_["index"])
            memory[position_address + ids.PerpPosition.hash] = int(position_["hash"])
            #
            header_address = position_address + ids.PerpPosition.position_header

            memory[header_address + POS_HEADER_SYNTHETIC_TOKEN_OFFSET] = int(position_["synthetic_token"])
            memory[header_address + POS_HEADER_POSITION_ADDRESS_OFFSET] = int(position_["position_address"])
            memory[header_address + POS_HEADER_ALLOW_PARTIAL_LIQUIDATIONS_OFFSET] = int(position_["allow_partial_liquidations"])
            memory[header_address + POS_HEADER_VLP_TOKEN_OFFSET] = int(position_["vlp_token"])
            memory[header_address + POS_HEADER_MAX_VLP_SUPPLY_OFFSET] = int(position_["max_vlp_supply"])
            memory[header_address + POS_HEADER_HASH_OFFSET] = int(position_["header_hash"])



        def store_output_order_tab(header_address, index, base_amount, quote_amount, vlp_supply, new_updated_hash):
            output_tabs[index] = {
                "index": index,
                "is_smart_contract": memory[header_address + ids.TabHeader.is_smart_contract],
                "base_token": memory[header_address + ids.TabHeader.base_token],
                "quote_token": memory[header_address + ids.TabHeader.quote_token],
                "base_blinding": memory[header_address + ids.TabHeader.base_blinding],
                "quote_blinding": memory[header_address + ids.TabHeader.quote_blinding],
                "pub_key": memory[header_address + ids.TabHeader.pub_key],
                "header_hash": memory[header_address + ids.TabHeader.hash],
                "vlp_token": memory[header_address + ids.TabHeader.vlp_token],
                "max_vlp_supply": memory[header_address + ids.TabHeader.max_vlp_supply],
                "base_amount": base_amount,
                "quote_amount": quote_amount,
                "vlp_supply": vlp_supply,
                "hash": new_updated_hash,
            }

        def read_output_order_tab(tab_address, index):
            order_tab = output_tabs[index]

            memory[tab_address + ids.OrderTab.tab_idx] = int(order_tab["index"])
            memory[tab_address + ids.OrderTab.base_amount] = int(order_tab["base_amount"])
            memory[tab_address + ids.OrderTab.quote_amount] = int(order_tab["quote_amount"])
            memory[tab_address + ids.OrderTab.vlp_supply] = int(order_tab["vlp_supply"])
            memory[tab_address + ids.OrderTab.hash] = int(order_tab["hash"])

            header_address = tab_address + ids.OrderTab.tab_header
            memory[header_address + ids.TabHeader.is_smart_contract] = int(order_tab["is_smart_contract"])
            memory[header_address + ids.TabHeader.base_token] = int(order_tab["base_token"])
            memory[header_address + ids.TabHeader.quote_token] = int(order_tab["quote_token"])
            memory[header_address + ids.TabHeader.base_blinding] = int(order_tab["base_blinding"])
            memory[header_address + ids.TabHeader.quote_blinding] = int(order_tab["quote_blinding"])
            memory[header_address + ids.TabHeader.vlp_token] = int(order_tab["vlp_token"])
            memory[header_address + ids.TabHeader.max_vlp_supply] = int(order_tab["max_vlp_supply"])
            memory[header_address + ids.TabHeader.pub_key] = int(order_tab["pub_key"])
            memory[header_address + ids.TabHeader.hash] = int(order_tab["header_hash"])


        def print_position(position_address):
            header_address = position_address + ids.PerpPosition.position_header
            pos = {
                "order_side": memory[position_address + ids.PerpPosition.order_side],
                "position_size": memory[position_address + ids.PerpPosition.position_size],
                "margin": memory[position_address + ids.PerpPosition.margin],
                "entry_price": memory[position_address + ids.PerpPosition.entry_price],
                "liquidation_price": memory[position_address + ids.PerpPosition.liquidation_price],
                "bankruptcy_price": memory[position_address + ids.PerpPosition.bankruptcy_price],
                "last_funding_idx": memory[position_address + ids.PerpPosition.last_funding_idx],
                "vlp_supply": memory[position_address + ids.PerpPosition.vlp_supply],
                "index": memory[position_address + ids.PerpPosition.index],
                "hash": memory[position_address + ids.PerpPosition.hash],
                "synthetic_token": memory[header_address + POS_HEADER_SYNTHETIC_TOKEN_OFFSET],
                "position_address": memory[header_address + POS_HEADER_POSITION_ADDRESS_OFFSET],
                "allow_partial_liquidations": memory[header_address + POS_HEADER_ALLOW_PARTIAL_LIQUIDATIONS_OFFSET],
                "vlp_token": memory[header_address + POS_HEADER_VLP_TOKEN_OFFSET],
                "max_vlp_supply": memory[header_address + POS_HEADER_MAX_VLP_SUPPLY_OFFSET],
                "header_hash": memory[header_address + POS_HEADER_HASH_OFFSET],
            }

            print(pos)

        def print_note(note_address):
            note = {
                "address": memory[note_address + ADDRESS_OFFSET],
                "token": memory[note_address + TOKEN_OFFSET],
                "amount": memory[note_address + AMOUNT_OFFSET],
                "blinding_factor": memory[note_address + BLINDING_FACTOR_OFFSET],
                "index": memory[note_address + INDEX_OFFSET],
                "hash": memory[note_address + HASH_OFFSET],
            }

            print(note)
    %}

    return ();
}
