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

func main{output_ptr, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}() {
    alloc_locals;

    let (keccak_ptr: felt*) = alloc();
    local keccak_ptr_start: felt* = keccak_ptr;

    let (local inputs: felt*) = alloc();
    assert inputs[0] = 1;
    assert inputs[1] = 2;
    assert inputs[2] = 3;
    assert inputs[3] = 4;
    assert inputs[4] = 5;

    let (local inputs2: Uint256*) = alloc();
    assert inputs2[0] = Uint256(1, 0);
    assert inputs2[1] = Uint256(2, 0);
    assert inputs2[2] = Uint256(3, 0);
    assert inputs2[3] = Uint256(4, 0);
    assert inputs2[4] = Uint256(5, 0);

    with keccak_ptr {
        let (res: Uint256) = cairo_keccak_felts_bigend(5, inputs);

        %{
            print(ids.res.high * 2**128 + ids.res.low)
            print(ids.res.high * 2**128 + ids.res.low > 2**252)
        %}

        let x = res.high * 2 ** 128 + res.low;
        %{
            print("x: ", ids.x)
            print("x2: ", (ids.res.high * 2**128 + ids.res.low) % (2**251 + 17* 2**192 + 1))
        %}

        jmp end;
    }

    end:
    // let (res2: Uint256) = keccak_uint256s_bigend(5, inputs2);
    // %{
    //     print("\n", ids.res2.high * 2**128 + ids.res2.low)
    //     print(ids.res2.high  + ids.res2.low * 2**128)
    // %}

    return ();
}
