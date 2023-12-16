%builtins output range_check bitwise

from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, KeccakBuiltin
from starkware.cairo.common.cairo_keccak.keccak import (
    cairo_keccak_felts,
    cairo_keccak_felts_bigend,
    cairo_keccak_uint256s,
)
from starkware.cairo.common.builtin_keccak.keccak import (
    keccak_felts,
    keccak_uint256s,
    keccak_felts_bigend,
    keccak_uint256s_bigend,
)
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.uint256 import Uint256
from starkware.cairo.common.math import unsigned_div_rem

func main{output_ptr, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}() {
    alloc_locals;

    let x = -103;

    let (quotient, remainder) = unsigned_div_rem(-x, 10);

    let y = -quotient;

    %{
        P = 2**251 + 17 * 2**192 + 1
        print("y: ", ids.y if ids.y < P//2 else ids.y - P)
    %}

    return ();
}
