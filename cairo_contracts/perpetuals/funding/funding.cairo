from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.math import signed_div_rem
from starkware.cairo.common.pow import pow

from helpers.utils import Note, hash_notes_array, get_price
from rollup.global_config import token_decimals, price_decimals, GlobalConfig

from perpetuals.order.order_structs import PerpPosition

struct FundingInfo {
    // & funding_rates structure is as follows:
    // &  [0] = token id, [1] = min_funding_idx, [2] = token funding_rates len (n), [3..n] = funding_rates
    // &  [n] = token id, [n+1] = min_funding_idx,  [n+2] = token funding_rates len (m), [n+3..n+m]
    // &  [n+m] = token id, [n+m+1] = min_funding_idx, [n+m+2] = token funding_rates len (o), [n+m+3..n+m+o] ...
    funding_rates: felt*,
    // & similar structure for funding_prices:
    // & [0] = token id, [1..n] = prices ...
    funding_prices: felt*,
}

// * APPLY FUNDING * #

func apply_funding{range_check_ptr, funding_info: FundingInfo*, global_config: GlobalConfig*}(
    position: PerpPosition, new_funding_idx: felt
) -> (new_margin: felt) {
    alloc_locals;

    let (synthetic_decimals: felt) = token_decimals(position.position_header.synthetic_token);
    let (synthetic_price_decimals: felt) = price_decimals(position.position_header.synthetic_token);

    tempvar decimal_conversion = synthetic_decimals + synthetic_price_decimals - 6;
    let (multiplier: felt) = pow(10, decimal_conversion);

    let (
        applicable_funding_rates_len: felt,
        applicable_funding_rates: felt*,
        applicable_funding_prices_len: felt,
        applicable_funding_prices: felt*,
    ) = get_applicable_funding_arrays(
        position.position_header.synthetic_token, position.last_funding_idx, new_funding_idx
    );

    let (margin_after_funding: felt) = get_margin_after_funding(
        position.position_size,
        position.margin,
        multiplier,
        position.order_side,
        applicable_funding_rates_len,
        applicable_funding_rates,
        applicable_funding_prices_len,
        applicable_funding_prices,
    );

    return (margin_after_funding,);
}

func get_margin_after_funding{range_check_ptr}(
    size: felt,
    margin: felt,
    multiplier: felt,
    order_side: felt,
    funding_rates_len: felt,
    funding_rates: felt*,
    prices_len: felt,
    prices: felt*,
) -> (size: felt) {
    if (funding_rates_len == 0) {
        return (margin,);
    }

    let (bound: felt) = pow(2, 64);

    // funding rate has 5 decimal places
    let funding_rate = funding_rates[0];
    let (funding: felt, _) = signed_div_rem(size * funding_rate, 100000, bound);

    let (funding_payment_margin: felt, _) = signed_div_rem(funding * prices[0], multiplier, bound);

    let margin_after_funding = margin - funding_payment_margin + 2 * funding_payment_margin *
        order_side;

    return get_margin_after_funding(
        size,
        margin_after_funding,
        multiplier,
        order_side,
        funding_rates_len - 1,
        &funding_rates[1],
        prices_len - 1,
        &prices[1],
    );
}

func get_applicable_funding_arrays{funding_info: FundingInfo*}(
    token: felt, prev_funding_idx: felt, new_funding_idx: felt
) -> (frs_len: felt, frs: felt*, fps_len: felt, fps: felt*) {
    //

    return _get_applicable_funding_arrays_inner(
        funding_info.funding_rates,
        funding_info.funding_prices,
        token,
        prev_funding_idx,
        new_funding_idx,
    );
}

func _get_applicable_funding_arrays_inner{funding_info: FundingInfo*}(
    funding_rates: felt*,
    funding_prices: felt*,
    token: felt,
    prev_funding_idx: felt,
    new_funding_idx: felt,
) -> (frs_len: felt, frs: felt*, fps_len: felt, fps: felt*) {
    alloc_locals;

    let token_id = funding_rates[0];
    let min_funding_idx = funding_rates[1];
    let token_funding_rates_len = funding_rates[2];

    if (token_id == token) {
        assert funding_prices[0] = token_id;

        // Todo: might be plus or minus 1 in start stop (figure this out)
        let start = prev_funding_idx - min_funding_idx;
        let stop = new_funding_idx - min_funding_idx - 1;

        let (frs_len: felt, frs: felt*) = array_slice(&funding_rates[3], start, stop);
        let (fps_len: felt, fps: felt*) = array_slice(&funding_prices[1], start, stop);

        return (frs_len, frs, fps_len, fps);
    } else {
        return _get_applicable_funding_arrays_inner(
            &funding_rates[3 + token_funding_rates_len],
            &funding_prices[1 + token_funding_rates_len],
            token,
            prev_funding_idx,
            new_funding_idx,
        );
    }
}

func array_slice(arr: felt*, start: felt, stop: felt) -> (arr_len: felt, arr: felt*) {
    // returns an array slice from start to including stop

    let len = stop - start + 1;

    return (len, &arr[start]);
}

// * ======================================================

func set_funding_info(funding_info: FundingInfo*) {
    %{
        # * STRUCT SIZES ==========================================================
        FUNDING_INFO_SIZE = ids.FundingInfo.SIZE
        FUNDING_RATES_OFFSET = ids.FundingInfo.funding_rates
        FUNDING_PRICES_OFFSET = ids.FundingInfo.funding_prices

        PRIME = 2**251 + 17 * 2**192 + 1

        funding_rates_ = program_input["funding_info"]["funding_rates"]
        funding_prices_ = program_input["funding_info"]["funding_prices"]

        memory[ids.funding_info.address_ +  FUNDING_RATES_OFFSET] = frs_address = segments.add()
        for i in range(len(funding_rates_)):
            memory[frs_address + i ] = int(funding_rates_[i] % PRIME)

        memory[ids.funding_info.address_ +  FUNDING_PRICES_OFFSET] = fps_address = segments.add()
        for i in range(len(funding_prices_)):
            memory[fps_address + i ] = int(funding_prices_[i] % PRIME)
    %}
    return ();
}
