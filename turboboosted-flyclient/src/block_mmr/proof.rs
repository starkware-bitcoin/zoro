//! Zcash FlyClient inclusion proof (ZIP-221 compatible)

use serde::{Deserialize, Serialize};
use zcash_history::{NodeData, Version, V1};

/// Zcash FlyClient inclusion proof
#[derive(Debug, Clone)]
pub struct ZcashInclusionProof {
    pub leaf: NodeData,
    pub siblings: Vec<(NodeData, bool)>, // (node, is_sibling_on_left)
    pub peaks: Vec<NodeData>,
    pub peak_index: usize,
}

impl ZcashInclusionProof {
    /// Verify proof against expected root hash
    pub fn verify(&self, expected_root: &[u8; 32]) -> bool {
        let mut current = self.leaf.clone();
        for (sibling, is_left) in &self.siblings {
            current = if *is_left {
                V1::combine(sibling, &current)
            } else {
                V1::combine(&current, sibling)
            };
        }

        let mut all_peaks = Vec::with_capacity(self.peaks.len() + 1);
        for (i, peak) in self.peaks.iter().enumerate() {
            if i == self.peak_index {
                all_peaks.push(current.clone());
            }
            all_peaks.push(peak.clone());
        }
        if self.peak_index >= self.peaks.len() {
            all_peaks.push(current);
        }
        if all_peaks.is_empty() {
            return false;
        }

        let mut iter = all_peaks.into_iter();
        let mut root = iter.next().unwrap();
        for p in iter {
            root = V1::combine(&root, &p);
        }
        V1::hash(&root) == *expected_root
    }

    pub fn block_height(&self) -> u64 {
        self.leaf.end_height
    }

    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(&ProofData::from(self))
    }

    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str::<ProofData>(json)?
            .try_into()
            .map_err(serde::de::Error::custom)
    }
}

// Serialization helper
#[derive(Serialize, Deserialize)]
struct ProofData {
    leaf: String,
    siblings: Vec<(String, bool)>,
    peaks: Vec<String>,
    peak_index: usize,
}

impl From<&ZcashInclusionProof> for ProofData {
    fn from(p: &ZcashInclusionProof) -> Self {
        Self {
            leaf: node_to_hex(&p.leaf),
            siblings: p
                .siblings
                .iter()
                .map(|(n, b)| (node_to_hex(n), *b))
                .collect(),
            peaks: p.peaks.iter().map(node_to_hex).collect(),
            peak_index: p.peak_index,
        }
    }
}

impl TryFrom<ProofData> for ZcashInclusionProof {
    type Error = &'static str;
    fn try_from(d: ProofData) -> Result<Self, Self::Error> {
        Ok(Self {
            leaf: node_from_hex(&d.leaf).ok_or("invalid leaf")?,
            siblings: d
                .siblings
                .into_iter()
                .map(|(s, b)| node_from_hex(&s).map(|n| (n, b)))
                .collect::<Option<_>>()
                .ok_or("invalid sibling")?,
            peaks: d
                .peaks
                .into_iter()
                .map(|s| node_from_hex(&s))
                .collect::<Option<_>>()
                .ok_or("invalid peak")?,
            peak_index: d.peak_index,
        })
    }
}

fn node_to_hex(n: &NodeData) -> String {
    let mut buf = Vec::new();
    buf.extend_from_slice(&n.consensus_branch_id.to_le_bytes());
    n.write(&mut buf).expect("write to vec");
    hex::encode(buf)
}

fn node_from_hex(s: &str) -> Option<NodeData> {
    let b = hex::decode(s).ok()?;
    if b.len() < 4 {
        return None;
    }
    let branch_id = u32::from_le_bytes(b[0..4].try_into().ok()?);
    NodeData::read(branch_id, &mut &b[4..]).ok()
}
