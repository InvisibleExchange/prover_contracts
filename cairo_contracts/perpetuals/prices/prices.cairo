from starkware.cairo.common.cairo_builtins import PoseidonBuiltin, SignatureBuiltin
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.math import unsigned_div_rem, assert_le
from starkware.cairo.common.bool import TRUE

from rollup.global_config import get_array_index_for_token, get_observer_by_index, GlobalConfig
from helpers.utils import Note

struct PriceRange {
    min: felt,
    max: felt,
}

// TODO: check the timestamp is valid

func get_price_ranges{range_check_ptr, ecdsa_ptr: SignatureBuiltin*, global_config: GlobalConfig*}(
    ) -> (price_ranges: PriceRange*) {
    alloc_locals;

    // // TODO: this if statement is only for testing
    // if (0 == 0) {
    //     let (local prices_ranges: PriceRange*) = alloc();
    //     return (prices_ranges,);
    // }

    %{ price_data = program_input["price_info"] %}

    let (local prices_ranges: PriceRange*) = alloc();

    get_prices_internal(prices_ranges);

    return (prices_ranges,);
}

func get_prices_internal{
    range_check_ptr, ecdsa_ptr: SignatureBuiltin*, global_config: GlobalConfig*
}(prices_array: PriceRange*) -> (prices_array: PriceRange*) {
    alloc_locals;

    if (nondet %{ len(price_data) == 0 %} != 0) {
        return (prices_array,);
    }

    local token: felt;
    local min_prices_len: felt;
    local min_prices: felt*;
    local max_prices_len: felt;
    local max_prices: felt*;
    %{
        # TODO minimum number of observations to consider a token observation valid
        OBSERVATIONS_TRESHOLD = 10  
        token_price_data = price_data.pop(0)

        ids.token = int(token_price_data["token"])

        min_price_data = token_price_data["min"]
        max_price_data = token_price_data["max"]

        observations_min_len = len(min_price_data["prices"])
        assert observations_min_len == len(min_price_data["signatures"])

        observations_max_len = len(max_price_data["prices"])
        assert observations_max_len == len(max_price_data["signatures"])


        ids.min_prices_len = observations_min_len
        ids.min_prices = min_prices_addr = segments.add() 
        for i in range(observations_min_len):
            memory[min_prices_addr + i] = int(min_price_data["prices"][i])

        ids.max_prices_len = observations_max_len
        ids.max_prices = max_prices_addr = segments.add()
        for i in range(observations_max_len):
            memory[max_prices_addr + i] = int(max_price_data["prices"][i])
    %}

    %{ price_bound_data = min_price_data %}
    let (min_prices_median: felt) = _verify_and_get_median(min_prices_len, min_prices, token);

    %{ price_bound_data = max_price_data %}
    let (max_prices_median: felt) = _verify_and_get_median(max_prices_len, max_prices, token);

    let (token_price_array_index: felt) = get_array_index_for_token(token, TRUE);

    let price_range: PriceRange = PriceRange(min_prices_median, max_prices_median);

    assert prices_array[token_price_array_index] = price_range;

    return get_prices_internal(prices_array);
}

func _verify_and_get_median{
    range_check_ptr, ecdsa_ptr: SignatureBuiltin*, global_config: GlobalConfig*
}(prices_len: felt, prices: felt*, token: felt) -> (price: felt) {
    alloc_locals;

    local timestamp: felt;
    %{
        ids.timestamp = int(price_bound_data["timestamp"])
        observer_idxs = price_bound_data["observer_idxs"]
        price_signatures = price_bound_data["signatures"]
    %}
    _verify_price_signatures(prices_len, prices, token, timestamp);

    assert_array_sorted(prices_len, prices);

    let (median_idx: felt, _) = unsigned_div_rem(prices_len, 2);
    let prices_median = prices[median_idx];

    return (prices_median,);
}

func _verify_price_signatures{
    range_check_ptr, ecdsa_ptr: SignatureBuiltin*, global_config: GlobalConfig*
}(prices_len: felt, prices: felt*, token: felt, timestamp: felt) {
    alloc_locals;

    if (prices_len == 0) {
        return ();
    }

    local observer_idx: felt;
    local sig_r: felt;
    local sig_s: felt;
    %{
        ids.observer_idx = int(observer_idxs.pop(0))

        sig = price_signatures.pop(0)
        ids.sig_r = int(sig[0])
        ids.sig_s = int(sig[1])
    %}

    let price = prices[0];
    let (observer_pk: felt) = get_observer_by_index(observer_idx);

    // Todo: figure this out
    let msg = (price * 2 ** 64 + token) * 2 ** 64 + timestamp;

    verify_ecdsa_signature(
        message=msg, public_key=observer_pk, signature_r=sig_r, signature_s=sig_s
    );

    return _verify_price_signatures(prices_len - 1, &prices[1], token, timestamp);
}

// * VALIDATE PRICE IS IN RANGE * #

func validate_price_in_range{
    range_check_ptr, price_ranges: PriceRange*, global_config: GlobalConfig*
}(price: felt, token: felt) {
    let (token_arr_idx: felt) = get_array_index_for_token(token, TRUE);

    let price_range: PriceRange = price_ranges[token_arr_idx];

    assert_le(price_range.min, price);
    assert_le(price, price_range.max);

    return ();
}

// * HELPERS * #

func assert_array_sorted{range_check_ptr}(arr_len: felt, arr: felt*) -> () {
    if (arr_len == 1) {
        return ();
    }

    let current = arr[0];
    let next = arr[1];
    with_attr error_message("==== (ARRAY ELEMENTS ARE NOT SORTED ASCENDINGLY) ====") {
        assert_le(current, next);
    }

    return assert_array_sorted(arr_len - 1, &arr[1]);
}
