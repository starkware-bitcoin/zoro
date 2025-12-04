use zcash_client::ZcashClient;
use zebra_chain::block::Hash;
use hex::FromHex;
#[tokio::main]
async fn main() {
    let client = ZcashClient::new(
        "https://go.getblock.io/5c5842f906c341c5a50cf95b602d0a09".to_string(),
        None,
    )
    .await
    .unwrap();

    // let tx_bytes =
    //     hex::decode("43e966e190f8a63dda0add470e9439b2163f3c89a857488b966d6af2ee716851").unwrap();

    // let tx = client.get_transaction(tx_bytes.as_slice()).await.unwrap();

    // println!("tx: {tx:?}");

    // let hash = tx.hash();
    // println!("hash: {hash}");

    // let hash = client.get_block_hash(3156073).await.unwrap();
    // println!("hash: {hash}");

    // let header = client.get_block_header(&hash).await.unwrap();
    // println!("header: {header:?}");

    // assert_eq!(hash, header.hash());

    // println!("hash: {hash}");
    // let block = hex::decode("0007bc227e1c57a4a70e237cad00e7b7ce565155ab49166bc57397a26d339283").unwrap();
    let header = client.get_block_header(&Hash::from_hex("00040fe8ec8471911baa1db1266ea15dd06b4a8a5c453883c000b031973dce08").unwrap()).await.unwrap();
        
    println!("header: {header:?}");


    println!("got header! hash: {}", header.hash());

    // let height = client.get_block_height(&hash).await.unwrap();

    // println!("height: {height}");

    // let header_by_height = client.get_block_header_by_height(height).await.unwrap();

    // println!("header_by_height: {}", header_by_height.0.hash());

    // let chain_height = client.get_chain_height().await.unwrap();

    // println!("chain_height: {chain_height}");
}
