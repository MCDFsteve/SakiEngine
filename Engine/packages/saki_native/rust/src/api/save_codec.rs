use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufReader, Cursor, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::UNIX_EPOCH;

const MAGIC: &[u8; 4] = b"SAKI";
const MAX_VERSION: i32 = 16;
const MAX_FIELD_BYTES: usize = 64 * 1024 * 1024;
const MAX_COLLECTION: usize = 100_000;
const MAX_SNAPSHOT_DEPTH: usize = 256;
static NEXT_TEMP_FILE: AtomicU64 = AtomicU64::new(1);
const SAVE_HEADER_INDEX_FILE: &str = ".saki_save_headers_v1.json";
const SAVE_HEADER_INDEX_VERSION: u32 = 1;
const MAX_HEADER_SCAN_WORKERS: usize = 16;

#[derive(Clone, Debug)]
pub struct RustSaveMetadata {
    pub version: i32,
    pub id: i64,
    pub save_time_millis: i64,
    pub current_script: String,
    pub dialogue_preview: String,
    pub screenshot_offset: Option<u64>,
    pub screenshot_length: Option<u64>,
    pub is_locked: bool,
    pub script_index: i32,
}

#[derive(Clone, Debug)]
pub struct RustDecodedSave {
    pub metadata: RustSaveMetadata,
    pub data: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RustSaveHeader {
    pub id: i64,
    pub version: i32,
    pub save_time_millis: i64,
    pub current_script: String,
    pub dialogue_preview: String,
    pub file_path: String,
    pub screenshot_offset: Option<i64>,
    pub screenshot_length: Option<i64>,
    pub is_locked: bool,
    pub script_index: i32,
    pub preview_kind: String,
    pub preview_speaker: Option<String>,
    pub preview_text: Option<String>,
    pub preview_choices: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct RustSaveHeaderScan {
    pub slots: Vec<RustSaveHeader>,
    pub invalid_files: Vec<String>,
    pub elapsed_micros: u64,
}

#[derive(Deserialize, Serialize)]
struct CachedSaveHeaderIndex {
    version: u32,
    entries: Vec<CachedSaveHeaderEntry>,
}

#[derive(Deserialize, Serialize)]
struct CachedSaveHeaderEntry {
    file_name: String,
    file_length: u64,
    modified_nanos: u64,
    header: RustSaveHeader,
}

struct SaveHeaderPath {
    path: PathBuf,
    file_name: String,
    file_length: u64,
    modified_nanos: u64,
}

struct SavePreview {
    kind: &'static str,
    speaker: Option<String>,
    text: Option<String>,
    choices: Vec<String>,
}

/// Streaming reader used by the save-list index.
///
/// The full save decoder intentionally keeps using `Reader` below because a
/// selected slot must be returned to Dart in full. The list screen only needs
/// the fixed header and the current `GameState` preview, so reading every PNG
/// screenshot and every historical snapshot was unnecessary I/O and memory.
struct HeaderReader<R> {
    reader: R,
    file_length: u64,
}

impl<R: Read + Seek> HeaderReader<R> {
    fn new(reader: R, file_length: u64) -> Self {
        Self {
            reader,
            file_length,
        }
    }

    fn exact(&mut self, buffer: &mut [u8]) -> Result<(), String> {
        self.reader
            .read_exact(buffer)
            .map_err(|error| format!("truncated save data: {error}"))
    }

    fn u8(&mut self) -> Result<u8, String> {
        let mut value = [0_u8; 1];
        self.exact(&mut value)?;
        Ok(value[0])
    }

    fn i32(&mut self) -> Result<i32, String> {
        let mut value = [0_u8; 4];
        self.exact(&mut value)?;
        Ok(i32::from_le_bytes(value))
    }

    fn i64(&mut self) -> Result<i64, String> {
        let mut value = [0_u8; 8];
        self.exact(&mut value)?;
        Ok(i64::from_le_bytes(value))
    }

    fn length(&mut self, nullable: bool) -> Result<Option<usize>, String> {
        let length = self.i32()?;
        if nullable && length == -1 {
            return Ok(None);
        }
        if length < 0 {
            return Err(format!("invalid negative save field length: {length}"));
        }
        let length = length as usize;
        if length > MAX_FIELD_BYTES {
            return Err(format!("save field is too large: {length} bytes"));
        }
        Ok(Some(length))
    }

    fn string(&mut self) -> Result<String, String> {
        let length = self.length(false)?.unwrap();
        self.utf8(length)
    }

    fn nullable_string(&mut self) -> Result<Option<String>, String> {
        self.length(true)?
            .map(|length| self.utf8(length))
            .transpose()
    }

    fn utf8(&mut self, length: usize) -> Result<String, String> {
        let mut bytes = vec![0_u8; length];
        self.exact(&mut bytes)?;
        String::from_utf8(bytes).map_err(|error| format!("save string is not UTF-8: {error}"))
    }

    fn skip(&mut self, length: u64) -> Result<(), String> {
        let position = self
            .reader
            .stream_position()
            .map_err(|error| format!("query save position: {error}"))?;
        if position.saturating_add(length) > self.file_length {
            return Err("save field extends beyond file length".to_string());
        }
        let delta =
            i64::try_from(length).map_err(|_| "save field is too large to seek".to_string())?;
        self.reader
            .seek(SeekFrom::Current(delta))
            .map_err(|error| format!("skip save field: {error}"))?;
        Ok(())
    }

    fn skip_string(&mut self) -> Result<(), String> {
        let length = self.length(false)?.unwrap();
        self.skip(length as u64)
    }

    fn skip_nullable_string(&mut self) -> Result<(), String> {
        if let Some(length) = self.length(true)? {
            self.skip(length as u64)?;
        }
        Ok(())
    }

    fn skip_nullable_bytes(&mut self) -> Result<Option<(u64, u64)>, String> {
        let Some(length) = self.length(true)? else {
            return Ok(None);
        };
        let offset = self
            .reader
            .stream_position()
            .map_err(|error| format!("query screenshot position: {error}"))?;
        self.skip(length as u64)?;
        Ok(Some((offset, length as u64)))
    }

    fn collection(&mut self, name: &str) -> Result<usize, String> {
        let length = self.i32()?;
        if length < 0 || length as usize > MAX_COLLECTION {
            return Err(format!("invalid {name} collection length: {length}"));
        }
        Ok(length as usize)
    }

    fn skip_character(&mut self, version: i32) -> Result<(), String> {
        self.skip_string()?;
        self.skip_nullable_string()?;
        self.skip_nullable_string()?;
        self.skip_nullable_string()?;
        if version >= 15 {
            self.skip_nullable_string()?;
            self.skip_nullable_string()?;
        }
        Ok(())
    }

    fn game_state_preview(&mut self, version: i32) -> Result<SavePreview, String> {
        self.skip_nullable_string()?; // background
        if version >= 3 {
            self.skip_nullable_string()?; // movieFile
        }
        let dialogue = self.nullable_string()?;
        if version >= 12 {
            self.skip_nullable_string()?; // dialogueTag
        }
        let speaker = self.nullable_string()?;

        for _ in 0..self.collection("characters")? {
            self.skip_string()?; // character map key
            self.skip_character(version)?;
        }
        if version >= 4 {
            for _ in 0..self.collection("CG characters")? {
                self.skip_string()?; // CG character map key
                self.skip_character(version)?;
            }
        }

        let is_nvl_mode = self.u8()? == 1;
        self.u8()?; // isNvlMovieMode
        if version >= 5 {
            self.u8()?; // isNvlnMode
        }
        if version >= 6 {
            self.u8()?; // isNvlOverlayVisible
        }

        let mut latest_nvl = None;
        for _ in 0..self.collection("NVL dialogues")? {
            let nvl_speaker = self.nullable_string()?;
            let nvl_dialogue = self.string()?;
            if version >= 12 {
                self.skip_nullable_string()?; // voice
            }
            self.i64()?; // timestamp
            latest_nvl = Some((nvl_speaker, nvl_dialogue));
        }

        let mut choices = Vec::new();
        if version >= 7 {
            match self.u8()? {
                0 => {}
                1 => {
                    for _ in 0..self.collection("menu choices")? {
                        choices.push(self.string()?);
                        self.skip_string()?; // targetLabel
                    }
                }
                value => return Err(format!("invalid current-node marker: {value}")),
            }
        }

        if !choices.is_empty() {
            return Ok(SavePreview {
                kind: "menu",
                speaker: None,
                text: None,
                choices,
            });
        }
        if is_nvl_mode {
            if let Some((speaker, text)) = latest_nvl {
                return Ok(SavePreview {
                    kind: "nvl",
                    speaker,
                    text: Some(text),
                    choices,
                });
            }
        }
        if let Some(text) = dialogue {
            return Ok(SavePreview {
                kind: "dialogue",
                speaker,
                text: Some(text),
                choices,
            });
        }
        Ok(SavePreview {
            kind: "stored",
            speaker: None,
            text: None,
            choices,
        })
    }
}

struct Reader<'a> {
    cursor: Cursor<&'a [u8]>,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self {
            cursor: Cursor::new(bytes),
        }
    }

    fn position(&self) -> u64 {
        self.cursor.position()
    }

    fn remaining(&self) -> u64 {
        self.cursor
            .get_ref()
            .len()
            .saturating_sub(self.position() as usize) as u64
    }

    fn exact(&mut self, length: usize) -> Result<Vec<u8>, String> {
        if length > MAX_FIELD_BYTES || length as u64 > self.remaining() {
            return Err(format!("save field exceeds remaining data: {length} bytes"));
        }
        let mut bytes = vec![0_u8; length];
        self.cursor
            .read_exact(&mut bytes)
            .map_err(|error| format!("truncated save data: {error}"))?;
        Ok(bytes)
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.exact(1)?[0])
    }

    fn bool(&mut self) -> Result<(), String> {
        match self.u8()? {
            0 | 1 => Ok(()),
            value => Err(format!("invalid boolean byte: {value}")),
        }
    }

    fn i32(&mut self) -> Result<i32, String> {
        Ok(i32::from_le_bytes(self.exact(4)?.try_into().unwrap()))
    }

    fn i64(&mut self) -> Result<i64, String> {
        Ok(i64::from_le_bytes(self.exact(8)?.try_into().unwrap()))
    }

    fn length(&mut self, nullable: bool) -> Result<Option<usize>, String> {
        let length = self.i32()?;
        if nullable && length == -1 {
            return Ok(None);
        }
        if length < 0 {
            return Err(format!("invalid negative save field length: {length}"));
        }
        let length = length as usize;
        if length > MAX_FIELD_BYTES {
            return Err(format!("save field is too large: {length} bytes"));
        }
        Ok(Some(length))
    }

    fn string(&mut self) -> Result<String, String> {
        let length = self.length(false)?.unwrap();
        String::from_utf8(self.exact(length)?)
            .map_err(|error| format!("save string is not UTF-8: {error}"))
    }

    fn nullable_string(&mut self) -> Result<Option<String>, String> {
        let Some(length) = self.length(true)? else {
            return Ok(None);
        };
        String::from_utf8(self.exact(length)?)
            .map(Some)
            .map_err(|error| format!("save string is not UTF-8: {error}"))
    }

    fn skip_nullable_bytes(&mut self) -> Result<Option<(u64, u64)>, String> {
        let Some(length) = self.length(true)? else {
            return Ok(None);
        };
        let offset = self.position();
        self.exact(length)?;
        Ok(Some((offset, length as u64)))
    }

    fn collection(&mut self, name: &str) -> Result<usize, String> {
        let length = self.i32()?;
        if length < 0 || length as usize > MAX_COLLECTION {
            return Err(format!("invalid {name} collection length: {length}"));
        }
        Ok(length as usize)
    }

    fn character(&mut self, version: i32) -> Result<(), String> {
        self.string()?;
        self.nullable_string()?;
        self.nullable_string()?;
        self.nullable_string()?;
        if version >= 15 {
            self.nullable_string()?;
            self.nullable_string()?;
        }
        Ok(())
    }

    fn nvl(&mut self, version: i32) -> Result<(), String> {
        self.nullable_string()?;
        self.string()?;
        if version >= 12 {
            self.nullable_string()?;
        }
        self.i64()?;
        Ok(())
    }

    fn current_node(&mut self, version: i32) -> Result<(), String> {
        if version < 7 {
            return Ok(());
        }
        let present = self.u8()?;
        if present == 0 {
            return Ok(());
        }
        if present != 1 {
            return Err(format!("invalid current-node marker: {present}"));
        }
        for _ in 0..self.collection("menu choices")? {
            self.string()?;
            self.string()?;
        }
        Ok(())
    }

    fn game_state(&mut self, version: i32) -> Result<(), String> {
        self.nullable_string()?;
        if version >= 3 {
            self.nullable_string()?;
        }
        self.nullable_string()?;
        if version >= 12 {
            self.nullable_string()?;
        }
        self.nullable_string()?;
        for _ in 0..self.collection("characters")? {
            self.string()?;
            self.character(version)?;
        }
        if version >= 4 {
            for _ in 0..self.collection("CG characters")? {
                self.string()?;
                self.character(version)?;
            }
        }
        self.bool()?;
        self.bool()?;
        if version >= 5 {
            self.bool()?;
        }
        if version >= 6 {
            self.bool()?;
        }
        for _ in 0..self.collection("NVL dialogues")? {
            self.nvl(version)?;
        }
        self.current_node(version)?;
        if version >= 8 {
            self.nullable_string()?;
            self.nullable_string()?;
            self.nullable_string()?;
            self.nullable_string()?;
            self.nullable_string()?;
            if version >= 9 {
                self.bool()?;
                self.bool()?;
                if version >= 10 {
                    self.bool()?;
                    if version >= 11 {
                        self.nullable_string()?;
                        self.bool()?;
                    }
                }
            }
            self.i32()?;
            if version >= 14 {
                self.nullable_string()?;
            }
        }
        Ok(())
    }

    fn snapshot(&mut self, version: i32, depth: usize) -> Result<i32, String> {
        if depth > MAX_SNAPSHOT_DEPTH {
            return Err("save snapshot nesting is too deep".to_string());
        }
        let script_index = self.i32()?;
        self.game_state(version)?;
        for _ in 0..self.collection("dialogue history")? {
            self.nullable_string()?;
            self.string()?;
            if version >= 12 {
                self.nullable_string()?;
            }
            self.i64()?;
            self.i32()?;
            if version >= 13 {
                self.nullable_string()?;
                self.nullable_string()?;
            }
            self.snapshot(version, depth + 1)?;
        }
        self.bool()?;
        self.bool()?;
        if version >= 5 {
            self.bool()?;
        }
        if version >= 6 {
            self.bool()?;
        }
        for _ in 0..self.collection("snapshot NVL dialogues")? {
            self.nvl(version)?;
        }
        if version >= 16 {
            for _ in 0..self.collection("looping sounds")? {
                self.string()?;
            }
        }
        Ok(script_index)
    }
}

fn decode(bytes: &[u8]) -> Result<RustSaveMetadata, String> {
    let mut reader = Reader::new(bytes);
    if reader.exact(4)?.as_slice() != MAGIC {
        return Err("invalid SAKI save magic".to_string());
    }
    let version = reader.i32()?;
    if !(1..=MAX_VERSION).contains(&version) {
        return Err(format!("unsupported save version: {version}"));
    }
    let id = if version == 1 {
        reader.i32()? as i64
    } else {
        reader.i64()?
    };
    let save_time_millis = reader.i64()?;
    let current_script = reader.string()?;
    let dialogue_preview = reader.nullable_string()?.unwrap_or_default();
    let screenshot = reader.skip_nullable_bytes()?;
    let is_locked = match reader.u8()? {
        0 => false,
        1 => true,
        value => return Err(format!("invalid save lock byte: {value}")),
    };
    let script_index = reader.snapshot(version, 0)?;
    if reader.remaining() != 0 {
        return Err(format!(
            "save contains {} unexpected trailing bytes",
            reader.remaining()
        ));
    }
    Ok(RustSaveMetadata {
        version,
        id,
        save_time_millis,
        current_script,
        dialogue_preview,
        screenshot_offset: screenshot.map(|value| value.0),
        screenshot_length: screenshot.map(|value| value.1),
        is_locked,
        script_index,
    })
}

fn decode_header_file(path: &Path) -> Result<RustSaveHeader, String> {
    let file =
        File::open(path).map_err(|error| format!("open save file {}: {error}", path.display()))?;
    let file_length = file
        .metadata()
        .map_err(|error| format!("stat save file {}: {error}", path.display()))?
        .len();
    let mut reader = HeaderReader::new(BufReader::new(file), file_length);
    let mut magic = [0_u8; 4];
    reader.exact(&mut magic)?;
    if &magic != MAGIC {
        return Err("invalid SAKI save magic".to_string());
    }
    let version = reader.i32()?;
    if !(1..=MAX_VERSION).contains(&version) {
        return Err(format!("unsupported save version: {version}"));
    }
    let id = if version == 1 {
        reader.i32()? as i64
    } else {
        reader.i64()?
    };
    let save_time_millis = reader.i64()?;
    let current_script = reader.string()?;
    let dialogue_preview = reader.nullable_string()?.unwrap_or_default();
    let screenshot = reader.skip_nullable_bytes()?;
    let is_locked = match reader.u8()? {
        0 => false,
        1 => true,
        value => return Err(format!("invalid save lock byte: {value}")),
    };
    let script_index = reader.i32()?;
    let preview = reader.game_state_preview(version)?;
    Ok(RustSaveHeader {
        id,
        version,
        save_time_millis,
        current_script,
        dialogue_preview,
        file_path: path.to_string_lossy().to_string(),
        screenshot_offset: screenshot.map(|value| value.0 as i64),
        screenshot_length: screenshot.map(|value| value.1 as i64),
        is_locked,
        script_index,
        preview_kind: preview.kind.to_string(),
        preview_speaker: preview.speaker,
        preview_text: preview.text,
        preview_choices: preview.choices,
    })
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("create save directory {}: {error}", parent.display()))?;
    }
    let temporary = PathBuf::from(format!(
        "{}.tmp.{}.{}",
        path.to_string_lossy(),
        std::process::id(),
        NEXT_TEMP_FILE.fetch_add(1, Ordering::Relaxed)
    ));
    {
        let mut output =
            File::create(&temporary).map_err(|error| format!("create save temp file: {error}"))?;
        output
            .write_all(bytes)
            .map_err(|error| format!("write save temp file: {error}"))?;
        output
            .sync_all()
            .map_err(|error| format!("flush save temp file: {error}"))?;
    }
    if let Err(first_error) = fs::rename(&temporary, path) {
        if !path.exists() {
            return Err(format!("commit save file: {first_error}"));
        }
        fs::remove_file(path).map_err(|error| format!("replace save file: {error}"))?;
        fs::rename(&temporary, path).map_err(|error| format!("commit save file: {error}"))?;
    }
    Ok(())
}

pub fn decode_save_bytes(data: Vec<u8>) -> Result<RustDecodedSave, String> {
    let metadata = decode(&data)?;
    Ok(RustDecodedSave { metadata, data })
}

pub fn read_save_file(path: String) -> Result<RustDecodedSave, String> {
    let data = fs::read(&path).map_err(|error| format!("read save file {path}: {error}"))?;
    decode_save_bytes(data)
}

pub fn write_save_file(path: String, data: Vec<u8>) -> Result<RustSaveMetadata, String> {
    let metadata = decode(&data)?;
    atomic_write(Path::new(&path), &data)?;
    Ok(metadata)
}

fn modified_nanos(metadata: &fs::Metadata) -> u64 {
    metadata
        .modified()
        .ok()
        .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
        .map(|value| value.as_nanos().min(u64::MAX as u128) as u64)
        .unwrap_or(0)
}

fn read_cached_save_headers(directory: &Path) -> HashMap<String, CachedSaveHeaderEntry> {
    let path = directory.join(SAVE_HEADER_INDEX_FILE);
    let Ok(data) = fs::read(&path) else {
        return HashMap::new();
    };
    let Ok(index) = serde_json::from_slice::<CachedSaveHeaderIndex>(&data) else {
        eprintln!("[SAKI_SAVE][RUST] cache-invalid reason=decode");
        return HashMap::new();
    };
    if index.version != SAVE_HEADER_INDEX_VERSION {
        eprintln!(
            "[SAKI_SAVE][RUST] cache-invalid reason=version actual={}",
            index.version
        );
        return HashMap::new();
    }
    index
        .entries
        .into_iter()
        .map(|entry| (entry.file_name.clone(), entry))
        .collect()
}

fn write_cached_save_headers(
    directory: &Path,
    entries: Vec<CachedSaveHeaderEntry>,
) -> Result<(), String> {
    let index = CachedSaveHeaderIndex {
        version: SAVE_HEADER_INDEX_VERSION,
        entries,
    };
    let data =
        serde_json::to_vec(&index).map_err(|error| format!("encode save header index: {error}"))?;
    atomic_write(&directory.join(SAVE_HEADER_INDEX_FILE), &data)
}

pub fn scan_save_headers(
    directory: String,
    start_slot_id: i64,
    end_slot_id: i64,
) -> Result<RustSaveHeaderScan, String> {
    let started = std::time::Instant::now();
    eprintln!("[SAKI_SAVE][RUST] scan-start range={start_slot_id}..{end_slot_id}");
    let directory_path = Path::new(&directory);
    let use_persistent_cache = start_slot_id <= 1 && end_slot_id >= i32::MAX as i64;
    let mut cached_by_name = if use_persistent_cache {
        read_cached_save_headers(directory_path)
    } else {
        HashMap::new()
    };
    let mut paths = Vec::new();
    for entry in fs::read_dir(&directory)
        .map_err(|error| format!("read save directory {directory}: {error}"))?
    {
        let entry = entry.map_err(|error| format!("read save directory entry: {error}"))?;
        let path = entry.path();
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        if !metadata.is_file() {
            continue;
        }
        let Some(file_name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        let file_name = file_name.to_string();
        let Some(id_text) = file_name
            .strip_prefix("save_")
            .and_then(|value| value.strip_suffix(".sakisav"))
        else {
            continue;
        };
        let Ok(id) = id_text.parse::<i64>() else {
            continue;
        };
        if id >= start_slot_id && id <= end_slot_id {
            paths.push(SaveHeaderPath {
                path,
                file_name,
                file_length: metadata.len(),
                modified_nanos: modified_nanos(&metadata),
            });
        }
    }
    paths.sort_unstable_by(|a, b| a.file_name.cmp(&b.file_name));
    eprintln!(
        "[SAKI_SAVE][RUST] enumerate-done files={} elapsedMs={:.3}",
        paths.len(),
        started.elapsed().as_secs_f64() * 1000.0
    );

    let mut slots = Vec::with_capacity(paths.len());
    let mut invalid_files = Vec::new();
    let mut cache_entries = Vec::with_capacity(paths.len());
    let mut uncached_indices = Vec::new();
    for (index, path) in paths.iter().enumerate() {
        if let Some(cached) = cached_by_name.remove(&path.file_name) {
            if cached.file_length == path.file_length
                && cached.modified_nanos == path.modified_nanos
            {
                slots.push(cached.header.clone());
                cache_entries.push(cached);
                continue;
            }
        }
        uncached_indices.push(index);
    }
    eprintln!(
        "[SAKI_SAVE][RUST] cache-check hits={} misses={} elapsedMs={:.3}",
        slots.len(),
        uncached_indices.len(),
        started.elapsed().as_secs_f64() * 1000.0
    );

    let worker_count = uncached_indices.len().min(MAX_HEADER_SCAN_WORKERS).max(1);
    let next_work = AtomicUsize::new(0);
    let decoded = Mutex::new(Vec::with_capacity(uncached_indices.len()));
    std::thread::scope(|scope| {
        for worker in 0..worker_count {
            let paths = &paths;
            let uncached_indices = &uncached_indices;
            let next_work = &next_work;
            let decoded = &decoded;
            scope.spawn(move || loop {
                let work_index = next_work.fetch_add(1, Ordering::Relaxed);
                if work_index >= uncached_indices.len() {
                    break;
                }
                let path_index = uncached_indices[work_index];
                let path = &paths[path_index];
                let file_started = std::time::Instant::now();
                eprintln!(
                    "[SAKI_SAVE][RUST] file-start worker={} index={} file={}",
                    worker + 1,
                    path_index + 1,
                    path.file_name
                );
                let result = decode_header_file(&path.path);
                eprintln!(
                    "[SAKI_SAVE][RUST] file-done worker={} index={} file={} \
                     success={} elapsedMs={:.3}",
                    worker + 1,
                    path_index + 1,
                    path.file_name,
                    result.is_ok(),
                    file_started.elapsed().as_secs_f64() * 1000.0
                );
                decoded
                    .lock()
                    .expect("save header result mutex poisoned")
                    .push((path_index, result));
            });
        }
    });

    let mut decoded = decoded
        .into_inner()
        .map_err(|_| "save header result mutex poisoned".to_string())?;
    decoded.sort_unstable_by_key(|(index, _)| *index);
    for (index, result) in decoded {
        let path = &paths[index];
        match result {
            Ok(header) => {
                cache_entries.push(CachedSaveHeaderEntry {
                    file_name: path.file_name.clone(),
                    file_length: path.file_length,
                    modified_nanos: path.modified_nanos,
                    header: header.clone(),
                });
                slots.push(header);
            }
            Err(error) => invalid_files.push(format!("{}: {error}", path.path.display())),
        }
    }

    if use_persistent_cache && invalid_files.is_empty() {
        if let Err(error) = write_cached_save_headers(directory_path, cache_entries) {
            eprintln!("[SAKI_SAVE][RUST] cache-write-failed error={error}");
        } else {
            eprintln!(
                "[SAKI_SAVE][RUST] cache-write-done elapsedMs={:.3}",
                started.elapsed().as_secs_f64() * 1000.0
            );
        }
    }
    slots.sort_unstable_by_key(|slot| slot.id);
    eprintln!(
        "[SAKI_SAVE][RUST] scan-done slots={} invalid={} elapsedMs={:.3}",
        slots.len(),
        invalid_files.len(),
        started.elapsed().as_secs_f64() * 1000.0
    );
    Ok(RustSaveHeaderScan {
        slots,
        invalid_files,
        elapsed_micros: started.elapsed().as_micros().min(u64::MAX as u128) as u64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn string(bytes: &mut Vec<u8>, value: Option<&str>) {
        match value {
            Some(value) => {
                bytes.extend_from_slice(&(value.len() as i32).to_le_bytes());
                bytes.extend_from_slice(value.as_bytes());
            }
            None => bytes.extend_from_slice(&(-1_i32).to_le_bytes()),
        }
    }

    fn minimal_v16() -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&16_i32.to_le_bytes());
        bytes.extend_from_slice(&7_i64.to_le_bytes());
        bytes.extend_from_slice(&1234_i64.to_le_bytes());
        string(&mut bytes, Some("start"));
        string(&mut bytes, Some(""));
        bytes.extend_from_slice(&(-1_i32).to_le_bytes());
        bytes.push(0);
        bytes.extend_from_slice(&3_i32.to_le_bytes());
        for _ in 0..5 {
            string(&mut bytes, None);
        }
        bytes.extend_from_slice(&0_i32.to_le_bytes());
        bytes.extend_from_slice(&0_i32.to_le_bytes());
        bytes.extend_from_slice(&[0, 0, 0, 0]);
        bytes.extend_from_slice(&0_i32.to_le_bytes());
        bytes.push(0);
        for _ in 0..5 {
            string(&mut bytes, None);
        }
        bytes.extend_from_slice(&[0, 0, 0]);
        string(&mut bytes, None);
        bytes.push(0);
        bytes.extend_from_slice(&0_i32.to_le_bytes());
        string(&mut bytes, None);
        bytes.extend_from_slice(&0_i32.to_le_bytes());
        bytes.extend_from_slice(&[0, 0, 0, 0]);
        bytes.extend_from_slice(&0_i32.to_le_bytes());
        bytes.extend_from_slice(&0_i32.to_le_bytes());
        bytes
    }

    #[test]
    fn validates_current_format() {
        let metadata = decode(&minimal_v16()).unwrap();
        assert_eq!(metadata.id, 7);
        assert_eq!(metadata.script_index, 3);
    }

    #[test]
    fn rejects_trailing_bytes() {
        let mut bytes = minimal_v16();
        bytes.push(1);
        assert!(decode(&bytes).unwrap_err().contains("trailing"));
    }

    #[test]
    fn atomically_round_trips_current_format() {
        let path = std::env::temp_dir().join(format!(
            "saki_save_codec_{}_{}.sakisav",
            std::process::id(),
            NEXT_TEMP_FILE.fetch_add(1, Ordering::Relaxed)
        ));
        let bytes = minimal_v16();
        let metadata = write_save_file(path.to_string_lossy().to_string(), bytes.clone()).unwrap();
        assert_eq!(metadata.id, 7);
        let decoded = read_save_file(path.to_string_lossy().to_string()).unwrap();
        assert_eq!(decoded.data, bytes);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn header_scan_writes_and_reuses_persistent_index() {
        let directory = std::env::temp_dir().join(format!(
            "saki_save_header_index_{}_{}",
            std::process::id(),
            NEXT_TEMP_FILE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&directory).unwrap();
        for id in 1_i64..=3 {
            let mut bytes = minimal_v16();
            bytes[8..16].copy_from_slice(&id.to_le_bytes());
            fs::write(directory.join(format!("save_{id}.sakisav")), bytes).unwrap();
        }

        let first =
            scan_save_headers(directory.to_string_lossy().to_string(), 1, i32::MAX as i64).unwrap();
        assert_eq!(first.slots.len(), 3);
        assert!(directory.join(SAVE_HEADER_INDEX_FILE).exists());

        let second =
            scan_save_headers(directory.to_string_lossy().to_string(), 1, i32::MAX as i64).unwrap();
        assert_eq!(second.slots.len(), 3);
        assert!(second.invalid_files.is_empty());

        let _ = fs::remove_dir_all(directory);
    }

    #[test]
    fn validates_external_fixture_when_configured() {
        let Ok(path) = std::env::var("SAKI_TEST_SAVE") else {
            return;
        };
        let bytes = fs::read(&path).unwrap();
        let metadata = decode(&bytes).unwrap();
        assert!((1..=MAX_VERSION).contains(&metadata.version));
        let parent = Path::new(&path).parent().unwrap();
        let scan =
            scan_save_headers(parent.to_string_lossy().to_string(), i64::MIN, i64::MAX).unwrap();
        assert!(scan.invalid_files.is_empty());
        assert!(!scan.slots.is_empty());
    }
}
