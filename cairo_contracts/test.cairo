%builtins output pedersen range_check poseidon

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin, PoseidonBuiltin
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash, poseidon_hash_many

from starkware.cairo.common.math import unsigned_div_rem, assert_le

from perpetuals.prices.prices import PriceRange, get_price_ranges, validate_price_in_range

func main{output_ptr, pedersen_ptr: HashBuiltin*, range_check_ptr, poseidon_ptr: PoseidonBuiltin*}(
    ) {
    alloc_locals;

    // let h = hash2{hash_ptr=pedersen_ptr}();

    // let (local arr) = alloc();
    // assert arr[0] = 892356257239756198358065209856295762385265783258162785126378512357263857;
    // assert arr[1] = 189246198172401851074121892461981724018510741243252189246198172401851074;
    // assert arr[2] = 263664821936291892461981724018510741218924619817240185104619817240185107;
    // assert arr[3] = 189246198172401851074124189246198172401851074124074085542858078217863492;
    // assert arr[4] = 263189246198172401851074124366189246198172401851074126198172401851074124;
    // assert arr[5] = 263618924619817240118924619817240181892461981724018510741247240185107444;
    // assert arr[6] = 263664821936297185028342543436642737036272536579074085542858078217863492;

    // let (res) = poseidon_hash_many(7, arr);

    // let (hash) = hash2{hash_ptr=pedersen_ptr}(arr[0], arr[1]);

    return ();
}
