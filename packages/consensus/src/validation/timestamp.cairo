//! Block time validation helpers.
//!
//! Read more: https://learnmeabitcoin.com/technical/block/time/

use consensus::params::{
    MAX_FUTURE_BLOCK_TIME_LOCAL, MAX_FUTURE_BLOCK_TIME_MTP, MAX_TIMESTAMP_HISTORY,
    MEDIAN_TIME_WINDOW,
};
use core::array::ArrayTrait;

/// Computes the Median Time Past (MTP) from the previous timestamps.
pub fn compute_median_time_past(prev_timestamps: Span<u32>) -> u32 {
    let slice = suffix_window(prev_timestamps, prev_timestamps.len());
    median_time(slice)
}

/// Computes the MTP for the block that is `offset` ancestors behind the newest entry.
pub fn median_time_past_at_offset(prev_timestamps: Span<u32>, offset: usize) -> Option<u32> {
    let len = prev_timestamps.len();
    if len == 0 || offset >= len {
        return Option::None;
    }
    let slice = suffix_window(prev_timestamps, len - offset);
    if slice.len() < MEDIAN_TIME_WINDOW {
        let pad_value = *slice[0];
        let missing = MEDIAN_TIME_WINDOW - slice.len();
        let mut padded: Array<u32> = array![];
        let mut idx = 0;
        while idx < missing {
            padded.append(pad_value);
            idx += 1;
        }
        for timestamp in slice {
            padded.append(*timestamp);
        }
        Option::Some(median_time(padded.span()))
    } else {
        Option::Some(median_time(slice))
    }
}

fn suffix_window(history: Span<u32>, end: usize) -> Span<u32> {
    let len = if end > history.len() {
        history.len()
    } else {
        end
    };
    let start = if len > MEDIAN_TIME_WINDOW {
        len - MEDIAN_TIME_WINDOW
    } else {
        0
    };
    history.slice(start, len - start)
}

fn median_time(mut prev_timestamps: Span<u32>) -> u32 {
    // adapted from :
    // https://github.com/keep-starknet-strange/alexandria/blob/main/packages/sorting/src/bubble_sort.cairo
    let mut idx1 = 0;
    let mut idx2 = 1;
    let mut sorted_iteration = true;
    let mut sorted_prev_timestamps: Array<u32> = array![];

    loop {
        if idx2 == prev_timestamps.len() {
            sorted_prev_timestamps.append(*prev_timestamps[idx1]);
            if sorted_iteration {
                break;
            }
            prev_timestamps = sorted_prev_timestamps.span();
            sorted_prev_timestamps = array![];
            idx1 = 0;
            idx2 = 1;
            sorted_iteration = true;
        } else if *prev_timestamps[idx1] <= *prev_timestamps[idx2] {
            sorted_prev_timestamps.append(*prev_timestamps[idx1]);
            idx1 = idx2;
            idx2 += 1;
        } else {
            sorted_prev_timestamps.append(*prev_timestamps[idx2]);
            idx2 += 1;
            sorted_iteration = false;
        }
    }

    (*sorted_prev_timestamps.at(sorted_prev_timestamps.len() / 2))
}

/// Checks that the block time is greater than the Median Time Past (MTP).
pub fn validate_timestamp(median_time_past: u32, block_time: u32) -> Result<(), ByteArray> {
    if block_time > median_time_past {
        Result::Ok(())
    } else {
        Result::Err(format!(
            "block timestamp {} must be greater than median time past {}",
            block_time, median_time_past,
        ))
    }
}

/// Ensures the block time is not excessively ahead of the previous MTP or the local clock.
pub fn validate_future_timestamp(
    prev_mtp: u32, block_time: u32, current_time: u32
) -> Result<(), ByteArray> {
    let block_time_64: u64 = block_time.into();
    let mtp_limit: u64 = prev_mtp.into() + MAX_FUTURE_BLOCK_TIME_MTP.into();
    if block_time_64 > mtp_limit {
        return Result::Err(format!(
            "block timestamp {} exceeds median time past {} plus {} seconds",
            block_time, prev_mtp, MAX_FUTURE_BLOCK_TIME_MTP,
        ));
    }

    let local_limit: u64 = current_time.into() + MAX_FUTURE_BLOCK_TIME_LOCAL.into();
    if block_time_64 > local_limit {
        return Result::Err(format!(
            "block timestamp {} is more than {} seconds ahead of local time {}",
            block_time, MAX_FUTURE_BLOCK_TIME_LOCAL, current_time,
        ));
    }

    Result::Ok(())
}

/// Updates the list of the recent timestamps, removing the oldest and appending the most recent
/// one.
pub fn next_prev_timestamps(prev_timestamps: Span<u32>, block_time: u32) -> Span<u32> {
    let mut timestamps: Array<u32> = prev_timestamps.into();
    if timestamps.len() == MAX_TIMESTAMP_HISTORY {
        timestamps.pop_front().unwrap(); // remove the oldest timestamp (not necessarily the min)
    }
    timestamps.append(block_time); //  append the most recent timestamp (not necessarily the max)

    timestamps.span()
}

#[cfg(test)]
mod tests {
    use super::{
        compute_median_time_past, median_time_past_at_offset, next_prev_timestamps,
        validate_future_timestamp, validate_timestamp,
    };
    use consensus::params::{MAX_FUTURE_BLOCK_TIME_LOCAL, MAX_FUTURE_BLOCK_TIME_MTP};

    #[test]
    fn test_compute_median_time_past() {
        let prev_timestamps = array![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].span();
        let mtp = compute_median_time_past(prev_timestamps);
        assert_eq!(mtp, 6, "Expected MTP to be 6");

        let unsorted_timestamps = array![1, 3, 2, 5, 4, 6, 8, 7, 9, 10, 11].span();
        let mtp = compute_median_time_past(unsorted_timestamps);
        assert_eq!(mtp, 6, "Expected MTP to be 6 for unsorted");
    }

    #[test]
    fn test_validate_timestamp() {
        let mtp = 6_u32;
        let mut block_time = 7_u32;

        // New timestamp is greater than MTP
        let result = validate_timestamp(mtp, block_time);
        assert(result.is_ok(), 'Expected timestamp to be valid');

        // New timestamp is equal to MTP
        block_time = 6;
        let result = validate_timestamp(mtp, block_time);
        assert!(result.is_err(), "MTP is greater than or equal to block's timestamp");

        // New timestamp is less than MTP
        block_time = 5;
        let result = validate_timestamp(mtp, block_time);
        assert!(result.is_err(), "MTP is greater than block's timestamp");
    }

    #[test]
    fn test_validate_future_timestamp_bounds() {
        // Within both limits.
        assert!(
            validate_future_timestamp(1_u32, 10_u32, 20_u32).is_ok(),
            "timestamp should be accepted"
        );

        // Exceeds MTP-based limit.
        let err = validate_future_timestamp(100_u32, 100 + MAX_FUTURE_BLOCK_TIME_MTP + 1, 200_u32);
        assert!(err.is_err(), "expected MTP bound violation");

        // Exceeds local-time limit.
        let err =
            validate_future_timestamp(100_u32, 100 + MAX_FUTURE_BLOCK_TIME_LOCAL + 1, 100_u32);
        assert!(err.is_err(), "expected local time bound violation");
    }

    #[test]
    fn test_next_prev_timestamps() {
        let prev_timestamps = array![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].span();
        let mut block_time = 12_u32;

        let next_prev_timestamps = next_prev_timestamps(prev_timestamps, block_time);
        assert_eq!(next_prev_timestamps.len(), 12);
        assert_eq!(next_prev_timestamps, array![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12].span());
    }

    #[test]
    fn test_validate_timestamp_with_unsorted_input() {
        let prev_timestamps = array![1, 3, 2, 5, 4, 6, 8, 7, 9, 10, 11].span();
        let mtp = compute_median_time_past(prev_timestamps);
        let mut block_time = 12_u32;

        // New timestamp is greater than MTP
        let result = validate_timestamp(mtp, block_time);
        assert(result.is_ok(), 'Expected timestamp to be valid');

        // New timestamp is equal to MTP
        block_time = 6;
        let result = validate_timestamp(mtp, block_time);
        assert!(result.is_err(), "MTP is greater than or equal to block's timestamp");

        // New timestamp is less than MTP
        block_time = 5;
        let result = validate_timestamp(mtp, block_time);
        assert!(result.is_err(), "MTP is greater than block's timestamp");
    }

    #[test]
    fn test_few_prev_timestamps() {
        assert_eq!(1, compute_median_time_past(array![1].span()));
        assert_eq!(2, compute_median_time_past(array![1, 2].span()));
        assert_eq!(2, compute_median_time_past(array![1, 2, 3].span()));
        assert_eq!(3, compute_median_time_past(array![1, 2, 3, 4].span()));
        assert_eq!(3, compute_median_time_past(array![1, 2, 3, 4, 5].span()));
    }

    #[test]
    fn test_median_time_past_at_offset() {
        let history = array![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17].span();
        assert_eq!(Some(12), median_time_past_at_offset(history, 0));
        assert_eq!(Some(6), median_time_past_at_offset(history, 6));
        assert_eq!(None, median_time_past_at_offset(history, 100));
    }
}
