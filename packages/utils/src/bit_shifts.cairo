//! Bit shifts and pow helpers.

use core::num::traits::{One, Zero};
use crate::WrappingMul;

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


// Fast exponentiation using the square-and-multiply algorithm.
// Reference:
// https://github.com/keep-starknet-strange/alexandria/blob/bcdca70afdf59c9976148e95cebad5cf63d75a7f/packages/math/src/fast_power.cairo#L12
pub fn fast_pow<
    T,
    U,
    +Zero<T>,
    +Zero<U>,
    +One<T>,
    +One<U>,
    +Add<U>,
    +Mul<T>,
    +Rem<U>,
    +Div<U>,
    +Copy<T>,
    +Copy<U>,
    +Drop<T>,
    +Drop<U>,
    +PartialEq<U>,
>(
    base: T, exp: U,
) -> T {
    if exp == Zero::zero() {
        return One::one();
    }

    let mut res: T = One::one();
    let mut base: T = base;
    let mut exp: U = exp;

    let two: U = One::one() + One::one();

    loop {
        if exp % two == One::one() {
            res = res * base;
        }
        exp = exp / two;
        if exp == Zero::zero() {
            break res;
        }
        base = base * base;
    }
}

/// Fast power of 2 using lookup tables.
/// Reference: https://github.com/keep-starknet-strange/alexandria/pull/336
///
/// # Arguments
/// * `exponent` - The exponent to raise 2 to
///
/// # Returns
/// * `u64` - The result of 2^exponent
///
/// # Panics
/// * If `exponent` is greater than 63 (out of the supported range)
pub fn pow2(exponent: u32) -> u64 {
    let hardcoded_results: [u64; 64] = [
        0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000, 0x2000,
        0x4000, 0x8000, 0x10000, 0x20000, 0x40000, 0x80000, 0x100000, 0x200000, 0x400000, 0x800000,
        0x1000000, 0x2000000, 0x4000000, 0x8000000, 0x10000000, 0x20000000, 0x40000000, 0x80000000,
        0x100000000, 0x200000000, 0x400000000, 0x800000000, 0x1000000000, 0x2000000000,
        0x4000000000, 0x8000000000, 0x10000000000, 0x20000000000, 0x40000000000, 0x80000000000,
        0x100000000000, 0x200000000000, 0x400000000000, 0x800000000000, 0x1000000000000,
        0x2000000000000, 0x4000000000000, 0x8000000000000, 0x10000000000000, 0x20000000000000,
        0x40000000000000, 0x80000000000000, 0x100000000000000, 0x200000000000000, 0x400000000000000,
        0x800000000000000, 0x1000000000000000, 0x2000000000000000, 0x4000000000000000,
        0x8000000000000000,
    ];
    *hardcoded_results.span()[exponent]
}

pub fn pow256(exponent: u32) -> NonZero<u256> {
    let hardcoded_results: [u256; 32] = [
        0x1, 0x100, 0x10000, 0x1000000, 0x100000000, 0x10000000000, 0x1000000000000,
        0x100000000000000, 0x10000000000000000, 0x1000000000000000000, 0x100000000000000000000,
        0x10000000000000000000000, 0x1000000000000000000000000, 0x100000000000000000000000000,
        0x10000000000000000000000000000, 0x1000000000000000000000000000000,
        0x100000000000000000000000000000000, 0x10000000000000000000000000000000000,
        0x1000000000000000000000000000000000000, 0x100000000000000000000000000000000000000,
        0x10000000000000000000000000000000000000000, 0x1000000000000000000000000000000000000000000,
        0x100000000000000000000000000000000000000000000,
        0x10000000000000000000000000000000000000000000000,
        0x1000000000000000000000000000000000000000000000000,
        0x100000000000000000000000000000000000000000000000000,
        0x10000000000000000000000000000000000000000000000000000,
        0x1000000000000000000000000000000000000000000000000000000,
        0x100000000000000000000000000000000000000000000000000000000,
        0x10000000000000000000000000000000000000000000000000000000000,
        0x1000000000000000000000000000000000000000000000000000000000000,
        0x100000000000000000000000000000000000000000000000000000000000000,
    ];
    (*hardcoded_results.span()[exponent]).try_into().unwrap()
}

#[cfg(test)]
mod tests {
    use super::{fast_pow, pow2, shr64};

    #[test]
    #[available_gas(1000000000)]
    fn test_fast_pow() {
        assert_eq!(fast_pow(2_u128, 3_u128), 8, "invalid result");
        assert_eq!(fast_pow(3_u128, 4_u128), 81, "invalid result");

        // Test with larger exponents
        assert_eq!(fast_pow(2_u128, 10_u128), 1024, "invalid result");
        assert_eq!(fast_pow(10_u128, 5_u128), 100000, "invalid result");
    }

    #[test]
    #[available_gas(1000000000)]
    fn test_pow2() {
        assert_eq!(pow2(0), 1, "2^0 should be 1");
        assert_eq!(pow2(1), 2, "2^1 should be 2");
        assert_eq!(pow2(2), 4, "2^2 should be 4");
        assert_eq!(pow2(3), 8, "2^3 should be 8");
        assert_eq!(pow2(10), 1024, "2^10 should be 1024");
        assert_eq!(pow2(63), 0x8000000000000000, "2^63 should be 0x8000000000000000");
        assert_eq!(pow2(63), 0x8000000000000000, "2^64 should be 0x8000000000000000");
    }

    #[test]
    fn test_shr_u64() {
        // Expect about 15% steps reduction over previous test,
        // should be much higher for bigger shifts
        let x: u64 = 32;
        let shift: u32 = 2;
        let result = shr64(x, shift);
        assert_eq!(result, 8);

        let shift: u32 = 32;
        let result = shr64(x, shift);
        assert_eq!(result, 0);

        let shift: u32 = 0;
        let result = shr64(x, shift);
        assert_eq!(result, 32);
    }
}
