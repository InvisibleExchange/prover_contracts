// %builtins output pedersen range_check ecdsa

from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.dict import dict_new, dict_write, dict_update, dict_squash, dict_read
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.squash_dict import squash_dict
from starkware.cairo.common.ec_point import EcPoint
from starkware.cairo.common.math import unsigned_div_rem, assert_le, assert_not_equal
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.pow import pow

// from invisible_swaps.helpers.range_checks import range_checks_
from rollup.output_structs import NoteDiffOutput, PerpPositionOutput, ZeroOutput
from rollup.global_config import GlobalConfig
from helpers.utils import (
    Note,
    construct_new_note,
    sum_notes,
    take_fee,
    get_price,
    verify_note_hashes,
    verify_note_hash,
)

from helpers.signatures import verify_open_order_signature, verify_order_signature, verify_sig

from perpetuals.prices.prices import PriceRange
from perpetuals.funding.funding import FundingInfo

from perpetuals.order.perp_position import (
    construct_new_position,
    add_margin_to_position_internal,
    increase_position_size_internal,
    reduce_position_size_internal,
    flip_position_side_internal,
    close_position_partialy_internal,
    close_position_internal,
)
from perpetuals.order.order_structs import (
    PerpOrder,
    OpenOrderFields,
    CloseOrderFields,
    PerpPosition,
    PositionHeader,
)
from perpetuals.order.order_hash import (
    verify_order_hash,
    verify_open_order_hash,
    verify_position_hash,
    verify_close_order_hash,
)

from helpers.perp_helpers.checks import (
    open_order_specific_checks,
    validate_fee_taken,
    checks_prev_fill_consistencies,
)

from rollup.global_config import get_dust_amount

from helpers.perp_helpers.partial_fill_helpers_perp import refund_partial_fill, remove_prev_pfr_note
from helpers.perp_helpers.dict_updates import (
    update_state_dict,
    update_rc_state_dict,
    update_position_state,
    update_position_state_on_close,
)

func execute_perpetual_transaction{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    fee_tracker_dict: DictAccess*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    order: PerpOrder,
    other_order: PerpOrder,
    spent_collateral: felt,
    spent_synthetic: felt,
    fee_taken: felt,
) {
    alloc_locals;

    // * ORDER ============================================================

    if (order.position_effect_type == 0) {
        %{ assert current_order["position_effect_type"] == "Open" %}

        let (__fp__: felt, _) = get_fp_and_pc();
        local open_order_fields: OpenOrderFields;
        %{ open_order_field_inputs = current_order["open_order_fields"] %}
        get_open_order_fields(&open_order_fields);

        verify_open_order_hash(order, open_order_fields);

        verify_note_hashes(open_order_fields.notes_in_len, open_order_fields.notes_in);
        verify_note_hash(open_order_fields.refund_note);

        execute_open_order(
            order, other_order, open_order_fields, spent_collateral, spent_synthetic, fee_taken
        );

        return ();
    }
    if (order.position_effect_type == 1) {
        %{ assert current_order["position_effect_type"] == "Modify" %}

        let position: PerpPosition = get_perp_position();

        verify_position_hash(position);

        verify_order_hash(order);

        verify_order_signature(order.hash, position);

        execute_modify_order(order, position, spent_collateral, spent_synthetic, fee_taken);

        return ();
    }
    if (order.position_effect_type == 2) {
        %{ assert current_order["position_effect_type"] == "Close" %}

        let position: PerpPosition = get_perp_position();
        verify_position_hash(position);

        let (__fp__: felt, _) = get_fp_and_pc();
        local close_order_fields: CloseOrderFields;
        get_close_order_fields(&close_order_fields);

        verify_close_order_hash(order, close_order_fields);

        verify_order_signature(order.hash, position);

        execute_close_order(
            order, close_order_fields, position, spent_collateral, spent_synthetic, fee_taken
        );

        return ();
    }

    return ();
}

// * ============================================================

func execute_open_order{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    fee_tracker_dict: DictAccess*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    order: PerpOrder,
    other_order: PerpOrder,
    open_order_fields: OpenOrderFields,
    spent_collateral: felt,
    spent_synthetic: felt,
    fee_taken: felt,
) {
    alloc_locals;

    let init_margin = get_init_margin(order, open_order_fields, spent_synthetic);

    open_order_specific_checks(order, open_order_fields, spent_synthetic, init_margin, fee_taken);

    // ? Take a fee
    validate_fee_taken(fee_taken, order, spent_collateral);
    take_fee(open_order_fields.collateral_token, fee_taken);

    if (nondet %{ is_first_fill %} != 0) {
        let (sum: felt) = sum_notes(
            open_order_fields.notes_in_len,
            open_order_fields.notes_in,
            open_order_fields.collateral_token,
            0,
        );
        assert sum = open_order_fields.refund_note.amount + open_order_fields.initial_margin;

        verify_open_order_signature(
            order.hash, open_order_fields.notes_in_len, open_order_fields.notes_in
        );

        let (scaler) = pow(10, global_config.leverage_decimals);
        let (leverage: felt, _) = unsigned_div_rem(
            spent_collateral * scaler, (init_margin - fee_taken)
        );

        let (position: PerpPosition) = open_new_position(
            order,
            init_margin,
            fee_taken,
            leverage,
            open_order_fields,
            spent_collateral,
            spent_synthetic,
        );

        // ? Add the position to the position dict and program output
        update_position_state(0, position);

        // ? Refund excess margin if necessary
        refund_unspent_margin_first_fill(order, open_order_fields, init_margin, spent_synthetic);

        // ? Update state dict
        update_state_dict(
            open_order_fields.notes_in_len,
            open_order_fields.notes_in,
            open_order_fields.refund_note,
        );

        return ();
    } else {
        local prev_pfr_note: Note;
        %{
            note_data = prev_pfr_note

            memory[ids.prev_pfr_note.address_ + ADDRESS_OFFSET + 0] = int(note_data["address"]["x"]) # x coordinate
            memory[ids.prev_pfr_note.address_ + ADDRESS_OFFSET + 1] = int(note_data["address"]["y"]) # y coordinate
            memory[ids.prev_pfr_note.address_ + TOKEN_OFFSET] = int(note_data["token"])
            memory[ids.prev_pfr_note.address_ + AMOUNT_OFFSET] = int(note_data["amount"])
            memory[ids.prev_pfr_note.address_ + BLINDING_FACTOR_OFFSET] = int(note_data["blinding"])
            memory[ids.prev_pfr_note.address_ + INDEX_OFFSET] = int(note_data["index"])
            memory[ids.prev_pfr_note.address_ + HASH_OFFSET] = int(note_data["hash"])
        %}

        checks_prev_fill_consistencies(order, open_order_fields, init_margin, prev_pfr_note);

        verify_open_order_signature(
            order.hash, open_order_fields.notes_in_len, open_order_fields.notes_in
        );

        let (scaler) = pow(10, global_config.leverage_decimals);
        let (leverage: felt, _) = unsigned_div_rem(spent_collateral * scaler, init_margin);

        let (prev_position_hash: felt, position: PerpPosition) = add_margin_to_position(
            order, init_margin, spent_synthetic, fee_taken, leverage
        );

        // ? Add the position to the position dict and program output
        update_position_state(prev_position_hash, position);

        // ? Refund excess margin if necessary
        refund_unspent_margin_later_fills(
            order, open_order_fields, init_margin, spent_synthetic, prev_pfr_note
        );

        return ();
    }
}

func execute_modify_order{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    fee_tracker_dict: DictAccess*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    order: PerpOrder,
    position: PerpPosition,
    spent_collateral: felt,
    spent_synthetic: felt,
    fee_taken: felt,
) {
    alloc_locals;

    // ? Take a fee
    validate_fee_taken(fee_taken, order, spent_collateral);
    take_fee(global_config.collateral_token, fee_taken);

    let (price: felt) = get_price(order.synthetic_token, spent_collateral, spent_synthetic);

    if (order.order_side == position.order_side) {
        let (prev_position_hash: felt, position: PerpPosition) = increase_position_size(
            order, position, spent_synthetic, fee_taken, price
        );

        // ? Add the position to the position dict and program output
        update_position_state(prev_position_hash, position);
    } else {
        let (prev_position_hash: felt, position: PerpPosition) = reduce_position_size(
            order, position, spent_synthetic, fee_taken, price
        );

        // ? Add the position to the position dict and program output
        update_position_state(prev_position_hash, position);
    }

    return ();
}

func execute_close_order{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    fee_tracker_dict: DictAccess*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    order: PerpOrder,
    close_order_fields: CloseOrderFields,
    position: PerpPosition,
    spent_collateral: felt,
    spent_synthetic: felt,
    fee_taken: felt,
) {
    alloc_locals;

    // ? Take a fee
    validate_fee_taken(fee_taken, order, spent_collateral);
    take_fee(global_config.collateral_token, fee_taken);

    assert_not_equal(order.order_side, position.order_side);

    assert position.vlp_supply = 0;

    let (close_price: felt) = get_price(order.synthetic_token, spent_collateral, spent_synthetic);

    let (collateral_returned: felt) = close_position(
        order, position, spent_synthetic, fee_taken, close_price
    );

    local index: felt;
    %{ ids.index = order_indexes["return_collateral_idx"] %}

    let (return_collateral_note: Note) = construct_new_note(
        close_order_fields.dest_received_address_x,
        close_order_fields.dest_received_address_y,
        global_config.collateral_token,
        collateral_returned,
        close_order_fields.dest_received_blinding,
        index,
    );

    update_rc_state_dict(return_collateral_note);

    return ();
}

// * ============================================================

func open_new_position{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    global_config: GlobalConfig*,
}(
    order: PerpOrder,
    init_margin: felt,
    fee_taken: felt,
    leverage: felt,
    open_order_fields: OpenOrderFields,
    spent_collateral: felt,
    spent_synthetic: felt,
) -> (position: PerpPosition) {
    alloc_locals;

    local position_idx: felt;
    %{ ids.position_idx = order_indexes["position_idx"] %}

    local funding_idx: felt;
    %{ ids.funding_idx = order_indexes["new_funding_idx"] %}

    let (position: PerpPosition) = construct_new_position(
        order.order_side,
        order.synthetic_token,
        open_order_fields.collateral_token,
        spent_synthetic,
        init_margin,
        leverage,
        open_order_fields.position_address,
        funding_idx,
        position_idx,
        fee_taken,
        open_order_fields.allow_partial_liquidations,
    );

    return (position,);
}

func add_margin_to_position{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(order: PerpOrder, init_margin: felt, added_size: felt, fee_taken: felt, leverage: felt) -> (
    prev_hash: felt, position: PerpPosition
) {
    alloc_locals;

    let position: PerpPosition = get_perp_position();

    let prev_position_hash = position.hash;

    assert position.order_side = order.order_side;

    let (position: PerpPosition) = add_margin_to_position_internal(
        position, init_margin, added_size, leverage, fee_taken
    );

    %{
        if ids.position.hash == 598345844227516041230339568462156132804121144810609493676183821408345703711:
            print_position(ids.position.address_)
    %}

    return (prev_position_hash, position);
}

func increase_position_size{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    order: PerpOrder, position: PerpPosition, spent_synthetic: felt, fee_taken: felt, price: felt
) -> (prev_hash: felt, position: PerpPosition) {
    alloc_locals;

    let prev_position_hash = position.hash;

    assert position.order_side = order.order_side;

    local funding_idx: felt;
    %{ ids.funding_idx = order_indexes["new_funding_idx"] %}

    let (position: PerpPosition) = increase_position_size_internal(
        position, spent_synthetic, price, fee_taken, funding_idx
    );

    return (prev_position_hash, position);
}

func reduce_position_size{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    order: PerpOrder, position: PerpPosition, spent_synthetic: felt, fee_taken: felt, price: felt
) -> (prev_hash: felt, position: PerpPosition) {
    alloc_locals;

    let prev_position_hash = position.hash;

    assert_not_equal(position.order_side, order.order_side);

    local funding_idx: felt;
    %{ ids.funding_idx = order_indexes["new_funding_idx"] %}

    let (dust_amount: felt) = get_dust_amount(order.synthetic_token);
    let cond = is_le(position.position_size + dust_amount, spent_synthetic);

    if (cond == 0) {
        let (position: PerpPosition) = reduce_position_size_internal(
            position, spent_synthetic, price, fee_taken, funding_idx
        );

        return (prev_position_hash, position);
    } else {
        let (position: PerpPosition) = flip_position_side_internal(
            position, spent_synthetic, price, fee_taken, funding_idx
        );

        return (prev_position_hash, position);
    }
}

func close_position{
    poseidon_ptr: PoseidonBuiltin*,
    range_check_ptr,
    state_dict: DictAccess*,
    note_updates: Note*,
    funding_info: FundingInfo*,
    global_config: GlobalConfig*,
}(
    order: PerpOrder,
    position: PerpPosition,
    spent_synthetic: felt,
    fee_taken: felt,
    close_price: felt,
) -> (collateral_returned: felt) {
    alloc_locals;

    let position_idx = position.index;
    let prev_position_hash = position.hash;

    // ! close position fully
    let (dust_amount) = get_dust_amount(order.synthetic_token);
    let is_full_close: felt = is_le(position.position_size - spent_synthetic, dust_amount);
    if (is_full_close == 1) {
        //

        local funding_idx: felt;
        %{ ids.funding_idx = order_indexes["new_funding_idx"] %}

        let (collateral_returned: felt) = close_position_internal(
            position, close_price, fee_taken, funding_idx
        );

        update_position_state_on_close(prev_position_hash, position_idx);

        return (collateral_returned,);
    } else {
        //

        local funding_idx: felt;
        %{ ids.funding_idx = order_indexes["new_funding_idx"] %}

        let (position: PerpPosition, collateral_returned: felt) = close_position_partialy_internal(
            position, spent_synthetic, close_price, fee_taken, funding_idx
        );

        // ? Removes the position to the position dict and program output
        update_position_state(prev_position_hash, position);

        return (collateral_returned,);
    }
}

// * ============================================================

func refund_unspent_margin_first_fill{
    range_check_ptr: felt,
    poseidon_ptr: PoseidonBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    global_config: GlobalConfig*,
}(order: PerpOrder, open_order_fields: OpenOrderFields, init_margin: felt, spent_synthetic: felt) {
    alloc_locals;

    let unspent_margin = open_order_fields.initial_margin - init_margin;

    let (dust_amount_synthetic) = get_dust_amount(order.synthetic_token);
    let (dust_amount_collateral) = get_dust_amount(global_config.collateral_token);

    let order_filled_partialy: felt = is_le(
        spent_synthetic + dust_amount_synthetic, order.synthetic_amount
    );
    let all_margin_spent: felt = is_le(unspent_margin, dust_amount_collateral);

    if (all_margin_spent == 1) {
        return ();
    }

    let notes_in_0 = open_order_fields.notes_in[0];
    refund_partial_fill(
        order,
        notes_in_0.address.x,
        notes_in_0.address.y,
        notes_in_0.blinding_factor,
        open_order_fields.collateral_token,
        unspent_margin,
    );

    return ();
}

func refund_unspent_margin_later_fills{
    range_check_ptr,
    poseidon_ptr: PoseidonBuiltin*,
    state_dict: DictAccess*,
    note_updates: Note*,
    global_config: GlobalConfig*,
}(
    order: PerpOrder,
    open_order_fields: OpenOrderFields,
    init_margin: felt,
    spent_synthetic: felt,
    pfr_note: Note,
) {
    alloc_locals;

    let unspent_margin = pfr_note.amount - init_margin;

    let (dust_amount_synthetic) = get_dust_amount(order.synthetic_token);
    let (dust_amount_collateral) = get_dust_amount(global_config.collateral_token);

    let all_margin_spent: felt = is_le(unspent_margin, dust_amount_collateral);

    if (all_margin_spent == 1) {
        remove_prev_pfr_note(pfr_note);
        return ();
    }

    refund_partial_fill(
        order,
        pfr_note.address.x,
        pfr_note.address.y,
        pfr_note.blinding_factor,
        open_order_fields.collateral_token,
        unspent_margin,
    );

    return ();
}

// * ============================================================

func get_perp_position() -> PerpPosition {
    alloc_locals;

    local position: PerpPosition;

    %{
        position_addr = ids.position.address_
        position_header_addr = ids.position.position_header.address_

        memory[position_addr + ids.PerpPosition.order_side] = 1 if prev_position["order_side"] == "Long" else 0
        memory[position_addr + ids.PerpPosition.position_size] = int(prev_position["position_size"])
        memory[position_addr + ids.PerpPosition.margin] = int(prev_position["margin"])
        memory[position_addr + ids.PerpPosition.entry_price] = int(prev_position["entry_price"])
        memory[position_addr + ids.PerpPosition.liquidation_price] = int(prev_position["liquidation_price"])
        memory[position_addr + ids.PerpPosition.bankruptcy_price] = int(prev_position["bankruptcy_price"])
        memory[position_addr + ids.PerpPosition.last_funding_idx] = int(prev_position["last_funding_idx"])
        memory[position_addr + ids.PerpPosition.index] = int(prev_position["index"])
        memory[position_addr + ids.PerpPosition.vlp_supply] = int(prev_position["vlp_supply"])
        memory[position_addr + ids.PerpPosition.hash] = int(prev_position["hash"])

        memory[position_header_addr + ids.PositionHeader.synthetic_token] = int(prev_position["position_header"]["synthetic_token"])
        memory[position_header_addr + ids.PositionHeader.position_address] = int(prev_position["position_header"]["position_address"])
        memory[position_header_addr + ids.PositionHeader.allow_partial_liquidations] = int(prev_position["position_header"]["allow_partial_liquidations"])
        memory[position_header_addr + ids.PositionHeader.vlp_token] = int(prev_position["position_header"]["vlp_token"])
        memory[position_header_addr + ids.PositionHeader.hash] = int(prev_position["position_header"]["hash"])
    %}

    return (position);
}

// * ============================================================

func get_open_order_fields{poseidon_ptr: PoseidonBuiltin*}(open_order_fields: OpenOrderFields*) {
    %{
        ## open_order_field_inputs = current_order["open_order_fields"]

        memory[ids.open_order_fields.address_ + INITIAL_MARGIN_OFFSET] = int(open_order_field_inputs["initial_margin"])
        memory[ids.open_order_fields.address_ + OOF_COLLATERAL_TOKEN_OFFSET] = int(open_order_field_inputs["collateral_token"])

        memory[ids.open_order_fields.address_ + POSITION_ADDRESS_OFFSET] = int(open_order_field_inputs["position_address"]) # x coordinate
        memory[ids.open_order_fields.address_ + ALLOW_PARTIAL_LIQUIDATIONS_OFFSET] =  1 if open_order_field_inputs["allow_partial_liquidations"] else 0    

        input_notes = open_order_field_inputs["notes_in"]
        memory[ids.open_order_fields.address_ + NOTES_IN_LEN_OFFSET] = len(input_notes)
        memory[ids.open_order_fields.address_ + NOTES_IN_OFFSET] = notes_ = segments.add()
        for i in range(len(input_notes)):
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET + 0] = int(open_order_field_inputs["notes_in"][i]["address"]["x"]) # x coordinate
            memory[notes_ + i* NOTE_SIZE + ADDRESS_OFFSET + 1] = int(open_order_field_inputs["notes_in"][i]["address"]["y"]) # y coordinate
            memory[notes_ + i* NOTE_SIZE + TOKEN_OFFSET] = int(open_order_field_inputs["notes_in"][i]["token"])
            memory[notes_ + i* NOTE_SIZE + AMOUNT_OFFSET] = int(open_order_field_inputs["notes_in"][i]["amount"])
            memory[notes_ + i* NOTE_SIZE + BLINDING_FACTOR_OFFSET] = int(open_order_field_inputs["notes_in"][i]["blinding"])
            memory[notes_ + i* NOTE_SIZE + INDEX_OFFSET] = int(open_order_field_inputs["notes_in"][i]["index"])
            memory[notes_ + i* NOTE_SIZE + HASH_OFFSET] = int(open_order_field_inputs["notes_in"][i]["hash"])

        refund_note_ =  open_order_field_inputs["refund_note"]
        if refund_note_ is not None:
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + ADDRESS_OFFSET + 0] = int(refund_note_["address"]["x"]) # x coordinate
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + ADDRESS_OFFSET + 1] = int(refund_note_["address"]["y"]) # y coordinate
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + TOKEN_OFFSET] = int(refund_note_["token"])
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + AMOUNT_OFFSET] = int(refund_note_["amount"])
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + BLINDING_FACTOR_OFFSET] = int(refund_note_["blinding"])
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + INDEX_OFFSET] = int(refund_note_["index"])
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + HASH_OFFSET] = int(refund_note_["hash"])
        else:
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + ADDRESS_OFFSET + 0] = 0
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + ADDRESS_OFFSET + 1] = 0
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + TOKEN_OFFSET] = 0
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + AMOUNT_OFFSET] = 0
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + BLINDING_FACTOR_OFFSET] = 0
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + INDEX_OFFSET] = 0
            memory[ids.open_order_fields.address_ + REFUND_NOTE_OFFSET + HASH_OFFSET] = 0
    %}

    return ();
}

func get_close_order_fields{poseidon_ptr: PoseidonBuiltin*}(close_order_fields: CloseOrderFields*) {
    %{
        close_order_field_inputs = current_order["close_order_fields"]

        memory[ids.close_order_fields.address_ + ids.CloseOrderFields.dest_received_address_x] = int(close_order_field_inputs["dest_received_address"]["x"])
        memory[ids.close_order_fields.address_ + ids.CloseOrderFields.dest_received_address_y] = int(close_order_field_inputs["dest_received_address"]["y"])
        memory[ids.close_order_fields.address_ + ids.CloseOrderFields.dest_received_blinding] = int(close_order_field_inputs["dest_received_blinding"])
    %}

    return ();
}

// ? GET INIT MARGIN
func get_init_margin{range_check_ptr}(
    order: PerpOrder, open_order_fields: OpenOrderFields, spent_synthetic: felt
) -> felt {
    alloc_locals;

    let (margin, _) = unsigned_div_rem(
        open_order_fields.initial_margin * spent_synthetic, order.synthetic_amount
    );

    return margin;
}
