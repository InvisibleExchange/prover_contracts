from starkware.cairo.common.cairo_builtins import PoseidonBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash, poseidon_hash_many
from starkware.cairo.common.math import split_felt

struct TabHeader {
    is_smart_contract: felt,
    base_token: felt,
    quote_token: felt,
    base_blinding: felt,
    quote_blinding: felt,
    vlp_token: felt,
    max_vlp_supply: felt,
    pub_key: felt,
    hash: felt,
}

struct OrderTab {
    tab_idx: felt,
    tab_header: TabHeader,
    base_amount: felt,
    quote_amount: felt,
    vlp_supply: felt,
    hash: felt,
}

func hash_order_tab{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(order_tab: OrderTab) -> felt {
    alloc_locals;

    let tab_hash = hash_order_tab_inner(
        order_tab.tab_header, order_tab.base_amount, order_tab.quote_amount, order_tab.vlp_supply
    );

    return tab_hash;
}

func verify_order_tab_hash{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(order_tab: OrderTab) {
    let header_hash = hash_tab_header(order_tab.tab_header);
    assert header_hash = order_tab.tab_header.hash;

    let order_tab_hash = hash_order_tab(order_tab);
    assert order_tab_hash = order_tab.hash;

    return ();
}

func hash_order_tab_inner{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    tab_header: TabHeader, base_amount: felt, quote_amount: felt, vlp_supply: felt
) -> felt {
    alloc_locals;

    let (base_commitment: felt) = poseidon_hash(base_amount, tab_header.base_blinding);

    let (quote_commitment: felt) = poseidon_hash(quote_amount, tab_header.quote_blinding);

    if (vlp_supply == 0) {
        let (local arr: felt*) = alloc();
        assert arr[0] = tab_header.hash;
        assert arr[1] = base_commitment;
        assert arr[2] = quote_commitment;
        assert arr[3] = 0;

        let (res) = poseidon_hash_many(4, arr);
        return res;
    } else {
        let (_, base_low) = split_felt(tab_header.base_blinding);
        let (_, quote_low) = split_felt(tab_header.quote_blinding);

        let (vlp_supply_commitment: felt) = poseidon_hash(vlp_supply, base_low + quote_low);

        let (local arr: felt*) = alloc();
        assert arr[0] = tab_header.hash;
        assert arr[1] = base_commitment;
        assert arr[2] = quote_commitment;
        assert arr[3] = vlp_supply_commitment;

        let (res) = poseidon_hash_many(4, arr);
        return res;
    }
}

func hash_tab_header{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    tab_header: TabHeader
) -> felt {
    alloc_locals;

    // & header_hash = H({is_smart_contract, base_token, quote_token, vlp_token, max_vlp_supply, pub_key})

    let header_hash = hash_tab_header_inner(
        tab_header.is_smart_contract,
        tab_header.base_token,
        tab_header.quote_token,
        tab_header.vlp_token,
        tab_header.max_vlp_supply,
        tab_header.pub_key,
    );

    return header_hash;
}

func hash_tab_header_inner{poseidon_ptr: PoseidonBuiltin*, range_check_ptr}(
    is_smart_contract: felt,
    base_token: felt,
    quote_token: felt,
    vlp_token: felt,
    max_vlp_supply: felt,
    pub_key: felt,
) -> felt {
    alloc_locals;

    // & header_hash = H({is_smart_contract, base_token, quote_token, vlp_token, max_vlp_supply, pub_key})

    let (local arr: felt*) = alloc();
    assert arr[0] = is_smart_contract;
    assert arr[1] = base_token;
    assert arr[2] = quote_token;
    assert arr[3] = vlp_token;
    assert arr[4] = max_vlp_supply;
    assert arr[5] = pub_key;

    let (res) = poseidon_hash_many(6, arr);
    return res;
}
