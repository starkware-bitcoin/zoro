pub mod bit_shifts;
pub mod blake2b;
pub mod blake2s_hasher;

pub mod bytearray;
pub mod double_sha256;
pub mod hash;
pub mod merkle_tree;
pub mod mmr;
pub mod numeric;
pub mod sort;
pub mod word_array;
#[cfg(feature: "syscalls")]
pub use core::sha256 as sha256;

#[cfg(target: 'test')]
pub mod hex;

#[cfg(not(feature: "syscalls"))]
pub mod sha256;


pub use blake2b::blake2b_hash;
use core::num::traits::{DivRem, Pow, WrappingMul};

pub fn pow32(n: u32) -> u64 {
    if n == 0 {
        1
    } else if n == 1 {
        2
    } else if n == 2 {
        4
    } else if n == 3 {
        8
    } else if n == 4 {
        16
    } else if n == 5 {
        32
    } else if n == 6 {
        64
    } else if n == 7 {
        128
    } else if n == 8 {
        256
    } else if n == 9 {
        512
    } else if n == 10 {
        1024
    } else if n == 11 {
        2048
    } else if n == 12 {
        4096
    } else if n == 13 {
        8192
    } else if n == 14 {
        16384
    } else if n == 15 {
        32768
    } else if n == 16 {
        65536
    } else if n == 17 {
        131072
    } else if n == 18 {
        262144
    } else if n == 19 {
        524288
    } else if n == 20 {
        1048576
    } else if n == 21 {
        2097152
    } else if n == 22 {
        4194304
    } else if n == 23 {
        8388608
    } else if n == 24 {
        16777216
    } else if n == 25 {
        33554432
    } else if n == 26 {
        67108864
    } else if n == 27 {
        134217728
    } else if n == 28 {
        268435456
    } else if n == 29 {
        536870912
    } else if n == 30 {
        1073741824
    } else if n == 31 {
        2147483648
    } else if n == 32 {
        4294967296
    } else if n == 33 {
        8589934592
    } else if n == 34 {
        17179869184
    } else if n == 35 {
        34359738368
    } else if n == 36 {
        68719476736
    } else if n == 37 {
        137438953472
    } else if n == 38 {
        274877906944
    } else if n == 39 {
        549755813888
    } else if n == 40 {
        1099511627776
    } else if n == 41 {
        2199023255552
    } else if n == 42 {
        4398046511104
    } else if n == 43 {
        8796093022208
    } else if n == 44 {
        17592186044416
    } else if n == 45 {
        35184372088832
    } else if n == 46 {
        70368744177664
    } else if n == 47 {
        140737488355328
    } else if n == 48 {
        281474976710656
    } else if n == 49 {
        562949953421312
    } else if n == 50 {
        1125899906842624
    } else if n == 51 {
        2251799813685248
    } else if n == 52 {
        4503599627370496
    } else if n == 53 {
        9007199254740992
    } else if n == 54 {
        18014398509481984
    } else if n == 55 {
        36028797018963968
    } else if n == 56 {
        72057594037927936
    } else if n == 57 {
        144115188075855872
    } else if n == 58 {
        288230376151711744
    } else if n == 59 {
        576460752303423488
    } else if n == 60 {
        1152921504606846976
    } else if n == 61 {
        2305843009213693952
    } else if n == 62 {
        4611686018427387904
    } else if n == 63 {
        9223372036854775808
    } else {
        panic!("pow32: n out of range: {}", n)
    }
}
// ===== Helper integer ops without shifts =====

pub fn shl64(x: u64, n: u32) -> u64 {
    // x << n  ==  x * 2^n  (for n < 64 and no overflow in this domain)
    x.wrapping_mul(pow32(n))
}

pub fn shr64(x: u64, n: u32) -> u64 {
    // x >> n  ==  floor(x / 2^n)
    let denom: u64 = pow32(n);
    let (q, _) = DivRem::<u64>::div_rem(x, denom.try_into().unwrap());
    q
}
