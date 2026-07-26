use std::collections::{BTreeSet, HashMap};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

const LEGACY_MAGIC: &[u8; 4] = b"SAKI";
const LOG_MAGIC: &[u8; 4] = b"SAKR";
const LEGACY_VERSION: i32 = 1;
const LOG_VERSION: i32 = 2;
const LOG_HEADER_BYTES: u64 = 8;
const RECORD_BYTES: usize = 9;
const RECORD_LEGACY: u8 = 0;
const RECORD_STABLE: u8 = 1;

#[derive(Clone, Debug)]
pub struct RustReadStateSnapshot {
    pub handle: u64,
    pub stable_hashes: Vec<i64>,
    pub legacy_hashes: Vec<i32>,
    pub migrated_legacy_file: bool,
}

struct ReadState {
    path: PathBuf,
    file: Option<File>,
    stable: BTreeSet<i64>,
    legacy: BTreeSet<i32>,
}

static STATES: OnceLock<Mutex<HashMap<u64, ReadState>>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

fn states() -> &'static Mutex<HashMap<u64, ReadState>> {
    STATES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn read_i32(bytes: &[u8], offset: usize) -> Result<i32, String> {
    let chunk = bytes
        .get(offset..offset + 4)
        .ok_or_else(|| "truncated i32".to_string())?;
    Ok(i32::from_le_bytes(chunk.try_into().unwrap()))
}

fn parse_existing(path: &Path) -> Result<(BTreeSet<i64>, BTreeSet<i32>, bool), String> {
    if !path.exists() {
        return Ok((BTreeSet::new(), BTreeSet::new(), false));
    }
    let bytes = fs::read(path)
        .map_err(|error| format!("read read-state file {}: {error}", path.display()))?;
    if bytes.is_empty() {
        return Ok((BTreeSet::new(), BTreeSet::new(), false));
    }
    if bytes.len() < 8 {
        return Err("read-state file is truncated".to_string());
    }
    let version = read_i32(&bytes, 4)?;
    if bytes.get(0..4) == Some(LEGACY_MAGIC) && version == LEGACY_VERSION {
        if bytes.len() < 12 {
            return Err("legacy read-state header is truncated".to_string());
        }
        let count = read_i32(&bytes, 8)?;
        if count < 0 {
            return Err("legacy read-state count is negative".to_string());
        }
        let expected = 12_usize
            .checked_add(count as usize * 4)
            .ok_or_else(|| "legacy read-state size overflow".to_string())?;
        if bytes.len() < expected {
            return Err("legacy read-state records are truncated".to_string());
        }
        let mut legacy = BTreeSet::new();
        for index in 0..count as usize {
            legacy.insert(read_i32(&bytes, 12 + index * 4)?);
        }
        return Ok((BTreeSet::new(), legacy, true));
    }
    if bytes.get(0..4) != Some(LOG_MAGIC) || version != LOG_VERSION {
        return Err("unknown read-state format".to_string());
    }
    let payload = &bytes[LOG_HEADER_BYTES as usize..];
    let complete_length = payload.len() - (payload.len() % RECORD_BYTES);
    let mut stable = BTreeSet::new();
    let mut legacy = BTreeSet::new();
    for record in payload[..complete_length].chunks_exact(RECORD_BYTES) {
        match record[0] {
            RECORD_LEGACY => {
                legacy.insert(i64::from_le_bytes(record[1..9].try_into().unwrap()) as i32);
            }
            RECORD_STABLE => {
                stable.insert(i64::from_le_bytes(record[1..9].try_into().unwrap()));
            }
            _ => {}
        }
    }
    Ok((stable, legacy, false))
}

fn write_snapshot(
    path: &Path,
    stable: &BTreeSet<i64>,
    legacy: &BTreeSet<i32>,
) -> Result<File, String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!("create read-state directory {}: {error}", parent.display())
        })?;
    }
    let temporary = path.with_extension(format!("sakiread.tmp.{}", std::process::id()));
    {
        let mut output = File::create(&temporary)
            .map_err(|error| format!("create read-state temp file: {error}"))?;
        output
            .write_all(LOG_MAGIC)
            .and_then(|_| output.write_all(&LOG_VERSION.to_le_bytes()))
            .map_err(|error| format!("write read-state header: {error}"))?;
        for value in legacy {
            output
                .write_all(&[RECORD_LEGACY])
                .and_then(|_| output.write_all(&(*value as i64).to_le_bytes()))
                .map_err(|error| format!("write legacy read-state record: {error}"))?;
        }
        for value in stable {
            output
                .write_all(&[RECORD_STABLE])
                .and_then(|_| output.write_all(&value.to_le_bytes()))
                .map_err(|error| format!("write stable read-state record: {error}"))?;
        }
        output
            .sync_all()
            .map_err(|error| format!("flush read-state file: {error}"))?;
    }
    if let Err(first_error) = fs::rename(&temporary, path) {
        if !path.exists() {
            return Err(format!("commit read-state file: {first_error}"));
        }
        fs::remove_file(path).map_err(|error| format!("replace read-state file: {error}"))?;
        fs::rename(&temporary, path).map_err(|error| format!("commit read-state file: {error}"))?;
    }
    OpenOptions::new()
        .read(true)
        .append(true)
        .open(path)
        .map_err(|error| format!("reopen read-state file: {error}"))
}

pub fn read_state_open(path: String) -> Result<RustReadStateSnapshot, String> {
    let path = PathBuf::from(path);
    let (stable, legacy, migrated) = parse_existing(&path)?;
    let file = write_snapshot(&path, &stable, &legacy)?;
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    let snapshot = RustReadStateSnapshot {
        handle,
        stable_hashes: stable.iter().copied().collect(),
        legacy_hashes: legacy.iter().copied().collect(),
        migrated_legacy_file: migrated,
    };
    states()
        .lock()
        .map_err(|_| "read-state handle store is poisoned".to_string())?
        .insert(
            handle,
            ReadState {
                path,
                file: Some(file),
                stable,
                // Legacy hashes are returned to Dart for compatibility checks.
                // The append-only store no longer needs a second in-Rust copy.
                legacy: BTreeSet::new(),
            },
        );
    Ok(snapshot)
}

pub fn read_state_mark(handle: u64, stable_hash: i64) -> Result<bool, String> {
    let mut store = states()
        .lock()
        .map_err(|_| "read-state handle store is poisoned".to_string())?;
    let state = store
        .get_mut(&handle)
        .ok_or_else(|| format!("unknown read-state handle: {handle}"))?;
    if !state.stable.insert(stable_hash) {
        return Ok(false);
    }
    let file = state
        .file
        .as_mut()
        .ok_or_else(|| "read-state log is closed".to_string())?;
    file.write_all(&[RECORD_STABLE])
        .and_then(|_| file.write_all(&stable_hash.to_le_bytes()))
        .map_err(|error| format!("append read-state record: {error}"))?;
    Ok(true)
}

pub fn read_state_flush(handle: u64) -> Result<bool, String> {
    let mut store = states()
        .lock()
        .map_err(|_| "read-state handle store is poisoned".to_string())?;
    let state = store
        .get_mut(&handle)
        .ok_or_else(|| format!("unknown read-state handle: {handle}"))?;
    state
        .file
        .as_mut()
        .ok_or_else(|| "read-state log is closed".to_string())?
        .sync_data()
        .map_err(|error| format!("flush read-state log: {error}"))?;
    Ok(true)
}

pub fn read_state_replace(
    handle: u64,
    stable_hashes: Vec<i64>,
    legacy_hashes: Vec<i32>,
) -> Result<bool, String> {
    let mut store = states()
        .lock()
        .map_err(|_| "read-state handle store is poisoned".to_string())?;
    let state = store
        .get_mut(&handle)
        .ok_or_else(|| format!("unknown read-state handle: {handle}"))?;
    if let Some(file) = state.file.take() {
        file.sync_data()
            .map_err(|error| format!("flush read-state log: {error}"))?;
        drop(file);
    }
    state.stable = stable_hashes.into_iter().collect();
    state.legacy = legacy_hashes.into_iter().collect();
    state.file = Some(write_snapshot(&state.path, &state.stable, &state.legacy)?);
    Ok(true)
}

pub fn read_state_clear(handle: u64) -> Result<bool, String> {
    read_state_replace(handle, Vec::new(), Vec::new())
}

pub fn read_state_close(handle: u64) -> Result<bool, String> {
    let mut state = states()
        .lock()
        .map_err(|_| "read-state handle store is poisoned".to_string())?
        .remove(&handle);
    if let Some(state) = state.as_mut() {
        if let Some(file) = state.file.take() {
            file.sync_data()
                .map_err(|error| format!("flush read-state log: {error}"))?;
        }
        return Ok(true);
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_legacy_records() {
        let path = std::env::temp_dir().join(format!(
            "saki_read_state_{}_{}.sakiread",
            std::process::id(),
            99
        ));
        let mut bytes = Vec::new();
        bytes.extend_from_slice(LEGACY_MAGIC);
        bytes.extend_from_slice(&LEGACY_VERSION.to_le_bytes());
        bytes.extend_from_slice(&2_i32.to_le_bytes());
        bytes.extend_from_slice(&123_i32.to_le_bytes());
        bytes.extend_from_slice(&(-456_i32).to_le_bytes());
        fs::write(&path, bytes).unwrap();
        let (_, legacy, migrated) = parse_existing(&path).unwrap();
        assert!(migrated);
        assert_eq!(legacy.len(), 2);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn appends_flushes_and_clears_log() {
        let path = std::env::temp_dir().join(format!(
            "saki_read_state_lifecycle_{}.sakiread",
            std::process::id()
        ));
        let snapshot = read_state_open(path.to_string_lossy().to_string()).unwrap();
        assert!(read_state_mark(snapshot.handle, 987_654_321).unwrap());
        assert!(read_state_flush(snapshot.handle).unwrap());
        assert!(read_state_clear(snapshot.handle).unwrap());
        assert!(read_state_close(snapshot.handle).unwrap());
        let (stable, legacy, _) = parse_existing(&path).unwrap();
        assert!(stable.is_empty());
        assert!(legacy.is_empty());
        let _ = fs::remove_file(path);
    }
}
