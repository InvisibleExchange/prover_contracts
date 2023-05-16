use firestore_db_and_auth::ServiceSession;
use num_bigint::BigUint;
use num_traits::Zero;
use parking_lot::Mutex;
use serde_json::{json, Map, Value};
use std::{
    collections::HashMap,
    fs::File,
    path::Path,
    str::FromStr,
    sync::Arc,
    thread::{self, JoinHandle, ThreadId},
};

use error_stack::Result;

use crate::{
    perpetual::{
        liquidations::{
            liquidation_engine::LiquidationSwap, liquidation_output::LiquidationResponse,
        },
        perp_helpers::{
            perp_rollback::{rollback_perp_swap, PerpRollbackInfo},
            perp_swap_outptut::PerpSwapResponse,
        },
        perp_position::PerpPosition,
        perp_swap::PerpSwap,
        VALID_COLLATERAL_TOKENS,
    },
    transaction_batch::tx_batch_helpers::_calculate_funding_rates,
    transactions::transaction_helpers::db_updates::update_db_after_note_split,
    trees::TreeStateType,
    utils::firestore::{
        start_add_note_thread, start_add_position_thread, start_delete_note_thread,
    },
};
use crate::{server::grpc::RollbackMessage, utils::storage::MainStorage};
use crate::{
    trees::{superficial_tree::SuperficialTree, Tree},
    utils::storage::BackupStorage,
};

use crate::utils::{
    errors::{
        BatchFinalizationError, OracleUpdateError, PerpSwapExecutionError,
        TransactionExecutionError,
    },
    firestore::create_session,
    notes::Note,
};

use crate::transactions::{
    swap::SwapResponse,
    transaction_helpers::rollbacks::{
        rollback_deposit_updates, rollback_swap_updates, rollback_withdrawal_updates, RollbackInfo,
    },
};

use super::{
    super::server::{
        grpc::{ChangeMarginMessage, FundingUpdateMessage},
        server_helpers::engine_helpers::{
            verify_margin_change_signature, verify_position_existence,
        },
    },
    restore_state_helpers::{
        restore_deposit_update, restore_margin_update, restore_note_split,
        restore_perp_order_execution, restore_spot_order_execution, restore_withdrawal_update,
    },
    tx_batch_helpers::{_per_minute_funding_update_inner, get_funding_info},
    tx_batch_structs::{get_price_info, GlobalConfig},
};

use crate::transaction_batch::{
    tx_batch_helpers::{
        _init_empty_tokens_map, add_margin_state_updates, get_final_updated_counts,
        get_json_output, reduce_margin_state_updates,
    },
    tx_batch_structs::{FundingInfo, GlobalDexState, OracleUpdate, SwapFundingInfo},
};

// TODO: This could be weighted sum of different transactions (e.g. 5 for swaps, 1 for deposits, 1 for withdrawals)
const TRANSACTIONS_PER_BATCH: u16 = 50; // Number of transaction per batch (untill batch finalization)

// TODO: Make fields in all classes private where they should be
// Todo: Could store snapshots more often than just on tx_batch updates

// TODO: If you get a note doesent exist error, there should  be a fuction where you can check the existence of all your notes
// TODO: Maybe have a backup notes storage in the database and every time you log in you check if any of them are still in the state otherweise delete them

pub trait Transaction {
    fn transaction_type(&self) -> &str;

    fn execute_transaction(
        &mut self,
        tree: Arc<Mutex<SuperficialTree>>,
        partial_fill_tracker: Arc<Mutex<HashMap<u64, (Note, u64)>>>,
        updated_note_hashes: Arc<Mutex<HashMap<u64, BigUint>>>,
        swap_output_json: Arc<Mutex<Vec<serde_json::Map<String, Value>>>>,
        blocked_order_ids: Arc<Mutex<HashMap<u64, bool>>>,
        rollback_safeguard: Arc<Mutex<HashMap<ThreadId, RollbackInfo>>>,
        session: Arc<Mutex<ServiceSession>>,
        backup_storage: Arc<Mutex<BackupStorage>>,
    ) -> Result<(Option<SwapResponse>, Option<Vec<u64>>), TransactionExecutionError>;
}

pub struct TransactionBatch {
    pub state_tree: Arc<Mutex<SuperficialTree>>, // current state tree (superficial tree only stores the leaves)
    pub partial_fill_tracker: Arc<Mutex<HashMap<u64, (Note, u64)>>>, // maps orderIds to partial fill refund notes and filled mounts
    pub updated_note_hashes: Arc<Mutex<HashMap<u64, BigUint>>>, // info to get merkle proofs at the end of the batch
    pub swap_output_json: Arc<Mutex<Vec<serde_json::Map<String, Value>>>>, // json output map for cairo input
    pub blocked_order_ids: Arc<Mutex<HashMap<u64, bool>>>, // maps orderIds to whether they are blocked while another thread is processing the same order (in case of partial fills)
    //
    pub perpetual_state_tree: Arc<Mutex<SuperficialTree>>, // current perpetual state tree (superficial tree only stores the leaves)
    pub perpetual_partial_fill_tracker: Arc<Mutex<HashMap<u64, (Option<Note>, u64, u64)>>>, // (pfr_note, amount_filled, spent_margin)
    pub partialy_opened_positions: Arc<Mutex<HashMap<String, (PerpPosition, u64)>>>, // positions that were partially opened in an order that was partially filled
    pub perpetual_updated_position_hashes: Arc<Mutex<HashMap<u64, BigUint>>>, // info to get merkle proofs at the end of the batch
    pub blocked_perp_order_ids: Arc<Mutex<HashMap<u64, bool>>>, // maps orderIds to whether they are blocked while another thread is processing the same order (in case of partial fills)
    pub insurance_fund: Arc<Mutex<i64>>, // insurance fund used to pay for liquidations
    //
    pub latest_index_price: HashMap<u64, u64>,
    pub min_index_price_data: HashMap<u64, (u64, OracleUpdate)>, // maps asset id to the min price, OracleUpdate info of this batch
    pub max_index_price_data: HashMap<u64, (u64, OracleUpdate)>, // maps asset id to the max price, OracleUpdate info of this batch
    //
    pub running_funding_tick_sums: HashMap<u64, i64>, // maps asset id to the sum of all funding ticks in this batch (used for TWAP)
    pub current_funding_count: u16, // maps asset id to the number of funding ticks applied already (used for TWAP, goes upto 480)

    pub funding_rates: HashMap<u64, Vec<i64>>, // maps asset id to an array of funding rates (not reset at new batch)
    pub funding_prices: HashMap<u64, Vec<u64>>, // maps asset id to an array of funding prices (corresponding to the funding rates) (not reset at new batch)
    pub current_funding_idx: u32, // the current index of the funding rates and prices arrays
    pub min_funding_idxs: Arc<Mutex<HashMap<u64, u32>>>, // the min funding index of a position being updated in this batch for each asset
    //
    pub n_deposits: u32,    // number of depositis in this batch
    pub n_withdrawals: u32, // number of withdrawals in this batch
    //
    pub rollback_safeguard: Arc<Mutex<HashMap<ThreadId, RollbackInfo>>>, // used to rollback the state in case of errors
    pub perp_rollback_safeguard: Arc<Mutex<HashMap<ThreadId, PerpRollbackInfo>>>, // used to rollback the perp_state in case of errors
    //
    pub firebase_session: Arc<Mutex<ServiceSession>>, // Firebase session for updating the database in the cloud
    pub main_storage: Arc<Mutex<MainStorage>>,        // Storage Connection to store data on disk
    pub backup_storage: Arc<Mutex<BackupStorage>>,    // Storage for failed database updates
    //
    pub running_tx_count: u16, // number of transactions in the current micro batch
    pub running_index_price_count: u16, // number of index price updates in the current micro batch
}

// [720611572046124714047264528971193275274039884725841843024975277676352634647, 3277063050706459067292422006810458761666327299309045368540059255761977948163, 2562919246125525194133149830679868209708641275857578728717940908705613159542, 2562919246125525194133149830679868209708641275857578728717940908705613159542, 2562919246125525194133149830679868209708641275857578728717940908705613159542, 2562919246125525194133149830679868209708641275857578728717940908705613159542, 0, 633169145156021810680094650136107711968775354738881437650002548915256114472, 633169145156021810680094650136107711968775354738881437650002548915256114472, 999865114641534551578343797337705745943197965388439213388506436713692204488, 421021076951682542324234567693006887925800082706539824582191228239311517383, 1251335263961598763003641874578203876372024766000865142645021246588933133207, 522924134205947440388003243818952293276466114427386446260495599410908902725, 1698665403995648829511386567217524516121600165071000909611522341821583497658]

impl TransactionBatch {
    pub fn new(
        spot_tree_depth: u32,
        perp_tree_depth: u32,
        rollback_safeguard: Arc<Mutex<HashMap<ThreadId, RollbackInfo>>>,
        perp_rollback_safeguard: Arc<Mutex<HashMap<ThreadId, PerpRollbackInfo>>>,
    ) -> TransactionBatch {
        let state_tree = SuperficialTree::new(spot_tree_depth);
        let partial_fill_tracker: HashMap<u64, (Note, u64)> = HashMap::new();
        let updated_note_hashes: HashMap<u64, BigUint> = HashMap::new();
        let swap_output_json: Vec<serde_json::Map<String, Value>> = Vec::new();
        let blocked_order_ids: HashMap<u64, bool> = HashMap::new();

        let perpetual_state_tree = SuperficialTree::new(perp_tree_depth);
        let perpetual_partial_fill_tracker: HashMap<u64, (Option<Note>, u64, u64)> = HashMap::new();
        let partialy_opened_positions: HashMap<String, (PerpPosition, u64)> = HashMap::new();
        let perpetual_updated_position_hashes: HashMap<u64, BigUint> = HashMap::new();
        let blocked_perp_order_ids: HashMap<u64, bool> = HashMap::new();

        let mut latest_index_price: HashMap<u64, u64> = HashMap::new();
        let mut min_index_price_data: HashMap<u64, (u64, OracleUpdate)> = HashMap::new();
        let mut max_index_price_data: HashMap<u64, (u64, OracleUpdate)> = HashMap::new();

        let mut running_funding_tick_sums: HashMap<u64, i64> = HashMap::new();
        let mut funding_rates: HashMap<u64, Vec<i64>> = HashMap::new();
        let mut funding_prices: HashMap<u64, Vec<u64>> = HashMap::new();
        let mut min_funding_idxs: HashMap<u64, u32> = HashMap::new();

        let session = create_session();
        let session = Arc::new(Mutex::new(session));

        // Init empty maps
        _init_empty_tokens_map::<u64>(&mut latest_index_price);
        _init_empty_tokens_map::<(u64, OracleUpdate)>(&mut min_index_price_data);
        _init_empty_tokens_map::<(u64, OracleUpdate)>(&mut max_index_price_data);
        _init_empty_tokens_map::<i64>(&mut running_funding_tick_sums);
        _init_empty_tokens_map::<Vec<i64>>(&mut funding_rates);
        _init_empty_tokens_map::<Vec<u64>>(&mut funding_prices);
        _init_empty_tokens_map::<u32>(&mut min_funding_idxs);

        // TODO: For testing only =================================================
        latest_index_price.insert(54321, 1000 * 10u64.pow(6));
        latest_index_price.insert(12345, 10000 * 10u64.pow(6));
        // TODO: For testing only =================================================

        let tx_batch = TransactionBatch {
            state_tree: Arc::new(Mutex::new(state_tree)),
            partial_fill_tracker: Arc::new(Mutex::new(partial_fill_tracker)),
            updated_note_hashes: Arc::new(Mutex::new(updated_note_hashes)),
            swap_output_json: Arc::new(Mutex::new(swap_output_json)),
            blocked_order_ids: Arc::new(Mutex::new(blocked_order_ids)),
            //
            perpetual_state_tree: Arc::new(Mutex::new(perpetual_state_tree)),
            perpetual_partial_fill_tracker: Arc::new(Mutex::new(perpetual_partial_fill_tracker)),
            partialy_opened_positions: Arc::new(Mutex::new(partialy_opened_positions)),
            perpetual_updated_position_hashes: Arc::new(Mutex::new(
                perpetual_updated_position_hashes,
            )),
            blocked_perp_order_ids: Arc::new(Mutex::new(blocked_perp_order_ids)),
            insurance_fund: Arc::new(Mutex::new(0)),
            //
            latest_index_price,
            min_index_price_data,
            max_index_price_data,
            //
            running_funding_tick_sums,
            current_funding_count: 0,
            funding_rates,
            funding_prices,
            current_funding_idx: 0,
            min_funding_idxs: Arc::new(Mutex::new(min_funding_idxs)),
            //
            n_deposits: 0,
            n_withdrawals: 0,
            //
            rollback_safeguard,
            perp_rollback_safeguard,
            //
            firebase_session: session,
            main_storage: Arc::new(Mutex::new(MainStorage::new())),
            backup_storage: Arc::new(Mutex::new(BackupStorage::new())),
            //
            running_tx_count: 0,
            running_index_price_count: 0,
        };

        return tx_batch;
    }

    /// This initializes the transaction batch from a previous state
    pub fn init(&mut self) {
        let storage = self.main_storage.lock();
        if storage.is_empty {
            return;
        }

        if let Ok((funding_rates, funding_prices, funding_idx, min_funding_idxs)) =
            storage.read_funding_info()
        {
            self.funding_rates = funding_rates;
            self.funding_prices = funding_prices;
            self.current_funding_idx = funding_idx;
            self.min_funding_idxs = Arc::new(Mutex::new(min_funding_idxs));
        }

        if let Some((latest_index_price, min_index_price_data, max_index_price_data)) =
            storage.read_price_data()
        {
            self.latest_index_price = latest_index_price;
            self.min_index_price_data = min_index_price_data;
            self.max_index_price_data = max_index_price_data;
        }
        let swap_output_json = storage.read_storage();
        drop(storage);

        let path = Path::new("storage/merkle_trees/state_tree");
        let open_res = File::open(path);
        if let Err(_e) = open_res {
            self.restore_state(swap_output_json);
            // If the file doesn't exist, we dont run this function
            return;
        }
        let full_state_tree = Tree::from_disk(TreeStateType::Spot).unwrap();
        self.state_tree = Arc::new(Mutex::new(SuperficialTree::from_tree(full_state_tree)));

        let full_perpetual_state_tree = Tree::from_disk(TreeStateType::Perpetual).unwrap();
        self.perpetual_state_tree = Arc::new(Mutex::new(SuperficialTree::from_tree(
            full_perpetual_state_tree,
        )));

        self.restore_state(swap_output_json);
    }

    pub fn execute_transaction<T: Transaction + std::marker::Send + 'static>(
        &mut self,
        mut transaction: T,
    ) -> JoinHandle<Result<(Option<SwapResponse>, Option<Vec<u64>>), TransactionExecutionError>>
    {
        //

        let tx_type = String::from_str(transaction.transaction_type()).unwrap();

        let state_tree = self.state_tree.clone();
        let partial_fill_tracker = self.partial_fill_tracker.clone();
        let updated_note_hashes = self.updated_note_hashes.clone();
        let swap_output_json = self.swap_output_json.clone();
        let blocked_order_ids = self.blocked_order_ids.clone();
        let rollback_safeguard = self.rollback_safeguard.clone();
        let session = self.firebase_session.clone();
        let backup_storage = self.backup_storage.clone();

        let handle = thread::spawn(move || {
            let res = transaction.execute_transaction(
                state_tree,
                partial_fill_tracker,
                updated_note_hashes,
                swap_output_json,
                blocked_order_ids,
                rollback_safeguard,
                session,
                backup_storage,
            );
            return res;
        });

        match tx_type.as_str() {
            "deposit" => {
                self.n_deposits += 1;
            }
            "withdrawal" => {
                self.n_withdrawals += 1;
            }
            _ => {
                self.running_tx_count += 1;

                if self.running_tx_count >= TRANSACTIONS_PER_BATCH {
                    if let Err(e) = self.finalize_batch() {
                        println!("Error finalizing batch: {:?}", e);
                    } else {
                        // ? Transaction batch sucessfully finalized
                        self.running_tx_count = 0;
                    }
                }
            }
        }

        return handle;
    }

    pub fn execute_perpetual_transaction(
        &mut self,
        transaction: PerpSwap,
    ) -> JoinHandle<Result<PerpSwapResponse, PerpSwapExecutionError>> {
        let state_tree = self.state_tree.clone();
        let updated_note_hashes = self.updated_note_hashes.clone();
        let swap_output_json = self.swap_output_json.clone();

        let perpetual_state_tree = self.perpetual_state_tree.clone();
        let perpetual_partial_fill_tracker = self.perpetual_partial_fill_tracker.clone();
        let partialy_opened_positions = self.partialy_opened_positions.clone();
        let perpetual_updated_position_hashes = self.perpetual_updated_position_hashes.clone();
        let blocked_perp_order_ids = self.blocked_perp_order_ids.clone();

        let session = self.firebase_session.clone();
        let backup_storage = self.backup_storage.clone();

        let current_index_price = *self
            .latest_index_price
            .get(&transaction.order_a.synthetic_token)
            .unwrap();
        let min_funding_idxs = self.min_funding_idxs.clone();

        let perp_rollback_safeguard = self.perp_rollback_safeguard.clone();

        let swap_funding_info = SwapFundingInfo::new(
            &self.funding_rates,
            &self.funding_prices,
            self.current_funding_idx,
            transaction.order_a.synthetic_token,
            &transaction.order_a.position,
            &transaction.order_b.position,
        );

        let handle = thread::spawn(move || {
            return transaction.execute(
                state_tree,
                updated_note_hashes,
                swap_output_json,
                blocked_perp_order_ids,
                perpetual_state_tree,
                perpetual_partial_fill_tracker,
                partialy_opened_positions,
                perpetual_updated_position_hashes,
                current_index_price,
                min_funding_idxs,
                swap_funding_info,
                perp_rollback_safeguard,
                session,
                backup_storage,
            );
        });

        self.running_tx_count += 1;

        if self.running_tx_count >= TRANSACTIONS_PER_BATCH {
            if let Err(e) = self.finalize_batch() {
                println!("Error finalizing batch: {:?}", e);
            } else {
                // ? Transaction batch sucessfully finalized
                self.running_tx_count = 0;
            }
        }

        return handle;
    }

    pub fn execute_liquidation_transaction(
        &mut self,
        liquidation_transaction: LiquidationSwap,
    ) -> JoinHandle<Result<LiquidationResponse, PerpSwapExecutionError>> {
        let state_tree = self.state_tree.clone();
        let updated_note_hashes = self.updated_note_hashes.clone();
        let swap_output_json = self.swap_output_json.clone();

        let perpetual_state_tree = self.perpetual_state_tree.clone();
        let perpetual_updated_position_hashes = self.perpetual_updated_position_hashes.clone();

        let session = self.firebase_session.clone();
        let backup_storage = self.backup_storage.clone();

        let insurance_fund = self.insurance_fund.clone();

        let current_index_price = *self
            .latest_index_price
            .get(&liquidation_transaction.liquidation_order.synthetic_token)
            .unwrap();
        let min_funding_idxs = self.min_funding_idxs.clone();

        let swap_funding_info = SwapFundingInfo::new(
            &self.funding_rates,
            &self.funding_prices,
            self.current_funding_idx,
            liquidation_transaction.liquidation_order.synthetic_token,
            &Some(liquidation_transaction.liquidation_order.position.clone()),
            &None,
        );

        let handle = thread::spawn(move || {
            return liquidation_transaction.execute(
                state_tree,
                updated_note_hashes,
                swap_output_json,
                perpetual_state_tree,
                perpetual_updated_position_hashes,
                insurance_fund,
                current_index_price,
                min_funding_idxs,
                swap_funding_info,
                session,
                backup_storage,
            );
        });

        self.running_tx_count += 1;

        return handle;
    }

    // * Rollback the transaction execution state updates

    pub fn rollback_transaction(&mut self, rollback_info_message: (ThreadId, RollbackMessage)) {
        let thread_id = rollback_info_message.0;
        let rollback_message = rollback_info_message.1;

        if rollback_message.tx_type == "deposit" {
            // ? rollback the deposit execution state updates

            let rollback_info = self.rollback_safeguard.lock().remove(&thread_id).unwrap();

            rollback_deposit_updates(&self.state_tree, &self.updated_note_hashes, rollback_info);
        } else if rollback_message.tx_type == "swap" {
            // ? rollback the swap execution state updates

            let rollback_info = self.rollback_safeguard.lock().remove(&thread_id).unwrap();

            rollback_swap_updates(
                &self.state_tree,
                &self.updated_note_hashes,
                rollback_message,
                rollback_info,
            );
        } else if rollback_message.tx_type == "withdrawal" {
            // ? rollback the withdrawal execution state updates

            rollback_withdrawal_updates(
                &self.state_tree,
                &self.updated_note_hashes,
                rollback_message,
            );
        } else if rollback_message.tx_type == "perp_swap" {
            // ? rollback the perp swap execution state updates

            let rollback_info = self
                .perp_rollback_safeguard
                .lock()
                .remove(&thread_id)
                .unwrap();

            rollback_perp_swap(
                &self.state_tree,
                &self.updated_note_hashes,
                &self.perpetual_state_tree,
                &self.perpetual_updated_position_hashes,
                rollback_message,
                rollback_info,
            );
        }
    }

    // * =================================================================
    // TODO: These two functions should take a constant fee to ensure not being DOSed
    pub fn split_notes(
        &mut self,
        notes_in: Vec<Note>,
        notes_out: Vec<Note>,
    ) -> std::result::Result<Vec<u64>, String> {
        let token = notes_in[0].token;

        let mut sum_in: u64 = 0;

        let mut state_tree = self.state_tree.lock();
        for note in notes_in.iter() {
            if note.token != token {
                return Err("Invalid token".to_string());
            }

            let leaf_hash = state_tree.get_leaf_by_index(note.index);

            if leaf_hash != note.hash {
                return Err("Note does not exist".to_string());
            }

            sum_in += note.amount;
        }

        let note_out1 = &notes_out[0];
        let note_out2 = &notes_out[1];
        if note_out1.token != token || note_out2.token != token {
            return Err("Invalid token".to_string());
        }

        let note_in1 = &notes_in[0];
        let note_in2 = &notes_in[notes_in.len() - 1];
        if note_out1.blinding != note_in1.blinding
            || note_out1.address.x != note_in1.address.x
            || note_out2.blinding != note_in2.blinding
            || note_out2.address.x != note_in2.address.x
        {
            return Err("Missmatch od address and blinding between input/output notes".to_string());
        }

        if sum_in != note_out1.amount + note_out2.amount {
            return Err("New note amounts exceed old note amounts".to_string());
        }

        let mut zero_idxs: Vec<u64> = Vec::new(); // TODO: Should be renamed to new_idxs

        let mut updated_note_hashes = self.updated_note_hashes.lock();
        if notes_in.len() > notes_out.len() {
            for i in 0..notes_out.len() {
                state_tree.update_leaf_node(&notes_out[i].hash, notes_in[i].index);
                updated_note_hashes.insert(notes_in[i].index, notes_out[i].hash.clone());

                zero_idxs.push(notes_in[i].index)
            }

            for i in notes_out.len()..notes_in.len() {
                state_tree.update_leaf_node(&BigUint::zero(), notes_in[i].index);
                updated_note_hashes.insert(notes_in[i].index, BigUint::zero());
            }
        } else if notes_in.len() == notes_out.len() {
            for i in 0..notes_out.len() {
                state_tree.update_leaf_node(&notes_out[i].hash, notes_in[i].index);
                updated_note_hashes.insert(notes_in[i].index, notes_out[i].hash.clone());

                zero_idxs.push(notes_in[i].index);
            }
        } else {
            for i in 0..notes_in.len() {
                state_tree.update_leaf_node(&notes_out[i].hash, notes_in[i].index);
                updated_note_hashes.insert(notes_in[i].index, notes_out[i].hash.clone());

                zero_idxs.push(notes_in[i].index);
            }

            for i in notes_in.len()..notes_out.len() {
                let zero_idx = state_tree.first_zero_idx();

                state_tree.update_leaf_node(&notes_out[i].hash, zero_idx);
                updated_note_hashes.insert(zero_idx, notes_out[i].hash.clone());

                zero_idxs.push(zero_idx);
            }
        }
        drop(updated_note_hashes);
        drop(state_tree);

        // ----------------------------------------------

        update_db_after_note_split(
            &self.firebase_session,
            &self.backup_storage,
            notes_in.clone(),
            notes_out.clone(),
            &zero_idxs,
        );

        // ----------------------------------------------

        let mut json_map = serde_json::map::Map::new();
        json_map.insert(
            String::from("transaction_type"),
            serde_json::to_value("note_split").unwrap(),
        );
        json_map.insert(
            String::from("note_split"),
            json!({"token": token, "notes_in": notes_in, "notes_out": notes_out, "zero_idxs": zero_idxs}),
        );

        let mut swap_output_json = self.swap_output_json.lock();
        swap_output_json.push(json_map);
        drop(swap_output_json);

        Ok(zero_idxs)
    }

    pub fn change_position_margin(
        &self,
        margin_change: ChangeMarginMessage,
    ) -> std::result::Result<Vec<u64>, String> {
        verify_margin_change_signature(&margin_change)?;

        let mut position = margin_change.position.clone();
        verify_position_existence(&position, &self.perpetual_state_tree)?;

        position.modify_margin(margin_change.margin_change)?;

        let z_indexes: Vec<u64>;
        let mut valid: bool = true;
        if margin_change.margin_change >= 0 {
            let amount_in = margin_change
                .notes_in
                .as_ref()
                .unwrap()
                .iter()
                .fold(0, |acc, n| {
                    if n.token != VALID_COLLATERAL_TOKENS[0] {
                        valid = true;
                    }
                    return acc + n.amount;
                });
            let refund_amount = if margin_change.refund_note.is_some() {
                margin_change.refund_note.as_ref().unwrap().amount
            } else {
                0
            };

            if !valid {
                return Err("Invalid token".to_string());
            }
            if amount_in < margin_change.margin_change.abs() as u64 + refund_amount {
                return Err("Invalid amount in".to_string());
            }

            add_margin_state_updates(
                &self.state_tree,
                &self.perpetual_state_tree,
                &self.updated_note_hashes,
                &self.perpetual_updated_position_hashes,
                margin_change.notes_in.as_ref().unwrap(),
                margin_change.refund_note.clone(),
                position.index as u64,
                &position.hash.clone(),
            )?;

            let _handle = start_add_position_thread(
                position.clone(),
                &self.firebase_session,
                self.backup_storage.clone(),
            );

            for note in margin_change.notes_in.as_ref().unwrap().iter().skip(1) {
                let _handle = start_delete_note_thread(
                    &self.firebase_session,
                    note.address.x.to_string(),
                    note.index.to_string(),
                );
            }

            if margin_change.refund_note.is_some() {
                let _handle = start_add_note_thread(
                    margin_change.refund_note.as_ref().unwrap().clone(),
                    &self.firebase_session,
                    self.backup_storage.clone(),
                );

                // ? If the index and address of the first note in the notes_in array is the same as the refund note then we don't need to delete the note becasue it will be overwritten anyway
                let n0 = &margin_change.notes_in.as_ref().unwrap()[0];
                if n0.address.x != margin_change.refund_note.as_ref().unwrap().address.x
                    && n0.index != margin_change.refund_note.as_ref().unwrap().index
                {
                    let _handle = start_delete_note_thread(
                        &self.firebase_session,
                        n0.address.x.to_string(),
                        n0.index.to_string(),
                    );
                }
            }

            z_indexes = vec![];
        } else {
            let mut tree = self.state_tree.lock();

            let index = tree.first_zero_idx();
            drop(tree);

            let return_collateral_note = Note::new(
                index,
                margin_change
                    .close_order_fields
                    .as_ref()
                    .unwrap()
                    .dest_received_address
                    .clone(),
                position.collateral_token,
                margin_change.margin_change.abs() as u64,
                margin_change
                    .close_order_fields
                    .as_ref()
                    .unwrap()
                    .dest_received_blinding
                    .clone(),
            );

            reduce_margin_state_updates(
                &self.state_tree,
                &self.perpetual_state_tree,
                &self.updated_note_hashes,
                &self.perpetual_updated_position_hashes,
                return_collateral_note.clone(),
                position.index as u64,
                &position.hash.clone(),
            );

            let _handle = start_add_position_thread(
                position.clone(),
                &self.firebase_session,
                self.backup_storage.clone(),
            );

            let _handle = start_add_note_thread(
                return_collateral_note,
                &self.firebase_session,
                self.backup_storage.clone(),
            );

            z_indexes = vec![index];
        }

        // ----------------------------------------------

        let mut json_map = serde_json::map::Map::new();
        json_map.insert(
            String::from("transaction_type"),
            serde_json::to_value("margin_change").unwrap(),
        );
        json_map.insert(
            String::from("margin_change"),
            serde_json::to_value(margin_change).unwrap(),
        );
        json_map.insert(
            String::from("new_position_hash"),
            serde_json::to_value(position.hash.to_string()).unwrap(),
        );
        json_map.insert(
            String::from("zero_idx"),
            serde_json::to_value(if z_indexes.len() == 0 {
                0
            } else {
                z_indexes[0]
            })
            .unwrap(),
        );

        let mut swap_output_json = self.swap_output_json.lock();
        swap_output_json.push(json_map);
        drop(swap_output_json);

        Ok(z_indexes)
    }

    // * =================================================================
    // * FINALIZE BATCH

    pub fn finalize_batch(&mut self) -> Result<(), BatchFinalizationError> {
        // & Get the merkle trees from the beginning of the batch from disk

        let state_tree = self.state_tree.lock();
        let updated_note_hashes = self.updated_note_hashes.lock();
        let perpetual_state_tree = self.perpetual_state_tree.lock();
        let perpetual_updated_position_hashes = self.perpetual_updated_position_hashes.lock();
        let main_storage = self.main_storage.lock();

        // Wait for all operations to finish
        std::thread::sleep(std::time::Duration::from_millis(200));

        let mut batch_init_tree = Tree::from_disk(crate::trees::TreeStateType::Spot)
            .map_err(|_| BatchFinalizationError {})?;
        let mut perpetual_init_tree = Tree::from_disk(crate::trees::TreeStateType::Perpetual)
            .map_err(|_| BatchFinalizationError {})?;

        // ? Save the initial tree roots for later
        let batch_init_root = batch_init_tree.root.clone();
        let perp_init_root = perpetual_init_tree.root.clone();

        // & Get the merkle multi updates for this batch
        let mut preimage_json: Map<String, Value> = Map::new();
        batch_init_tree.batch_transition_updates(&updated_note_hashes, &mut preimage_json);

        let mut perpetual_preimage_json: Map<String, Value> = Map::new();
        perpetual_init_tree.batch_transition_updates(
            &perpetual_updated_position_hashes,
            &mut perpetual_preimage_json,
        );

        let counts =
            get_final_updated_counts(&updated_note_hashes, &perpetual_updated_position_hashes);
        let num_output_notes: u32 = counts[0];
        let num_zero_notes: u32 = counts[1];
        let num_output_positions: u32 = counts[2];
        let num_empty_positions: u32 = counts[3];

        let global_dex_state: GlobalDexState = GlobalDexState::new(
            1234, // todo
            &batch_init_root,
            &batch_init_tree.root,
            &perp_init_root,
            &perpetual_init_tree.root,
            batch_init_tree.depth,
            perpetual_init_tree.depth,
            1_000_000, // todo
            num_output_notes,
            num_zero_notes,
            num_output_positions,
            num_empty_positions,
            self.n_deposits,
            self.n_withdrawals,
        );

        let global_config: GlobalConfig = GlobalConfig::new();

        let funding_info: FundingInfo = get_funding_info(
            &self.min_funding_idxs,
            &self.funding_rates,
            &self.funding_prices,
        );

        let price_info_json =
            get_price_info(&self.min_index_price_data, &self.max_index_price_data);

        let mut swap_output_json = main_storage.read_storage();

        let mut latest_output_json = self.swap_output_json.lock();
        swap_output_json.append(&mut latest_output_json);
        drop(latest_output_json);

        let output_json = get_json_output(
            &global_dex_state,
            &global_config,
            &funding_info,
            price_info_json,
            &swap_output_json,
            preimage_json,
            perpetual_preimage_json,
        );

        // & Write to file
        // cairo_contracts/transaction_batch/tx_batch_input.json
        let path = Path::new("../cairo_contracts/transaction_batch/tx_batch_input.json");
        std::fs::write(path, serde_json::to_string(&output_json).unwrap()).unwrap();

        // & Store the merkle trees to disk
        batch_init_tree
            .store_to_disk(crate::trees::TreeStateType::Spot)
            .map_err(|_| BatchFinalizationError {})?;
        perpetual_init_tree
            .store_to_disk(crate::trees::TreeStateType::Perpetual)
            .map_err(|_| BatchFinalizationError {})?;

        // & Store the snapshot info to disk
        // store_snapshot_data(
        //     &self.partial_fill_tracker.lock(),
        //     &self.perpetual_partial_fill_tracker.lock(),
        //     &self.partialy_opened_positions.lock(),
        //     &self.funding_rates,
        //     &self.funding_prices,
        //     self.current_funding_idx,
        // )
        // .map_err(|_| BatchFinalizationError {})?;

        main_storage.clear_transaction_data().unwrap();

        println!("Transaction batch finalized sucessfully!");

        drop(batch_init_tree);
        drop(state_tree);
        drop(updated_note_hashes);
        drop(swap_output_json);
        //
        drop(perpetual_init_tree);
        drop(perpetual_state_tree);
        drop(perpetual_updated_position_hashes);
        drop(main_storage);

        // & Reset the batch
        self.reset_batch();

        Ok(())
    }

    // * =================================================================
    // * RESTORE STATE

    pub fn restore_state(&mut self, transactions: Vec<Map<String, Value>>) {
        for transaction in transactions {
            let transaction_type = transaction
                .get("transaction_type")
                .unwrap()
                .as_str()
                .unwrap();
            match transaction_type {
                "deposit" => {
                    let deposit_notes = transaction
                        .get("deposit")
                        .unwrap()
                        .get("notes")
                        .unwrap()
                        .as_array()
                        .unwrap();

                    restore_deposit_update(
                        &self.state_tree,
                        &self.updated_note_hashes,
                        deposit_notes,
                    );

                    self.n_deposits += 1;
                }
                "withdrawal" => {
                    let withdrawal_notes_in = transaction
                        .get("withdrawal")
                        .unwrap()
                        .get("notes_in")
                        .unwrap()
                        .as_array()
                        .unwrap();
                    let refund_note = transaction.get("withdrawal").unwrap().get("refund_note");

                    restore_withdrawal_update(
                        &self.state_tree,
                        &self.updated_note_hashes,
                        withdrawal_notes_in,
                        refund_note,
                    );

                    self.n_withdrawals += 1;
                }
                "swap" => {
                    // * Order a ------------------------

                    restore_spot_order_execution(
                        &self.state_tree,
                        &self.updated_note_hashes,
                        &transaction,
                        true,
                    );

                    // * Order b ------------------------

                    restore_spot_order_execution(
                        &self.state_tree,
                        &self.updated_note_hashes,
                        &transaction,
                        false,
                    );

                    self.running_tx_count += 1;
                }
                "perpetual_swap" => {
                    // * Order a ------------------------
                    restore_perp_order_execution(
                        &self.state_tree,
                        &self.updated_note_hashes,
                        &self.perpetual_state_tree,
                        &self.perpetual_updated_position_hashes,
                        &self.perpetual_partial_fill_tracker,
                        &transaction,
                        true,
                    );

                    // * Order b ------------------------
                    restore_perp_order_execution(
                        &self.state_tree,
                        &self.updated_note_hashes,
                        &self.perpetual_state_tree,
                        &self.perpetual_updated_position_hashes,
                        &self.perpetual_partial_fill_tracker,
                        &transaction,
                        false,
                    );

                    self.running_tx_count += 1;
                }

                "margin_change" => restore_margin_update(
                    &self.state_tree,
                    &self.updated_note_hashes,
                    &self.perpetual_state_tree,
                    &self.perpetual_updated_position_hashes,
                    &transaction,
                ),
                "note_split" => {
                    restore_note_split(&self.state_tree, &self.updated_note_hashes, &transaction)
                }

                _ => {
                    panic!("Invalid transaction type");
                }
            }
        }
    }

    // * FUNDING CALCULATIONS * //

    pub fn per_minute_funding_updates(&mut self, funding_update: FundingUpdateMessage) {
        let mut running_sums: Vec<(u64, i64)> = Vec::new();
        for tup in self.running_funding_tick_sums.drain() {
            running_sums.push(tup);
        }

        for (token, sum) in running_sums {
            let index_price = self.latest_index_price.get(&token).unwrap().clone();
            let (impact_bid, impact_ask) = funding_update.impact_prices.get(&token).unwrap();
            let new_sum =
                _per_minute_funding_update_inner(*impact_bid, *impact_ask, sum, index_price);

            self.running_funding_tick_sums.insert(token, new_sum);
        }

        self.current_funding_count += 1;

        if self.current_funding_count == 480 {
            let fundings = _calculate_funding_rates(&mut self.running_funding_tick_sums);

            for (token, funding) in fundings.iter() {
                self.funding_rates.get_mut(token).unwrap().push(*funding);
                let price = self.latest_index_price.get(token).unwrap().clone();
                self.funding_prices.get_mut(token).unwrap().push(price);
            }

            self.current_funding_idx += 1;

            // Reinitialize the funding tick sums
            self.current_funding_count = 0;
            _init_empty_tokens_map::<i64>(&mut self.running_funding_tick_sums);

            let storage = self.main_storage.lock();
            storage.store_funding_info(
                &self.funding_rates,
                &self.funding_prices,
                &self.current_funding_idx,
                &self.min_funding_idxs.lock(),
            );
            drop(storage);
        }
    }

    // * PRICE FUNCTIONS * //

    pub fn update_index_prices(
        &mut self,
        oracle_updates: Vec<OracleUpdate>,
    ) -> Result<HashMap<u64, u64>, OracleUpdateError> {
        // Oracle prices received from the oracle provider (e.g. Chainlink, Pontis, Stork)

        // Todo: check signatures only if the price is more/less then the max/min price this batch
        // Todo || *(could check all signatures if we dedicate a cpu just to that, probably not neccessary)*
        // Todo: Should also check signatures (at least a few) if the price deviates from the previous price by more than some threshold
        // Todo: Maybe check signatures every few seconds (e.g. 5 seconds)

        for mut update in oracle_updates {
            let token = update.token;
            let mut median = update.median_price();

            if self.min_index_price_data.get(&update.token).unwrap().0 == 0 {
                update.verify_update()?;
                median = update.median_price();

                self.latest_index_price.insert(token, median);

                self.min_index_price_data
                    .insert(update.token, (median, update.clone()));

                if self.max_index_price_data.get(&token).unwrap().0 == 0 {
                    self.max_index_price_data.insert(token, (median, update));
                }
            } else if median < self.min_index_price_data.get(&update.token).unwrap().0 {
                // ? This disregards the invalid observations and just uses the valid ones to get the median
                update.verify_update()?;
                median = update.median_price();

                if median >= self.min_index_price_data.get(&update.token).unwrap().0 {
                    self.latest_index_price.insert(token, median);
                    continue;
                }

                self.min_index_price_data
                    .insert(update.token, (median, update));

                //
            } else if median > self.max_index_price_data.get(&update.token).unwrap().0 {
                update.verify_update()?;
                median = update.median_price();

                if median <= self.max_index_price_data.get(&update.token).unwrap().0 {
                    self.latest_index_price.insert(token, median);
                    continue;
                }

                self.max_index_price_data
                    .insert(update.token, (median, update));
            }

            self.latest_index_price.insert(token, median);
        }

        self.running_index_price_count += 1;

        if self.running_index_price_count == 10 {
            let main_storage = self.main_storage.lock();
            main_storage.store_price_data(
                &self.latest_index_price,
                &self.min_index_price_data,
                &self.max_index_price_data,
            );
            drop(main_storage);
        }

        Ok(self.latest_index_price.clone())
    }

    pub fn get_index_price(&self, token: u64) -> u64 {
        // returns latest oracle price

        return self.latest_index_price.get(&token).unwrap().clone();
    }

    fn _mark_price() {
        // Average price of different exchanges
    }

    // * RESET * //

    fn reset_batch(&mut self) {
        let mut updated_note_hashes = self.updated_note_hashes.lock();
        // let mut swap_output_json = self.swap_output_json.lock();

        updated_note_hashes.clear();
        // swap_output_json.clear();

        // ====================================

        let mut perpetual_updated_note_hashes = self.perpetual_updated_position_hashes.lock();
        perpetual_updated_note_hashes.clear();

        _init_empty_tokens_map::<(u64, OracleUpdate)>(&mut self.min_index_price_data);
        _init_empty_tokens_map::<(u64, OracleUpdate)>(&mut self.max_index_price_data);
        // ? Funding is seperate from batch execution so it is not reset
        // ? min_funding_idxs is the exception since it's reletive to the batch
        let mut min_funding_idxs = self.min_funding_idxs.lock();
        min_funding_idxs.clear();
        _init_empty_tokens_map::<u32>(&mut min_funding_idxs);

        self.running_tx_count = 0;

        self.n_deposits = 0;
        self.n_withdrawals = 0;
    }
}

//

//

//

//
