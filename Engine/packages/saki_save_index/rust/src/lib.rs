use rayon::prelude::*;
use serde::Serialize;
use std::ffi::{c_char, CStr, CString};
use std::fs::{self, File};
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::time::Instant;

const MAX_SAVE_VERSION: i32 = 16;
const MAX_FIELD_LENGTH: usize = 64 * 1024 * 1024;
const MAX_COLLECTION_LENGTH: i32 = 100_000;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ScanResponse {
    ok: bool,
    elapsed_micros: u128,
    slots: Vec<SaveHeader>,
    invalid_files: Vec<String>,
    error: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SaveHeader {
    id: i64,
    version: i32,
    save_time_millis: i64,
    current_script: String,
    dialogue_preview: String,
    file_path: String,
    screenshot_offset: Option<u64>,
    screenshot_length: Option<usize>,
    is_locked: bool,
    script_index: i32,
    preview_kind: &'static str,
    preview_speaker: Option<String>,
    preview_text: Option<String>,
    preview_choices: Vec<String>,
}

struct Preview {
    kind: &'static str,
    speaker: Option<String>,
    text: Option<String>,
    choices: Vec<String>,
}

#[no_mangle]
pub unsafe extern "C" fn saki_save_index_scan_json(
    directory: *const c_char,
    start_slot_id: i64,
    end_slot_id: i64,
) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        scan_from_pointer(directory, start_slot_id, end_slot_id)
    }))
    .unwrap_or_else(|_| ScanResponse {
        ok: false,
        elapsed_micros: 0,
        slots: Vec::new(),
        invalid_files: Vec::new(),
        error: Some("Rust save index panicked while scanning.".to_owned()),
    });

    let json = serde_json::to_string(&response).unwrap_or_else(|error| {
        format!(
            "{{\"ok\":false,\"elapsedMicros\":0,\"slots\":[],\
             \"invalidFiles\":[],\"error\":\"JSON encoding failed: {}\"}}",
            error
        )
    });
    CString::new(json)
        .unwrap_or_else(|_| CString::new("{\"ok\":false}").unwrap())
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn saki_save_index_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

unsafe fn scan_from_pointer(
    directory: *const c_char,
    start_slot_id: i64,
    end_slot_id: i64,
) -> ScanResponse {
    let started = Instant::now();
    if directory.is_null() {
        return failure(started, "Save directory pointer was null.".to_owned());
    }

    let directory = match CStr::from_ptr(directory).to_str() {
        Ok(value) => PathBuf::from(value),
        Err(error) => return failure(started, format!("Save directory is not UTF-8: {error}")),
    };

    match scan_directory(&directory, start_slot_id, end_slot_id) {
        Ok((slots, invalid_files)) => ScanResponse {
            ok: true,
            elapsed_micros: started.elapsed().as_micros(),
            slots,
            invalid_files,
            error: None,
        },
        Err(error) => failure(started, error),
    }
}

fn failure(started: Instant, error: String) -> ScanResponse {
    ScanResponse {
        ok: false,
        elapsed_micros: started.elapsed().as_micros(),
        slots: Vec::new(),
        invalid_files: Vec::new(),
        error: Some(error),
    }
}

fn scan_directory(
    directory: &Path,
    start_slot_id: i64,
    end_slot_id: i64,
) -> Result<(Vec<SaveHeader>, Vec<String>), String> {
    let entries = fs::read_dir(directory).map_err(|error| {
        format!(
            "Cannot read save directory {}: {error}",
            directory.display()
        )
    })?;

    let paths: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let path = entry.path();
            let id = manual_slot_id(&path)?;
            (id >= start_slot_id && id <= end_slot_id).then_some(path)
        })
        .collect();

    let parsed: Vec<(PathBuf, Result<SaveHeader, String>)> = paths
        .into_par_iter()
        .map(|path| {
            let result = parse_header(&path);
            (path, result)
        })
        .collect();

    let mut slots = Vec::new();
    let mut invalid_files = Vec::new();
    for (path, result) in parsed {
        match result {
            Ok(slot) => slots.push(slot),
            Err(error) => invalid_files.push(format!("{}: {error}", path.display())),
        }
    }
    slots.sort_by_key(|slot| slot.id);
    invalid_files.sort();
    Ok((slots, invalid_files))
}

fn manual_slot_id(path: &Path) -> Option<i64> {
    let file_name = path.file_name()?.to_str()?;
    let id = file_name.strip_prefix("save_")?.strip_suffix(".sakisav")?;
    id.parse().ok()
}

fn parse_header(path: &Path) -> Result<SaveHeader, String> {
    let file = File::open(path).map_err(|error| format!("Cannot open save file: {error}"))?;
    let file_length = file
        .metadata()
        .map_err(|error| format!("Cannot stat save file: {error}"))?
        .len();
    let mut reader = SaveReader::new(BufReader::new(file), file_length);

    let mut magic = [0_u8; 4];
    reader.read_exact(&mut magic)?;
    if &magic != b"SAKI" {
        return Err("Invalid SAKI magic.".to_owned());
    }

    let version = reader.read_i32()?;
    if !(1..=MAX_SAVE_VERSION).contains(&version) {
        return Err(format!("Unsupported save version: {version}"));
    }

    let id = if version == 1 {
        i64::from(reader.read_i32()?)
    } else {
        reader.read_i64()?
    };
    let save_time_millis = reader.read_i64()?;
    let current_script = reader.read_string()?;
    let dialogue_preview = reader.read_nullable_string()?.unwrap_or_default();
    let screenshot = reader.read_nullable_bytes_location()?;
    let is_locked = reader.read_u8()? == 1;
    let script_index = reader.read_i32()?;
    let preview = reader.read_game_state_preview(version)?;

    Ok(SaveHeader {
        id,
        version,
        save_time_millis,
        current_script,
        dialogue_preview,
        file_path: path.to_string_lossy().into_owned(),
        screenshot_offset: screenshot.map(|location| location.0),
        screenshot_length: screenshot.map(|location| location.1),
        is_locked,
        script_index,
        preview_kind: preview.kind,
        preview_speaker: preview.speaker,
        preview_text: preview.text,
        preview_choices: preview.choices,
    })
}

struct SaveReader<R> {
    reader: R,
    file_length: u64,
}

impl<R: Read + Seek> SaveReader<R> {
    fn new(reader: R, file_length: u64) -> Self {
        Self {
            reader,
            file_length,
        }
    }

    fn read_exact(&mut self, buffer: &mut [u8]) -> Result<(), String> {
        self.reader
            .read_exact(buffer)
            .map_err(|error| format!("Unexpected end of save data: {error}"))
    }

    fn read_u8(&mut self) -> Result<u8, String> {
        let mut value = [0_u8; 1];
        self.read_exact(&mut value)?;
        Ok(value[0])
    }

    fn read_i32(&mut self) -> Result<i32, String> {
        let mut value = [0_u8; 4];
        self.read_exact(&mut value)?;
        Ok(i32::from_le_bytes(value))
    }

    fn read_i64(&mut self) -> Result<i64, String> {
        let mut value = [0_u8; 8];
        self.read_exact(&mut value)?;
        Ok(i64::from_le_bytes(value))
    }

    fn checked_length(&mut self) -> Result<Option<usize>, String> {
        let value = self.read_i32()?;
        if value == -1 {
            return Ok(None);
        }
        if value < 0 {
            return Err(format!("Invalid negative field length: {value}"));
        }
        let length = value as usize;
        if length > MAX_FIELD_LENGTH {
            return Err(format!("Field is too large: {length} bytes"));
        }
        Ok(Some(length))
    }

    fn read_string(&mut self) -> Result<String, String> {
        let length = self
            .checked_length()?
            .ok_or_else(|| "Required string was null.".to_owned())?;
        self.read_utf8(length)
    }

    fn read_nullable_string(&mut self) -> Result<Option<String>, String> {
        self.checked_length()?
            .map(|length| self.read_utf8(length))
            .transpose()
    }

    fn read_utf8(&mut self, length: usize) -> Result<String, String> {
        let mut value = vec![0_u8; length];
        self.read_exact(&mut value)?;
        String::from_utf8(value).map_err(|error| format!("Invalid UTF-8 field: {error}"))
    }

    fn read_nullable_bytes_location(&mut self) -> Result<Option<(u64, usize)>, String> {
        let Some(length) = self.checked_length()? else {
            return Ok(None);
        };
        let position = self
            .reader
            .stream_position()
            .map_err(|error| format!("Cannot query save position: {error}"))?;
        if position.saturating_add(length as u64) > self.file_length {
            return Err("Screenshot extends beyond the save file.".to_owned());
        }
        self.skip(length as u64)?;
        Ok(Some((position, length)))
    }

    fn collection_length(&mut self, name: &str) -> Result<usize, String> {
        let value = self.read_i32()?;
        if !(0..=MAX_COLLECTION_LENGTH).contains(&value) {
            return Err(format!("Invalid {name} length: {value}"));
        }
        Ok(value as usize)
    }

    fn skip_string(&mut self) -> Result<(), String> {
        let length = self
            .checked_length()?
            .ok_or_else(|| "Required string was null.".to_owned())?;
        self.skip(length as u64)
    }

    fn skip_nullable_string(&mut self) -> Result<(), String> {
        if let Some(length) = self.checked_length()? {
            self.skip(length as u64)?;
        }
        Ok(())
    }

    fn skip(&mut self, length: u64) -> Result<(), String> {
        let current = self
            .reader
            .stream_position()
            .map_err(|error| format!("Cannot query save position: {error}"))?;
        if current.saturating_add(length) > self.file_length {
            return Err("Field extends beyond the save file.".to_owned());
        }
        self.reader
            .seek(SeekFrom::Current(length as i64))
            .map_err(|error| format!("Cannot skip save field: {error}"))?;
        Ok(())
    }

    fn skip_character_state(&mut self, version: i32) -> Result<(), String> {
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

    fn read_game_state_preview(&mut self, version: i32) -> Result<Preview, String> {
        self.skip_nullable_string()?; // background
        if version >= 3 {
            self.skip_nullable_string()?; // movieFile
        }
        let dialogue = self.read_nullable_string()?;
        if version >= 12 {
            self.skip_nullable_string()?; // dialogueTag
        }
        let speaker = self.read_nullable_string()?;

        let characters = self.collection_length("characters")?;
        for _ in 0..characters {
            self.skip_string()?;
            self.skip_character_state(version)?;
        }

        if version >= 4 {
            let cg_characters = self.collection_length("cgCharacters")?;
            for _ in 0..cg_characters {
                self.skip_string()?;
                self.skip_character_state(version)?;
            }
        }

        let is_nvl_mode = self.read_u8()? == 1;
        self.read_u8()?; // isNvlMovieMode
        if version >= 5 {
            self.read_u8()?; // isNvlnMode
        }
        if version >= 6 {
            self.read_u8()?; // isNvlOverlayVisible
        }

        let nvl_count = self.collection_length("nvlDialogues")?;
        let mut latest_nvl: Option<(Option<String>, String)> = None;
        for _ in 0..nvl_count {
            let nvl_speaker = self.read_nullable_string()?;
            let nvl_dialogue = self.read_string()?;
            if version >= 12 {
                self.skip_nullable_string()?;
            }
            self.read_i64()?;
            latest_nvl = Some((nvl_speaker, nvl_dialogue));
        }

        let mut choices = Vec::new();
        if version >= 7 && self.read_u8()? == 1 {
            let choice_count = self.collection_length("menu choices")?;
            for _ in 0..choice_count {
                choices.push(self.read_string()?);
                self.skip_string()?; // targetLabel
            }
        }

        if !choices.is_empty() {
            return Ok(Preview {
                kind: "menu",
                speaker: None,
                text: None,
                choices,
            });
        }
        if is_nvl_mode {
            if let Some((speaker, text)) = latest_nvl {
                return Ok(Preview {
                    kind: "nvl",
                    speaker,
                    text: Some(text),
                    choices,
                });
            }
        }
        if let Some(text) = dialogue {
            return Ok(Preview {
                kind: "dialogue",
                speaker,
                text: Some(text),
                choices,
            });
        }

        Ok(Preview {
            kind: "stored",
            speaker: None,
            text: None,
            choices,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::manual_slot_id;
    use std::path::Path;

    #[test]
    fn recognizes_only_manual_slot_files() {
        assert_eq!(manual_slot_id(Path::new("/tmp/save_22.sakisav")), Some(22));
        assert_eq!(manual_slot_id(Path::new("/tmp/autosave_1.sakisav")), None);
        assert_eq!(manual_slot_id(Path::new("/tmp/quicksave.sakisav")), None);
    }
}
