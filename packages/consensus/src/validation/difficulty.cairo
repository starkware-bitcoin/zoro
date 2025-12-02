//! Difficulty target validation helpers.
//!
//! Read more:
//!   - https://learnmeabitcoin.com/technical/mining/target/
//!   - https://learnmeabitcoin.com/technical/block/bits/

use consensus::params::{
    POW_AVERAGING_WINDOW, POW_LIMIT, POW_MAX_ADJUST_DOWN, POW_MAX_ADJUST_UP, pow_target_spacing,
};
use core::array::ArrayTrait;
use utils::bit_shifts::fast_pow;
use utils::numeric::u256_to_u32x8;

/// Checks if the given bits match the target difficulty.
pub fn validate_bits(target: u256, bits: u32) -> Result<(), ByteArray> {
    if bits_to_target(bits)? == target {
        Result::Ok(())
    } else {
        Result::Err(format!("Block header bits {} do not match target {}", bits, target))
    }
}

/// Adjusts difficulty target using Zcash's DigiShield-v3 algorithm.
pub fn adjust_difficulty(
    pow_targets: Span<u256>, block_height: u32, last_mtp: u32, window_start_mtp: u32,
) -> u256 {
    let avg_target = average_target(pow_targets);
    let spacing: u64 = pow_target_spacing(block_height).into();
    let averaging_window_timespan: u64 = POW_AVERAGING_WINDOW.into() * spacing;

    let mut actual_timespan: u64 = (last_mtp - window_start_mtp).into();
    if actual_timespan > averaging_window_timespan {
        let diff = actual_timespan - averaging_window_timespan;
        actual_timespan = averaging_window_timespan + diff / 4;
    } else {
        let diff = averaging_window_timespan - actual_timespan;
        actual_timespan = averaging_window_timespan - diff / 4;
    }

    let max_adjust_up: u64 = POW_MAX_ADJUST_UP.into();
    let max_adjust_down: u64 = POW_MAX_ADJUST_DOWN.into();

    let min_timespan = averaging_window_timespan * (100 - max_adjust_up) / 100;
    let max_timespan = averaging_window_timespan * (100 + max_adjust_down) / 100;

    if actual_timespan < min_timespan {
        actual_timespan = min_timespan;
    }
    if actual_timespan > max_timespan {
        actual_timespan = max_timespan;
    }

    let actual_timespan_u128: u128 = actual_timespan.into();
    let averaging_window_timespan_u128: u128 = averaging_window_timespan.into();
    let actual_timespan_u256: u256 = actual_timespan_u128.into();
    let averaging_window_timespan_u256: u256 = averaging_window_timespan_u128.into();

    let mut new_target: u256 = avg_target * actual_timespan_u256 / averaging_window_timespan_u256;
    if new_target > POW_LIMIT {
        new_target = POW_LIMIT;
    }
    reduce_target_precision(new_target)
}

/// Returns true if the history contains enough entries to run the full averaging window.
pub fn has_full_pow_window(pow_targets: Span<u256>) -> bool {
    pow_targets.len() >= POW_AVERAGING_WINDOW
}

/// Updates the queue of difficulty targets with the most recent block target.
pub fn next_pow_targets(pow_targets: Span<u256>, new_target: u256) -> Span<u256> {
    let mut targets: Array<u256> = pow_targets.into();
    if targets.len() == POW_AVERAGING_WINDOW {
        targets.pop_front().unwrap();
    }
    targets.append(new_target);
    targets.span()
}

fn average_target(pow_targets: Span<u256>) -> u256 {
    assert!(pow_targets.len() > 0, "empty pow target history");
    let mut total: u256 = 0;
    for target in pow_targets {
        total += *target;
    }
    let len_u128: u128 = pow_targets.len().into();
    total / len_u128.into()
}


/// Reduces target precision leaving just 3 most significant bytes.
///
/// Note that the most significant byte might be ZERO in case the following
/// one is >= 0x80 (see "caution" section on https://learnmeabitcoin.com/technical/block/bits/).
/// This helper assumes the given target is strictly less than POW_LIMIT.
fn reduce_target_precision(target: u256) -> u256 {
    if target == 0 {
        return target;
    }

    let bits = target_to_compact(target);
    match bits_to_target(bits) {
        Result::Ok(value) => value,
        Result::Err(err) => panic!("compact target converts to integer: {}", err),
    }
}

fn target_to_compact(target: u256) -> u32 {
    if target == 0 {
        return 0;
    }

    // Determine the byte size (exponent)
    let mut size: u32 = 0;
    let mut num = target;
    while num != 0 {
        num /= 256;
        size += 1;
    }

    // Compute mantissa
    let mut mantissa_value: u256 = target;
    if size > 3 {
        let factor = fast_pow(256_u256, size - 3);
        mantissa_value /= factor;
    } else if size < 3 {
        let factor = fast_pow(256_u256, 3 - size);
        mantissa_value *= factor;
    }

    let mut mantissa: u32 = expect_u32(mantissa_value);

    if mantissa & 0x00800000_u32 != 0 {
        mantissa /= 256;
        size += 1;
    }

    size * 0x1000000 + (mantissa & 0x007fffff_u32)
}

fn expect_u32(value: u256) -> u32 {
    assert!(value.high == 0, "value exceeds u32 range");
    assert!(value.low <= 0xFFFFFFFF_u128, "value exceeds u32 range");
    let [_a, _b, _c, _d, _e, _f, _g, h] = u256_to_u32x8(value);
    h
}


/// Converts the difficulty target compact form (bits) to a big integer.
fn bits_to_target(bits: u32) -> Result<u256, ByteArray> {
    let (exponent, mantissa) = core::traits::DivRem::div_rem(bits, 0x1000000);

    if mantissa > 0x7FFFFF && exponent != 0 {
        return Result::Err("Target cannot have most significant bit set");
    }

    if exponent > 32 {
        return Result::Err("Target size cannot exceed 32 bytes");
    }

    let mut target: u256 = mantissa.into();

    if exponent > 3 {
        let mut shift = exponent - 3;
        while shift > 0 {
            target *= 256;
            shift -= 1;
        }
    } else if exponent < 3 {
        let mut shift = 3 - exponent;
        while shift > 0 {
            target /= 256;
            shift -= 1;
        }
    }

    if target > POW_LIMIT {
        Result::Err("Target exceeds maximum value")
    } else {
        Result::Ok(target)
    }
}

#[cfg(test)]
mod tests {
    use consensus::params::{POW_AVERAGING_WINDOW, POW_LIMIT, pow_target_spacing};
    use super::{adjust_difficulty, bits_to_target, has_full_pow_window, next_pow_targets};

    #[test]
    fn test_adjust_difficulty_fast_blocks_reduces_target() {
        let current_target = POW_LIMIT / 4_u256;
        let history = pow_history(current_target);
        let spacing = pow_target_spacing(1);
        let avg_span = POW_AVERAGING_WINDOW * spacing;
        let last_mtp = 1_000_000_u32;
        let window_start_mtp = last_mtp - avg_span / 2;

        let new_target = adjust_difficulty(history, 1, last_mtp, window_start_mtp);
        assert!(new_target < super::reduce_target_precision(current_target));
    }

    #[test]
    fn test_adjust_difficulty_slow_blocks_increases_target() {
        let current_target = POW_LIMIT / 8_u256;
        let history = pow_history(current_target);
        let spacing = pow_target_spacing(1);
        let avg_span = POW_AVERAGING_WINDOW * spacing;
        let last_mtp = 1_000_000_u32;
        let window_start_mtp = last_mtp - avg_span * 2;

        let new_target = adjust_difficulty(history, 1, last_mtp, window_start_mtp);
        assert!(new_target > super::reduce_target_precision(current_target));
    }

    #[test]
    fn test_adjust_difficulty_matches_average_timespan() {
        let history = pow_history(POW_LIMIT / 2_u256);
        let spacing = pow_target_spacing(1);
        let avg_span = POW_AVERAGING_WINDOW * spacing;
        let last_mtp = 10_000_u32;
        let first_mtp = last_mtp - avg_span;
        let new_target = adjust_difficulty(history, 1, last_mtp, first_mtp);
        assert_eq!(new_target, super::reduce_target_precision(POW_LIMIT / 2_u256));
    }

    #[test]
    fn test_adjust_difficulty_caps_to_pow_limit() {
        let history = pow_history(POW_LIMIT);
        let spacing = pow_target_spacing(1);
        let avg_span = POW_AVERAGING_WINDOW * spacing;
        let last_mtp = avg_span * 200;
        let first_mtp = last_mtp - avg_span * 100;
        let new_target = adjust_difficulty(history, 1, last_mtp, first_mtp);
        assert!(new_target <= POW_LIMIT);
        assert!(new_target > POW_LIMIT / 2_u256);
    }

    #[test]
    fn test_pow_target_history_updates() {
        let mut history = array![].span();
        history = next_pow_targets(history, 1_u256);
        assert_eq!(history.len(), 1);
        let mut arr = pow_history(0_u256);
        history = next_pow_targets(arr, 42_u256);
        assert_eq!(history.len(), POW_AVERAGING_WINDOW);
        assert_eq!(*history[0], 0_u256);
        assert_eq!(*history[history.len() - 1], 42_u256);
    }

    #[test]
    fn test_has_full_pow_window() {
        let empty = array![].span();
        assert!(!has_full_pow_window(empty));
        let full = pow_history(POW_LIMIT);
        assert!(has_full_pow_window(full));
    }

    fn pow_history(value: u256) -> Span<u256> {
        let mut history: Array<u256> = array![];
        let mut idx = 0;
        loop {
            history.append(value);
            idx += 1;
            if idx == POW_AVERAGING_WINDOW {
                break;
            }
        }
        history.span()
    }

    #[test]
    fn test_reduce_target_precision() {
        assert_eq!(super::reduce_target_precision(0x00), 0x00);
        assert_eq!(super::reduce_target_precision(0x01), 0x01);
        assert_eq!(super::reduce_target_precision(0x80), 0x80);
        assert_eq!(super::reduce_target_precision(0x8001), 0x8001);
        assert_eq!(super::reduce_target_precision(0x0102), 0x0102);
        assert_eq!(super::reduce_target_precision(0x7f0001), 0x7f0001);
        assert_eq!(super::reduce_target_precision(0x800001), 0x800000);
        assert_eq!(super::reduce_target_precision(0x800001), 0x800000);
        assert_eq!(
            super::reduce_target_precision(
                0x00000000FFFF0000000000000000000000000000000000000000000000000000,
            ),
            0x00000000FFFF0000000000000000000000000000000000000000000000000000,
        );
        assert_eq!(
            super::reduce_target_precision(
                0x00000000FFFF0100000000000000000000000000000000000000000000000000,
            ),
            0x00000000FFFF0000000000000000000000000000000000000000000000000000,
        );
        assert_eq!(
            super::reduce_target_precision(
                0x00000001FFFF0100000000000000000000000000000000000000000000000000,
            ),
            0x00000001FFFF0000000000000000000000000000000000000000000000000000,
        );
    }

    #[test]
    fn test_bits_to_target_01003456() {
        let result = bits_to_target(0x01003456);
        assert!(result.is_ok(), "Should be valid");
        assert!(result.unwrap() == 0x00_u256, "Incorrect target for 0x01003456");
    }

    #[test]
    fn test_bits_to_target_01123456() {
        let result = bits_to_target(0x01123456);
        assert!(result.is_ok(), "Should be valid");
        assert!(result.unwrap() == 0x12_u256, "Incorrect target for 0x01123456");
    }

    #[test]
    fn test_bits_to_target_02008000() {
        let result = bits_to_target(0x02008000);
        assert!(result.is_ok(), "Should be valid");
        assert!(result.unwrap() == 0x80_u256, "Incorrect target for 0x02008000");
    }

    #[test]
    fn test_bits_to_target_181bc330() {
        let result = bits_to_target(0x181bc330);
        assert!(result.is_ok(), "Should be valid");
        assert!(
            result.unwrap() == 0x1bc330000000000000000000000000000000000000000000_u256,
            "Incorrect target for 0x181bc330",
        );
    }

    #[test]
    fn test_bits_to_target_05009234() {
        let result = bits_to_target(0x05009234);
        assert!(result.is_ok(), "Should be valid");
        assert!(result.unwrap() == 0x92340000_u256, "Incorrect target for 0x05009234");
    }

    #[test]
    fn test_bits_to_target_04123456() {
        let result = bits_to_target(0x04123456);
        assert!(result.is_ok(), "Should be valid");
        assert!(result.unwrap() == 0x12345600_u256, "Incorrect target for 0x04123456");
    }

    #[test]
    fn test_bits_to_target_1d00ffff() {
        let result = bits_to_target(0x1d00ffff);
        assert!(result.is_ok(), "Should be valid");
        assert!(
            result
                .unwrap() == 0x00000000ffff0000000000000000000000000000000000000000000000000000_u256,
            "Incorrect target for 0x1d00ffff",
        );
    }

    #[test]
    fn test_bits_to_target_1c0d3142() {
        let result = bits_to_target(0x1c0d3142);
        assert!(result.is_ok(), "Should be valid");
        assert!(
            result
                .unwrap() == 0x000000000d314200000000000000000000000000000000000000000000000000_u256,
            "Incorrect target for 0x1c0d3142",
        );
    }

    #[test]
    fn test_bits_to_target_1707a429() {
        let result = bits_to_target(0x1707a429);
        assert!(result.is_ok(), "Should be valid");
        assert!(
            result
                .unwrap() == 0x00000000000000000007a4290000000000000000000000000000000000000000_u256,
            "Incorrect target for 0x1707a429",
        );
    }

    #[test]
    fn test_bits_to_target_bounds() {
        // MSB is 0x80
        assert_eq!(
            bits_to_target(0x03800000).unwrap_err(), "Target cannot have most significant bit set",
        );
        // Exponent is 33
        assert_eq!(bits_to_target(0x2100aa00).unwrap_err(), "Target size cannot exceed 32 bytes");
        // Max target exceeded
        assert_eq!(bits_to_target(0x20010000).unwrap_err(), "Target exceeds maximum value");
    }
}
