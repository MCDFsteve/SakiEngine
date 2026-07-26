const MAX_HISTORY_SNAPSHOT_BYTES: usize = 16 * 1024 * 1024;

#[flutter_rust_bridge::frb(sync)]
pub fn compress_history_snapshot(data: Vec<u8>) -> Result<Vec<u8>, String> {
    if data.len() > MAX_HISTORY_SNAPSHOT_BYTES {
        return Err(format!(
            "history snapshot exceeds {} bytes",
            MAX_HISTORY_SNAPSHOT_BYTES
        ));
    }
    Ok(lz4_flex::compress_prepend_size(&data))
}

#[flutter_rust_bridge::frb(sync)]
pub fn decompress_history_snapshot(data: Vec<u8>) -> Result<Vec<u8>, String> {
    if data.len() > MAX_HISTORY_SNAPSHOT_BYTES {
        return Err(format!(
            "compressed history snapshot exceeds {} bytes",
            MAX_HISTORY_SNAPSHOT_BYTES
        ));
    }
    let decoded = lz4_flex::decompress_size_prepended(&data)
        .map_err(|error| format!("decompress history snapshot: {error}"))?;
    if decoded.len() > MAX_HISTORY_SNAPSHOT_BYTES {
        return Err(format!(
            "decoded history snapshot exceeds {} bytes",
            MAX_HISTORY_SNAPSHOT_BYTES
        ));
    }
    Ok(decoded)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_snapshot_bytes() {
        let source = b"background=classroom;character=shioke;".repeat(100);
        let compressed = compress_history_snapshot(source.clone()).unwrap();
        assert!(compressed.len() < source.len());
        assert_eq!(decompress_history_snapshot(compressed).unwrap(), source);
    }
}
