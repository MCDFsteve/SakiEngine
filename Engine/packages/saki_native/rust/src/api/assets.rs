use memmap2::{Mmap, MmapOptions};
use serde::Deserialize;
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::UNIX_EPOCH;

const PACK_MAGIC: u32 = 0x5341_4b49;
const PACK_VERSION: u32 = 1;
const PACK_HEADER_BYTES: usize = 20;
const MAX_PACK_INDEX_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct RustAssetEntry {
    pub relative_path: String,
    pub absolute_path: String,
    pub file_name: String,
    pub stem: String,
    pub extension: String,
    pub size: u64,
    pub modified_millis: i64,
}

#[derive(Clone, Debug)]
pub struct RustAssetCatalog {
    pub root_path: String,
    pub entries: Vec<RustAssetEntry>,
    pub elapsed_micros: u64,
}

#[derive(Clone, Debug)]
pub struct RustPackEntry {
    pub path: String,
    pub offset: u64,
    pub length: u64,
    pub text: bool,
    pub sha256: Option<String>,
}

#[derive(Clone, Debug)]
pub struct RustPackCatalog {
    pub handle: u64,
    pub path: String,
    pub entries: Vec<RustPackEntry>,
}

#[derive(Deserialize)]
struct PackIndex {
    entries: Vec<PackIndexEntry>,
}

#[derive(Clone, Deserialize)]
struct PackIndexEntry {
    path: String,
    offset: u64,
    length: u64,
    #[serde(default)]
    text: bool,
    #[serde(default)]
    sha256: Option<String>,
}

struct OpenPack {
    mmap: Mmap,
    file_len: u64,
    entries: HashMap<String, PackIndexEntry>,
}

static PACKS: OnceLock<Mutex<HashMap<u64, OpenPack>>> = OnceLock::new();
static NEXT_PACK_HANDLE: AtomicU64 = AtomicU64::new(1);

fn packs() -> &'static Mutex<HashMap<u64, OpenPack>> {
    PACKS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn normalize_slashes(value: &str) -> String {
    value.replace('\\', "/").trim_start_matches('/').to_string()
}

fn visit_directory(
    root: &Path,
    directory: &Path,
    entries: &mut Vec<RustAssetEntry>,
) -> Result<(), String> {
    let children = fs::read_dir(directory)
        .map_err(|error| format!("read directory {}: {error}", directory.display()))?;
    for child in children {
        let child = child.map_err(|error| format!("read directory entry: {error}"))?;
        let path = child.path();
        let file_type = child
            .file_type()
            .map_err(|error| format!("read file type {}: {error}", path.display()))?;
        if file_type.is_symlink() {
            continue;
        }
        let metadata = child
            .metadata()
            .map_err(|error| format!("read metadata {}: {error}", path.display()))?;
        if metadata.is_dir() {
            visit_directory(root, &path, entries)?;
            continue;
        }
        if !metadata.is_file() {
            continue;
        }
        let relative = path.strip_prefix(root).unwrap_or(&path);
        let file_name = path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_string();
        let stem = path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_string();
        let extension = path
            .extension()
            .and_then(|value| value.to_str())
            .map(|value| format!(".{}", value.to_lowercase()))
            .unwrap_or_default();
        let modified_millis = metadata
            .modified()
            .ok()
            .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
            .map(|value| value.as_millis().min(i64::MAX as u128) as i64)
            .unwrap_or(0);
        entries.push(RustAssetEntry {
            relative_path: normalize_slashes(&relative.to_string_lossy()),
            absolute_path: path.to_string_lossy().to_string(),
            file_name,
            stem,
            extension,
            size: metadata.len(),
            modified_millis,
        });
    }
    Ok(())
}

pub fn scan_assets(root_path: String) -> Result<RustAssetCatalog, String> {
    let started = std::time::Instant::now();
    let root = fs::canonicalize(&root_path)
        .map_err(|error| format!("resolve asset root {root_path}: {error}"))?;
    if !root.is_dir() {
        return Err(format!("asset root is not a directory: {}", root.display()));
    }
    let mut entries = Vec::new();
    let mut game_asset_roots = Vec::new();
    for child in fs::read_dir(&root)
        .map_err(|error| format!("read asset root {}: {error}", root.display()))?
    {
        let child = child.map_err(|error| format!("read asset root entry: {error}"))?;
        let file_type = child
            .file_type()
            .map_err(|error| format!("read asset root entry type: {error}"))?;
        if !file_type.is_dir() {
            continue;
        }
        let name = child.file_name().to_string_lossy().to_string();
        if name == "Assets" || name == "GameScript" || name.starts_with("GameScript_") {
            game_asset_roots.push(child.path());
        }
    }
    if game_asset_roots.is_empty() {
        visit_directory(&root, &root, &mut entries)?;
    } else {
        game_asset_roots.sort_unstable();
        for asset_root in game_asset_roots {
            visit_directory(&root, &asset_root, &mut entries)?;
        }
    }
    entries.sort_unstable_by(|left, right| left.relative_path.cmp(&right.relative_path));
    Ok(RustAssetCatalog {
        root_path: root.to_string_lossy().to_string(),
        entries,
        elapsed_micros: started.elapsed().as_micros().min(u64::MAX as u128) as u64,
    })
}

pub fn open_saki_pack(path: String) -> Result<RustPackCatalog, String> {
    let mut file = OpenOptions::new()
        .read(true)
        .open(&path)
        .map_err(|error| format!("open SakiPack {path}: {error}"))?;
    let file_len = file
        .metadata()
        .map_err(|error| format!("read SakiPack metadata: {error}"))?
        .len();
    if file_len < PACK_HEADER_BYTES as u64 {
        return Err("SakiPack header is truncated".to_string());
    }

    let mut header = [0_u8; PACK_HEADER_BYTES];
    file.read_exact(&mut header)
        .map_err(|error| format!("read SakiPack header: {error}"))?;
    let magic = u32::from_be_bytes(header[0..4].try_into().unwrap());
    let version = u32::from_be_bytes(header[4..8].try_into().unwrap());
    let index_offset = u64::from_be_bytes(header[8..16].try_into().unwrap());
    let index_length = u32::from_be_bytes(header[16..20].try_into().unwrap()) as usize;
    if magic != PACK_MAGIC {
        return Err(format!("invalid SakiPack magic: {magic:#x}"));
    }
    if version != PACK_VERSION {
        return Err(format!("unsupported SakiPack version: {version}"));
    }
    if index_length == 0 || index_length > MAX_PACK_INDEX_BYTES {
        return Err(format!("invalid SakiPack index length: {index_length}"));
    }
    let index_end = index_offset
        .checked_add(index_length as u64)
        .ok_or_else(|| "SakiPack index offset overflow".to_string())?;
    if index_end > file_len {
        return Err("SakiPack index exceeds file length".to_string());
    }

    file.seek(SeekFrom::Start(index_offset))
        .map_err(|error| format!("seek SakiPack index: {error}"))?;
    let mut index_bytes = vec![0_u8; index_length];
    file.read_exact(&mut index_bytes)
        .map_err(|error| format!("read SakiPack index: {error}"))?;
    let index: PackIndex = serde_json::from_slice(&index_bytes)
        .map_err(|error| format!("parse SakiPack index: {error}"))?;

    let mut by_path = HashMap::with_capacity(index.entries.len());
    let mut public_entries = Vec::with_capacity(index.entries.len());
    for mut entry in index.entries {
        entry.path = normalize_slashes(&entry.path);
        let end = entry
            .offset
            .checked_add(entry.length)
            .ok_or_else(|| format!("SakiPack entry overflow: {}", entry.path))?;
        if end > file_len || end > index_offset {
            return Err(format!("SakiPack entry out of bounds: {}", entry.path));
        }
        public_entries.push(RustPackEntry {
            path: entry.path.clone(),
            offset: entry.offset,
            length: entry.length,
            text: entry.text,
            sha256: entry.sha256.clone(),
        });
        by_path.insert(entry.path.clone(), entry);
    }
    public_entries.sort_unstable_by(|left, right| left.path.cmp(&right.path));

    let handle = NEXT_PACK_HANDLE.fetch_add(1, Ordering::Relaxed);
    // The pack file is immutable while open. Mapping it lets the operating
    // system page only the ranges that are actually read and avoids a second
    // native heap buffer when materializing large media.
    let mmap = unsafe { MmapOptions::new().map(&file) }
        .map_err(|error| format!("memory-map SakiPack {path}: {error}"))?;

    packs()
        .lock()
        .map_err(|_| "SakiPack handle store is poisoned".to_string())?
        .insert(
            handle,
            OpenPack {
                mmap,
                file_len,
                entries: by_path,
            },
        );
    Ok(RustPackCatalog {
        handle,
        path,
        entries: public_entries,
    })
}

pub fn read_saki_pack_entry(handle: u64, path: String) -> Result<Vec<u8>, String> {
    let normalized = normalize_slashes(&path);
    let store = packs()
        .lock()
        .map_err(|_| "SakiPack handle store is poisoned".to_string())?;
    let pack = store
        .get(&handle)
        .ok_or_else(|| format!("unknown SakiPack handle: {handle}"))?;
    let entry = pack
        .entries
        .get(&normalized)
        .ok_or_else(|| format!("SakiPack entry not found: {normalized}"))?
        .clone();
    let end = entry
        .offset
        .checked_add(entry.length)
        .ok_or_else(|| "SakiPack entry offset overflow".to_string())?;
    if end > pack.file_len || entry.length > usize::MAX as u64 {
        return Err(format!("SakiPack entry is invalid: {normalized}"));
    }
    Ok(pack.mmap[entry.offset as usize..end as usize].to_vec())
}

pub fn materialize_saki_pack_entry(
    handle: u64,
    path: String,
    output_path: String,
) -> Result<bool, String> {
    let normalized = normalize_slashes(&path);
    let output = PathBuf::from(&output_path);
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            format!("create materialize directory {}: {error}", parent.display())
        })?;
    }
    let temporary = output.with_extension(format!(
        "{}.tmp.{}",
        output
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default(),
        std::process::id()
    ));
    {
        let store = packs()
            .lock()
            .map_err(|_| "SakiPack handle store is poisoned".to_string())?;
        let pack = store
            .get(&handle)
            .ok_or_else(|| format!("unknown SakiPack handle: {handle}"))?;
        let entry = pack
            .entries
            .get(&normalized)
            .ok_or_else(|| format!("SakiPack entry not found: {normalized}"))?;
        let end = entry
            .offset
            .checked_add(entry.length)
            .ok_or_else(|| "SakiPack entry offset overflow".to_string())?;
        if end > pack.file_len || entry.length > usize::MAX as u64 {
            return Err(format!("SakiPack entry is invalid: {normalized}"));
        }
        let mut file = File::create(&temporary).map_err(|error| {
            format!("create materialized asset {}: {error}", temporary.display())
        })?;
        file.write_all(&pack.mmap[entry.offset as usize..end as usize])
            .map_err(|error| format!("write materialized asset: {error}"))?;
        file.sync_all()
            .map_err(|error| format!("flush materialized asset: {error}"))?;
    }
    if output.exists() {
        fs::remove_file(&output)
            .map_err(|error| format!("replace materialized asset {}: {error}", output.display()))?;
    }
    fs::rename(&temporary, &output)
        .map_err(|error| format!("commit materialized asset {}: {error}", output.display()))?;
    Ok(true)
}

pub fn close_saki_pack(handle: u64) -> Result<bool, String> {
    Ok(packs()
        .lock()
        .map_err(|_| "SakiPack handle store is poisoned".to_string())?
        .remove(&handle)
        .is_some())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_windows_and_absolute_paths() {
        assert_eq!(
            normalize_slashes(r"\Assets\images\a.png"),
            "Assets/images/a.png"
        );
    }

    #[test]
    fn opens_external_pack_when_configured() {
        let Ok(path) = std::env::var("SAKI_TEST_PACK") else {
            return;
        };
        let catalog = open_saki_pack(path).unwrap();
        assert!(!catalog.entries.is_empty());
        let first = catalog.entries.first().unwrap();
        let bytes = read_saki_pack_entry(catalog.handle, first.path.clone()).unwrap();
        assert_eq!(bytes.len() as u64, first.length);
        close_saki_pack(catalog.handle).unwrap();
    }
}
