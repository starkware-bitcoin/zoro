//! Proof generation from zcash_history::Tree

use super::ZcashInclusionProof;
use zcash_history::{EntryLink, Tree, V1};

/// Generate an inclusion proof for a block
pub fn generate_proof(
    tree: &Tree<V1>,
    leaf_index: u32,
    leaf_count: u32,
) -> Result<ZcashInclusionProof, String> {
    if leaf_index >= leaf_count {
        return Err("Leaf index out of bounds".into());
    }

    let leaf_pos = leaf_index_to_pos(leaf_index);
    let tree_size = leaf_count_to_mmr_size(leaf_count);

    let leaf = tree
        .resolve_link(EntryLink::Stored(leaf_pos))
        .map_err(|e| format!("Failed to get leaf: {e:?}"))?
        .data()
        .clone();

    let mut siblings = Vec::new();
    let mut pos = leaf_pos;

    loop {
        let height = pos_height(pos);
        let sib_offset = sibling_offset(height);

        // Try right sibling
        let right_sib = pos + sib_offset;
        if right_sib < tree_size && pos_height(right_sib) == height {
            let sibling = tree
                .resolve_link(EntryLink::Stored(right_sib))
                .map_err(|e| format!("Failed to get sibling: {e:?}"))?
                .data()
                .clone();
            siblings.push((sibling, false));
            pos = right_sib + 1;
            continue;
        }

        // Try left sibling
        if pos >= sib_offset {
            let left_sib = pos - sib_offset;
            if pos_height(left_sib) == height {
                let sibling = tree
                    .resolve_link(EntryLink::Stored(left_sib))
                    .map_err(|e| format!("Failed to get sibling: {e:?}"))?
                    .data()
                    .clone();
                siblings.push((sibling, true));
                pos += 1;
                continue;
            }
        }
        break;
    }

    let peak_positions = get_peaks(tree_size);
    let mut peaks = Vec::new();
    let mut peak_index = 0;

    for (i, &peak_pos) in peak_positions.iter().enumerate() {
        if peak_pos == pos {
            peak_index = i;
        } else {
            let peak = tree
                .resolve_link(EntryLink::Stored(peak_pos))
                .map_err(|e| format!("Failed to get peak: {e:?}"))?
                .data()
                .clone();
            peaks.push(peak);
        }
    }

    Ok(ZcashInclusionProof {
        leaf,
        siblings,
        peaks,
        peak_index,
    })
}

// MMR position math
fn leaf_index_to_pos(idx: u32) -> u32 {
    // Find the nth position with height 0 (leaf positions: 0, 1, 3, 4, 7, 8, 10, ...)
    (0u32..)
        .filter(|&p| pos_height(p) == 0)
        .nth(idx as usize)
        .unwrap()
}

fn pos_height(mut pos: u32) -> u32 {
    loop {
        let n = pos + 1;
        if (n & (n + 1)) == 0 {
            return n.count_ones() - 1;
        }
        let k = 32 - n.leading_zeros();
        let left_size = (1u32 << (k - 1)) - 1;
        pos -= left_size;
    }
}

fn sibling_offset(height: u32) -> u32 {
    (2u32 << height) - 1
}

fn leaf_count_to_mmr_size(n: u32) -> u32 {
    if n == 0 {
        0
    } else {
        2 * n - n.count_ones()
    }
}

fn get_peaks(tree_size: u32) -> Vec<u32> {
    if tree_size == 0 {
        return vec![];
    }
    let mut peaks = Vec::new();
    let mut pos = 0;
    let mut remaining = tree_size;
    while remaining > 0 {
        let mut size = 1u32;
        while size * 2 - 1 <= remaining {
            size *= 2;
        }
        let subtree_size = size - 1;
        if subtree_size > 0 {
            peaks.push(pos + subtree_size - 1);
            pos += subtree_size;
            remaining -= subtree_size;
        } else {
            break;
        }
    }
    peaks
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pos_height() {
        assert_eq!(pos_height(0), 0);
        assert_eq!(pos_height(1), 0);
        assert_eq!(pos_height(2), 1);
        assert_eq!(pos_height(3), 0);
        assert_eq!(pos_height(6), 2);
    }

    #[test]
    fn test_leaf_positions() {
        assert_eq!(leaf_index_to_pos(0), 0);
        assert_eq!(leaf_index_to_pos(1), 1);
        assert_eq!(leaf_index_to_pos(2), 3);
        assert_eq!(leaf_index_to_pos(3), 4);
    }

    #[test]
    fn test_peaks() {
        assert_eq!(get_peaks(11), vec![6, 9, 10]);
        assert_eq!(get_peaks(7), vec![6]);
    }

    #[test]
    fn test_mmr_size() {
        assert_eq!(leaf_count_to_mmr_size(1), 1);
        assert_eq!(leaf_count_to_mmr_size(4), 7);
        assert_eq!(leaf_count_to_mmr_size(7), 11);
    }
}
