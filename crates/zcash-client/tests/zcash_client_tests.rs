use zcash_client::ZcashClient;
use zebra_chain::transaction::Hash;
use hex::FromHex;
#[tokio::test]
async fn zcash_client_main_flow_like_example() {
    // Same parameters as `crates/raito-bitcoin-client/src/main.rs`
    let client = ZcashClient::new(
        "https://go.getblock.io/5c5842f906c341c5a50cf95b602d0a09".to_string(),
        None,
    )
    .await
    .expect("failed to create ZcashClient");

    let height: u32 = 3_156_073;

    // getblockhash
    let hash = client
        .get_block_hash(height)
        .await
        .expect("get_block_hash failed");

    // getblockheader (hash only)
    let header = client
        .get_block_header(&hash)
        .await
        .expect("get_block_header failed");

    // getblockheader (hash + verbose=true -> height)
    let returned_height = client
        .get_block_height(&hash)
        .await
        .expect("get_block_height failed");
    assert_eq!(returned_height, height, "height round-trip must match");

    // getblockhash + getblockheader by height
    let (header_by_height, hash_by_height) = client
        .get_block_header_by_height(height)
        .await
        .expect("get_block_header_by_height failed");

    // The header and hash obtained by height should match those obtained by hash
    assert_eq!(
        header_by_height.hash(),
        header.hash(),
        "header hash from height and direct hash must match"
    );
    assert_eq!(
        hash_by_height, hash,
        "block hash from height and direct hash must match"
    );

    // getblockcount
    let chain_height = client
        .get_chain_height()
        .await
        .expect("get_chain_height failed");
    assert!(
        chain_height >= height,
        "chain height {chain_height} should be at least {height}"
    );
}

#[tokio::test]
async fn zcash_client_get_transaction_test() {
    // these should contain all the different tx versions
    let txids_hex = [
        "55ab20ae2d528fd612ed55b419950ebac20f4c59ea841b7fe5db97f9c3e7e206",
        "a6cabf193af5066654d9929e54ea6bc1f794c5d07d7247a3893eeef4e5bfe17f",
        "b2aa4c149a451d75fff16d0b97291dab06cb2788ebc44be3cfeb61b847446c2b",
        "c61e5ce69c9892ee36602d6d31458f381750d52983fc471f874f95f57d9afeab",
        "84832e66f3261737b84da806f62bc07dce03e3002bef412766faa3d123f066e1",
        "ac694dd10970909bf1bfc6bd71f5e6c924b174a5ddf6529f5ba3b8e721724f9c",
        "381b65eb3fa04c1c78e73d4488b7e0b02f0469e5bd8e222f84c7896410e966dd",
        "0a5803ee986c48fb9b8c8d949ee6b4e8f48c2d81a94fb36bbf168d66753a0d41"
    ];

    let client = ZcashClient::new(
        "https://go.getblock.io/5c5842f906c341c5a50cf95b602d0a09".to_string(),
        None,
    )
    .await
    .expect("failed to create ZcashClient");

    for txid_hex in txids_hex {
        let transaction = client
            .get_transaction(&Hash::from_hex(&txid_hex).expect("Invalid txid hex"))
            .await
            .expect("get_transaction failed");

        let expected_txid = transaction.hash().0;
        assert_eq!(expected_txid, Hash::from_hex(&txid_hex).expect("Invalid txid hex").0);
    }
}
