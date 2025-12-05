use serde::de::Error as SerdeError;
use serde::{Deserialize, Deserializer, Serializer};
use zebra_chain::block::Header;
use zebra_chain::serialization::ZcashDeserialize;
use zebra_chain::serialization::ZcashSerialize;
use zebra_chain::transaction::Transaction;

pub fn serialize_transaction<S>(tx: &Transaction, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    let mut buffer = Vec::new();
    tx.zcash_serialize(&mut buffer)
        .map_err(serde::ser::Error::custom)?;
    let hex_string = hex::encode(buffer);
    serializer.serialize_str(&hex_string)
}

pub fn deserialize_transaction<'de, D>(deserializer: D) -> Result<Transaction, D::Error>
where
    D: Deserializer<'de>,
{
    let hex_string = String::deserialize(deserializer)?;
    let bytes = hex::decode(&hex_string).map_err(SerdeError::custom)?;
    let mut reader = bytes.as_slice();
    Transaction::zcash_deserialize(&mut reader).map_err(SerdeError::custom)
}

pub fn serialize_header<S>(header: &Header, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    let mut buffer = Vec::new();
    header
        .zcash_serialize(&mut buffer)
        .map_err(serde::ser::Error::custom)?;
    let hex_string = hex::encode(buffer);
    serializer.serialize_str(&hex_string)
}

pub fn deserialize_header<'de, D>(deserializer: D) -> Result<Header, D::Error>
where
    D: Deserializer<'de>,
{
    let hex_string = String::deserialize(deserializer)?;
    let bytes = hex::decode(&hex_string).map_err(SerdeError::custom)?;
    let mut reader = bytes.as_slice();
    Header::zcash_deserialize(&mut reader).map_err(SerdeError::custom)
}
