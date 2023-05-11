use std::{collections::HashMap, net::SocketAddr, sync::Arc};

use futures::stream::SplitSink;
use futures::{SinkExt, StreamExt};
use phf::phf_map;
use tokio::net::TcpStream;
use tokio::sync::Mutex as TokioMutex;

use error_stack::{Report, Result};
use tokio_tungstenite::WebSocketStream;

use crate::perpetual::perp_order::PerpOrder;
use crate::perpetual::perp_swap::PerpSwap;
use crate::perpetual::{calculate_quote_amount, VALID_COLLATERAL_TOKENS};
use crate::utils::crypto_utils::Signature;
use crate::{
    matching_engine::{
        domain::{Order, OrderSide as OBOrderSide},
        orderbook::{Failed, OrderBook, Success},
    },
    transactions::{limit_order::LimitOrder, swap::Swap},
    utils::errors::{send_matching_error, MatchingEngineError},
};

use tokio_tungstenite::tungstenite::{Message, Result as WsResult};

const BTC: u64 = 12345;
const ETH: u64 = 54321;
const USDC: u64 = 55555;

pub static SPOT_MARKET_IDS: phf::Map<&'static str, u16> = phf_map! {
 "12345" => 11, // BTC
 "54321" => 12, // ETH
};

pub static PERP_MARKET_IDS: phf::Map<&'static str, u16> = phf_map! {
    "12345" => 21, // BTC
    "54321" => 22, // ETH
};

pub mod amend_order_execution;
pub mod engine_helpers;
pub mod periodic_updates;
pub mod perp_swap_execution;
pub mod swap_execution;

pub fn init_order_books() -> (
    HashMap<u16, Arc<TokioMutex<OrderBook>>>,
    HashMap<u16, Arc<TokioMutex<OrderBook>>>,
) {
    let mut spot_order_books: HashMap<u16, Arc<TokioMutex<OrderBook>>> = HashMap::new();
    let mut perp_order_books: HashMap<u16, Arc<TokioMutex<OrderBook>>> = HashMap::new();

    // & BTC-USDC orderbook
    let market_id = SPOT_MARKET_IDS.get(&BTC.to_string()).unwrap();
    let book = Arc::new(TokioMutex::new(OrderBook::new(BTC, USDC, *market_id)));
    spot_order_books.insert(*market_id, book);

    let market_id = PERP_MARKET_IDS.get(&BTC.to_string()).unwrap();
    let book = Arc::new(TokioMutex::new(OrderBook::new(BTC, USDC, *market_id)));
    perp_order_books.insert(*market_id, book);

    // & ETH-USDC orderbook
    let market_id = SPOT_MARKET_IDS.get(&ETH.to_string()).unwrap();
    let book = Arc::new(TokioMutex::new(OrderBook::new(ETH, USDC, *market_id)));
    spot_order_books.insert(*market_id, book);

    let market_id = PERP_MARKET_IDS.get(&ETH.to_string()).unwrap();
    let book = Arc::new(TokioMutex::new(OrderBook::new(ETH, USDC, *market_id)));
    perp_order_books.insert(*market_id, book);

    return (spot_order_books, perp_order_books);
}

pub fn get_market_id_and_order_side(
    token_spent: u64,
    token_received: u64,
) -> Option<(u16, OBOrderSide)> {
    let option1 = SPOT_MARKET_IDS.get(&token_spent.to_string());

    if let Some(m_id) = option1 {
        return Some((*m_id, OBOrderSide::Ask));
    }

    let option2 = SPOT_MARKET_IDS.get(&token_received.to_string());

    if let Some(m_id) = option2 {
        return Some((*m_id, OBOrderSide::Bid));
    }

    None
}

pub fn get_order_side(
    order_book: &OrderBook,
    token_spent: u64,
    token_received: u64,
) -> Option<OBOrderSide> {
    if order_book.order_asset == token_spent && order_book.price_asset == token_received {
        return Some(OBOrderSide::Ask);
    } else if order_book.order_asset == token_received && order_book.price_asset == token_spent {
        return Some(OBOrderSide::Bid);
    }

    None
}

// * ======================= ==================== ===================== =========================== ====================================

pub struct MatchingProcessedResult {
    pub swaps: Option<Vec<(Swap, u64, u64)>>, // An array of swaps that were processed by the order
    pub new_order_id: u64,                    // The order id of the order that was just processed
}

pub fn proccess_spot_matching_result(
    results_vec: &mut Vec<std::result::Result<Success, Failed>>,
) -> Result<MatchingProcessedResult, MatchingEngineError> {
    if results_vec.len() == 0 {
        return Err(send_matching_error(
            "Invalid or duplicate order".to_string(),
        ));
    } else if results_vec.len() == 1 {
        match &results_vec[0] {
            Ok(x) => match x {
                Success::Accepted {
                    id,
                    order_type: _,
                    ts: _,
                } => {
                    return Ok(MatchingProcessedResult {
                        swaps: None,
                        new_order_id: *id,
                    });
                }
                Success::Cancelled { id: _, ts: _ } => {
                    return Ok(MatchingProcessedResult {
                        swaps: None,
                        new_order_id: 0,
                    });
                }
                Success::Amended {
                    id: _,
                    new_price: _,
                    ts: _,
                } => {
                    return Ok(MatchingProcessedResult {
                        swaps: None,
                        new_order_id: 0,
                    });
                }
                _ => return Err(send_matching_error("Invalid matching response".to_string())),
            },
            Err(e) => Err(handle_error(e)),
        }
    } else if results_vec.len() % 2 == 0 {
        for res in results_vec {
            if let Err(e) = res {
                return Err(handle_error(e));
            }
        }

        return Err(send_matching_error(
            "Invalid matching response length".to_string(),
        ));
    } else {
        //

        let mut new_order_id: u64 = 0;
        if let Ok(x) = &results_vec[0] {
            if let Success::Accepted { id, .. } = x {
                new_order_id = *id;
            }
        } else if let Err(e) = &results_vec[0] {
            return Err(handle_error(e));
        }

        let mut a_orders: Vec<(LimitOrder, Signature, u64, u64, bool)> = Vec::new(); // Vec<(order, sig, spent_amount, user_id, take_fee?)>
        let mut b_orders: Vec<(LimitOrder, Signature, u64, u64, bool)> = Vec::new(); // Vec<(order, sig, spent_amount, user_id, take_fee?)>

        for (i, res) in results_vec.drain(1..).enumerate() {
            if let Ok(res) = res {
                match res {
                    // ? Because fills always happen in pairs you can always set the bid order to order_a and ask order to order_b
                    Success::Filled {
                        order,
                        signature,
                        side,
                        order_type: _,
                        price,
                        qty,
                        quote_qty,
                        partially_filled: _,
                        ts: _,
                        user_id,
                    } => {
                        if let Order::Spot(lim_order) = order {
                            if side == OBOrderSide::Ask {
                                // He is selling the base asset and buying the quote(price) asset
                                let spent_amount = qty;

                                // transactions are ordered as [(taker,maker), (taker,maker), ...]
                                let take_fee = i % 2 == 0;

                                let b_order_tup =
                                    (lim_order, signature, spent_amount, user_id, take_fee);
                                b_orders.push(b_order_tup);
                            } else {
                                // He is buying the base asset and selling the quote(price) asset
                                let spent_amount = if quote_qty > 0 {
                                    quote_qty
                                } else {
                                    calculate_quote_amount(
                                        lim_order.token_received,
                                        lim_order.token_spent,
                                        qty,
                                        price,
                                    )
                                };

                                // transactions are ordered as [(taker,maker), (taker,maker), ...]
                                let take_fee = i % 2 == 0;

                                let a_order_tup =
                                    (lim_order, signature, spent_amount, user_id, take_fee);
                                a_orders.push(a_order_tup);
                            }
                        } else {
                            return Err(send_matching_error(
                                "Invalid order type in Filled response".to_string(),
                            ));
                        }
                    }
                    _ => return Err(send_matching_error("SOMETHING WENT WRONG".to_string())),
                };
            } else if let Err(e) = res {
                return Err(handle_error(&e));
            }
        }

        let mut swaps: Vec<(Swap, u64, u64)> = Vec::new(); // Vec<(swap, user_id_a, user_id_b)>

        // ? Build swaps from a_orders and b_orders vecs
        for (a, b) in a_orders.into_iter().zip(b_orders.into_iter()) {
            let (order_a, signature_a, spent_amount_a, user_id_a, take_fee_a) = a;
            let (order_b, signature_b, spent_amount_b, user_id_b, take_fee_b) = b;

            let fee_taken_a = if take_fee_a {
                (spent_amount_b as f64 * 0.0005) as u64
            } else {
                0
            };
            let fee_taken_b = if take_fee_b {
                (spent_amount_a as f64 * 0.0005) as u64
            } else {
                0
            };

            let swap = Swap::new(
                order_a,
                order_b,
                signature_a,
                signature_b,
                spent_amount_a,
                spent_amount_b,
                fee_taken_a,
                fee_taken_b,
            );

            swaps.push((swap, user_id_a, user_id_b));
        }

        return Ok(MatchingProcessedResult {
            swaps: Some(swaps),
            new_order_id,
        });
    }
}

// ======================== ======================== =======================

pub struct PerpMatchingProcessedResult {
    pub perp_swaps: Option<Vec<(PerpSwap, u64, u64)>>, // An array of swaps that were processed by the order
    pub new_order_id: u64, // The order id of the order that was just processed
}

pub fn proccess_perp_matching_result(
    results_vec: &mut Vec<std::result::Result<Success, Failed>>,
) -> Result<PerpMatchingProcessedResult, MatchingEngineError> {
    if results_vec.len() == 0 {
        return Err(send_matching_error(
            "Invalid matching response length".to_string(),
        ));
    } else if results_vec.len() == 1 {
        match &results_vec[0] {
            Ok(x) => match x {
                Success::Accepted { id, .. } => {
                    return Ok(PerpMatchingProcessedResult {
                        perp_swaps: None,
                        new_order_id: *id,
                    });
                }
                Success::Cancelled { .. } => {
                    return Ok(PerpMatchingProcessedResult {
                        perp_swaps: None,
                        new_order_id: 0,
                    });
                }
                Success::Amended { .. } => {
                    return Ok(PerpMatchingProcessedResult {
                        perp_swaps: None,
                        new_order_id: 0,
                    });
                }
                _ => return Err(send_matching_error("Invalid matching response".to_string())),
            },
            Err(e) => Err(handle_error(e)),
        }
    } else if results_vec.len() % 2 == 0 {
        for res in results_vec {
            if let Err(e) = res {
                return Err(handle_error(e));
            }
        }

        return Err(send_matching_error(
            "Invalid matching response length".to_string(),
        ));
    } else {
        //

        let mut new_order_id: u64 = 0;
        if let Ok(x) = &results_vec[0] {
            if let Success::Accepted { id, .. } = x {
                new_order_id = *id;
            }
        } else if let Err(e) = &results_vec[0] {
            return Err(handle_error(e));
        }

        let mut a_orders: Vec<(PerpOrder, Signature, u64, u64, bool)> = Vec::new(); // Vec<(order, sig, spent_synthetic, user_id, take_fee?)>
        let mut b_orders: Vec<(PerpOrder, Signature, u64, u64, bool)> = Vec::new(); // Vec<(order, sig, spent_collateral, user_id, take_fee?)>

        for (i, res) in results_vec.drain(1..).enumerate() {
            if let Ok(res) = res {
                match res {
                    // ? Because fills always happen in pairs you can always set the bid order to order_a and ask order to order_b
                    Success::Filled {
                        order,
                        signature,
                        side,
                        order_type: _,
                        price,
                        qty,
                        quote_qty,
                        partially_filled: _,
                        ts: _,
                        user_id,
                    } => {
                        if let Order::Perp(perp_order) = order {
                            if side == OBOrderSide::Ask {
                                // The synthetic exchnaged in the swap
                                let spent_synthetic = qty;

                                // transactions are ordered as [(taker,maker), (taker,maker), ...]
                                let take_fee = i % 2 == 0;

                                let b_order_tup =
                                    (perp_order, signature, spent_synthetic, user_id, take_fee);
                                b_orders.push(b_order_tup);
                            } else {
                                // The collateral exchnaged in the swap
                                let collateral_spent = if quote_qty > 0 {
                                    quote_qty
                                } else {
                                    calculate_quote_amount(
                                        perp_order.synthetic_token,
                                        VALID_COLLATERAL_TOKENS[0],
                                        qty,
                                        price,
                                    )
                                };

                                // transactions are ordered as [(taker,maker), (taker,maker), ...]
                                let take_fee = i % 2 == 0;

                                let a_order_tup =
                                    (perp_order, signature, collateral_spent, user_id, take_fee);
                                a_orders.push(a_order_tup);
                            }
                        } else {
                            return Err(send_matching_error(
                                "Invalid order type in Filled response".to_string(),
                            ));
                        }
                    }
                    _ => return Err(send_matching_error("SOMETHING WENT WRONG".to_string())),
                };
            } else if let Err(e) = res {
                return Err(handle_error(&e));
            }
        }

        let mut swaps: Vec<(PerpSwap, u64, u64)> = Vec::new(); // Vec<(swap, user_id_a, user_id_b)>

        // ? Build swaps from a_orders and b_orders vecs
        for (a, b) in a_orders.into_iter().zip(b_orders.into_iter()) {
            let (order_a, signature_a, spent_collateral, user_id_a, take_fee_a) = a;
            let (order_b, signature_b, spent_synthetic, user_id_b, take_fee_b) = b;

            let fee_taken_a = if take_fee_a {
                (spent_collateral as f64 * 0.0005) as u64
            } else {
                0
            };
            let fee_taken_b = if take_fee_b {
                (spent_collateral as f64 * 0.0005) as u64
            } else {
                0
            };

            let swap = PerpSwap::new(
                order_a,
                order_b,
                Some(signature_a),
                Some(signature_b),
                spent_collateral,
                spent_synthetic,
                fee_taken_a,
                fee_taken_b,
            );

            swaps.push((swap, user_id_a, user_id_b));
        }

        return Ok(PerpMatchingProcessedResult {
            perp_swaps: Some(swaps),
            new_order_id,
        });
    }
}

fn handle_error(e: &Failed) -> Report<MatchingEngineError> {
    match e {
        Failed::ValidationFailed(e) => {
            return send_matching_error(format!("ValidationFailed: {:#?}", e))
        }
        Failed::DuplicateOrderID(e) => {
            return send_matching_error(format!("DuplicateOrderID: {:#?}", e))
        }
        Failed::NoMatch(e) => return send_matching_error(format!("NoMatch: {:#?}", e)),
        Failed::OrderNotFound(e) => return send_matching_error(format!("OrderNotFound: {:#?}", e)),
        Failed::TooMuchSlippage(e) => {
            return send_matching_error(format!("TooMuchSlippage: {:#?}", e))
        }
    }
}

// * ======================= ==================== ===================== =========================== ====================================

pub type WsConnectionsMap = HashMap<SocketAddr, SplitSink<WebSocketStream<TcpStream>, Message>>;
pub type WsIdsMap = HashMap<u64, SocketAddr>;

pub async fn handle_connection(
    raw_stream: TcpStream,
    addr: SocketAddr,
    ws_connections: Arc<TokioMutex<WsConnectionsMap>>,
    ws_ids: Arc<TokioMutex<WsIdsMap>>,
) -> WsResult<()> {
    let ws_stream = tokio_tungstenite::accept_async(raw_stream)
        .await
        .expect("Error during the websocket handshake occurred");

    let (ws_sender, mut ws_receiver) = ws_stream.split();

    let msg = ws_receiver.next().await;

    let mut user_id: Option<u64> = None;

    match msg {
        Some(msg) => {
            let msg: Message = msg?;
            if let Message::Text(m) = msg {
                // ? SUBSCRIBE TO THE LIQUIDITY UPDATES AS WELL AS TRADES
                if let Ok(user_id_) = m.parse::<u64>() {
                    user_id = Some(user_id_);

                    let mut ws_connections__ = ws_connections.lock().await;
                    ws_connections__.insert(addr, ws_sender);
                    drop(ws_connections__);

                    let mut ws_ids__ = ws_ids.lock().await;
                    ws_ids__.insert(user_id_, addr);
                    drop(ws_ids__);
                } else {
                    // println!("Received invalid user id: {}", m);
                }
            }
        }
        None => {
            // println!("Failed to establish connection");
        }
    }

    loop {
        let msg = ws_receiver.next().await;
        match msg {
            Some(_msg) => {
                // let msg: Message = msg?;
            }
            None => break,
        }
    }

    let mut ws_connections__ = ws_connections.lock().await;
    ws_connections__.remove(&addr);
    drop(ws_connections__);

    if let Some(user_id) = user_id {
        let mut ws_ids__ = ws_ids.lock().await;
        ws_ids__.remove(&user_id);
        drop(ws_ids__);
    }

    Ok(())
}

pub async fn brodcast_message(
    ws_connections: &Arc<TokioMutex<WsConnectionsMap>>,
    msg: Message,
) -> WsResult<()> {
    let mut ws_connections__ = ws_connections.lock().await;
    for (_, ws_sender) in ws_connections__.iter_mut() {
        ws_sender.send(msg.clone()).await?;
    }
    drop(ws_connections__);

    Ok(())
}

pub async fn send_direct_message(
    ws_connections: &Arc<TokioMutex<WsConnectionsMap>>,
    ws_ids: &Arc<TokioMutex<WsIdsMap>>,
    user_id: u64,
    msg: Message,
) -> WsResult<()> {
    let mut ws_connections__ = ws_connections.lock().await;
    let ws_ids__ = ws_ids.lock().await;

    let addr = ws_ids__.get(&user_id);

    if addr.is_none() {
        return Ok(());
    }

    let ws_sender = ws_connections__.get_mut(addr.unwrap()).unwrap();

    ws_sender.send(msg.clone()).await?;

    drop(ws_connections__);
    drop(ws_ids__);

    Ok(())
}

// * ======================= ==================== ===================== =========================== ====================================
