//! Zcash network upgrade branch IDs and activation heights

pub mod branch_id {
    pub const HEARTWOOD: u32 = 0xf5b9230b;
    pub const CANOPY: u32 = 0xe9ff75a6;
    pub const NU5: u32 = 0xc2d6d0b4;
}

pub mod activation_height {
    pub const HEARTWOOD: u32 = 903_000;
    pub const CANOPY: u32 = 1_046_400;
    pub const NU5: u32 = 1_687_104;
}

pub fn branch_id_for_height(height: u32) -> u32 {
    if height >= activation_height::NU5 {
        branch_id::NU5
    } else if height >= activation_height::CANOPY {
        branch_id::CANOPY
    } else {
        branch_id::HEARTWOOD
    }
}
