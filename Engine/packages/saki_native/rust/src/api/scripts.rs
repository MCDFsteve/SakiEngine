use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

#[derive(Clone, Debug)]
pub struct RustScriptSource {
    pub file_name: String,
    pub content: String,
}

#[derive(Clone, Debug)]
pub struct RustScriptLabel {
    pub label: String,
    pub file_name: String,
    pub source_line: u32,
}

#[derive(Clone, Debug)]
pub struct RustScriptReference {
    pub kind: String,
    pub value: String,
    pub file_name: String,
    pub source_line: u32,
}

#[derive(Clone, Debug)]
pub struct RustScriptDiagnostic {
    pub severity: String,
    pub message: String,
    pub file_name: String,
    pub source_line: u32,
}

#[derive(Clone, Debug)]
pub struct RustScriptCompileResult {
    pub merged_source: String,
    pub ordered_files: Vec<String>,
    pub labels: Vec<RustScriptLabel>,
    pub references: Vec<RustScriptReference>,
    pub diagnostics: Vec<RustScriptDiagnostic>,
    pub elapsed_micros: u64,
}

struct SourceAnalysis {
    labels: Vec<(String, u32)>,
    targets: Vec<(String, u32)>,
    references: Vec<RustScriptReference>,
}

fn strip_comment(line: &str) -> &str {
    let bytes = line.as_bytes();
    let mut quote = None;
    let mut escaped = false;
    let mut index = 0;
    while index + 1 < bytes.len() {
        let value = bytes[index];
        if escaped {
            escaped = false;
            index += 1;
            continue;
        }
        if value == b'\\' {
            escaped = true;
            index += 1;
            continue;
        }
        if let Some(active) = quote {
            if value == active {
                quote = None;
            }
            index += 1;
            continue;
        }
        if value == b'"' || value == b'\'' {
            quote = Some(value);
            index += 1;
            continue;
        }
        if value == b'/' && bytes[index + 1] == b'/' {
            return &line[..index];
        }
        index += 1;
    }
    line
}

fn first_argument(line: &str, command: &str) -> Option<String> {
    let trimmed = line.trim();
    let rest = trimmed.strip_prefix(command)?;
    if !rest.is_empty() && !rest.starts_with(char::is_whitespace) {
        return None;
    }
    let rest = rest.trim();
    if rest.is_empty() {
        return None;
    }
    if let Some(quoted) = rest.strip_prefix('"') {
        return quoted.find('"').map(|end| quoted[..end].to_string());
    }
    if let Some(quoted) = rest.strip_prefix('\'') {
        return quoted.find('\'').map(|end| quoted[..end].to_string());
    }
    rest.split_whitespace().next().map(ToString::to_string)
}

fn analyse(source: &RustScriptSource) -> SourceAnalysis {
    let mut result = SourceAnalysis {
        labels: Vec::new(),
        targets: Vec::new(),
        references: Vec::new(),
    };
    let mut in_menu = false;
    for (index, raw_line) in source.content.lines().enumerate() {
        let source_line = (index + 1).min(u32::MAX as usize) as u32;
        let line = strip_comment(raw_line).trim();
        if line.is_empty() {
            continue;
        }
        if line == "menu" {
            in_menu = true;
            continue;
        }
        if line == "endmenu" {
            in_menu = false;
            continue;
        }
        if in_menu && (line.starts_with('"') || line.starts_with('\'')) {
            let quote = line.as_bytes()[0] as char;
            if let Some(end) = line[1..].find(quote) {
                let remainder = line[end + 2..].trim();
                if let Some(target) = remainder.split_whitespace().next() {
                    result.targets.push((target.to_string(), source_line));
                }
            }
            continue;
        }
        if let Some(label) = first_argument(line, "label") {
            result.labels.push((label, source_line));
        }
        if let Some(target) = first_argument(line, "jump") {
            result.targets.push((target, source_line));
        }
        if let Some(target) = first_argument(line, "goto") {
            result.targets.push((target, source_line));
        }
        for (kind, command) in [
            ("music", "play music"),
            ("sound", "play sound"),
            ("voice", "voice"),
            ("background", "background"),
            ("movie", "movie"),
            ("cg", "cg"),
        ] {
            if let Some(value) = first_argument(line, command) {
                result.references.push(RustScriptReference {
                    kind: kind.to_string(),
                    value,
                    file_name: source.file_name.clone(),
                    source_line,
                });
            }
        }
    }
    result
}

fn visit(
    file_name: &str,
    analyses: &HashMap<String, SourceAnalysis>,
    label_files: &HashMap<String, String>,
    visiting: &mut HashSet<String>,
    visited: &mut HashSet<String>,
    ordered: &mut Vec<String>,
) {
    if visited.contains(file_name) || !analyses.contains_key(file_name) {
        return;
    }
    if !visiting.insert(file_name.to_string()) {
        return;
    }
    visited.insert(file_name.to_string());
    ordered.push(file_name.to_string());
    if let Some(analysis) = analyses.get(file_name) {
        let mut target_files = Vec::new();
        let mut seen = HashSet::new();
        for (target, _) in &analysis.targets {
            if let Some(target_file) = label_files.get(target) {
                if target_file != file_name && seen.insert(target_file.clone()) {
                    target_files.push(target_file.clone());
                }
            }
        }
        for target_file in target_files {
            visit(
                &target_file,
                analyses,
                label_files,
                visiting,
                visited,
                ordered,
            );
        }
    }
    visiting.remove(file_name);
}

pub fn compile_sks_sources(
    sources: Vec<RustScriptSource>,
) -> Result<RustScriptCompileResult, String> {
    let started = std::time::Instant::now();
    if sources.is_empty() {
        return Ok(RustScriptCompileResult {
            merged_source: String::new(),
            ordered_files: Vec::new(),
            labels: Vec::new(),
            references: Vec::new(),
            diagnostics: Vec::new(),
            elapsed_micros: 0,
        });
    }

    let mut source_map = BTreeMap::new();
    let mut diagnostics = Vec::new();
    for source in sources {
        let normalized = source.file_name.trim_end_matches(".sks").to_string();
        if normalized.trim().is_empty() {
            return Err("SKS source has an empty file name".to_string());
        }
        if source_map
            .insert(
                normalized.clone(),
                RustScriptSource {
                    file_name: normalized.clone(),
                    content: source.content,
                },
            )
            .is_some()
        {
            diagnostics.push(RustScriptDiagnostic {
                severity: "warning".to_string(),
                message: format!("duplicate source file replaced: {normalized}"),
                file_name: normalized,
                source_line: 0,
            });
        }
    }

    let mut analyses = HashMap::new();
    let mut label_files = HashMap::new();
    let mut labels = Vec::new();
    let mut references = Vec::new();
    for source in source_map.values() {
        let analysis = analyse(source);
        for (label, source_line) in &analysis.labels {
            if let Some(existing) = label_files.insert(label.clone(), source.file_name.clone()) {
                diagnostics.push(RustScriptDiagnostic {
                    severity: "error".to_string(),
                    message: format!("duplicate label `{label}`; first declared in `{existing}`"),
                    file_name: source.file_name.clone(),
                    source_line: *source_line,
                });
            }
            labels.push(RustScriptLabel {
                label: label.clone(),
                file_name: source.file_name.clone(),
                source_line: *source_line,
            });
        }
        references.extend(analysis.references.iter().cloned());
        analyses.insert(source.file_name.clone(), analysis);
    }
    for (file_name, analysis) in &analyses {
        for (target, source_line) in &analysis.targets {
            if !label_files.contains_key(target) {
                diagnostics.push(RustScriptDiagnostic {
                    severity: "warning".to_string(),
                    message: format!("unresolved jump target `{target}`"),
                    file_name: file_name.clone(),
                    source_line: *source_line,
                });
            }
        }
    }

    let mut ordered_files = Vec::with_capacity(source_map.len());
    let mut visited = HashSet::new();
    let mut visiting = HashSet::new();
    if source_map.contains_key("start") {
        visit(
            "start",
            &analyses,
            &label_files,
            &mut visiting,
            &mut visited,
            &mut ordered_files,
        );
    }
    for file_name in source_map.keys() {
        visit(
            file_name,
            &analyses,
            &label_files,
            &mut visiting,
            &mut visited,
            &mut ordered_files,
        );
    }

    let mut merged_source = String::new();
    for file_name in &ordered_files {
        let source = source_map.get(file_name).expect("ordered source exists");
        merged_source.push_str("__saki_source \"");
        merged_source.push_str(&file_name.replace('"', ""));
        merged_source.push_str("\"\n");
        merged_source.push_str(&source.content);
        if !source.content.ends_with('\n') {
            merged_source.push('\n');
        }
        merged_source.push_str("__saki_source_end \"");
        merged_source.push_str(&file_name.replace('"', ""));
        merged_source.push_str("\"\n");
    }

    labels.sort_unstable_by(|left, right| {
        (&left.file_name, left.source_line, &left.label).cmp(&(
            &right.file_name,
            right.source_line,
            &right.label,
        ))
    });
    references.sort_unstable_by(|left, right| {
        (&left.file_name, left.source_line, &left.kind, &left.value).cmp(&(
            &right.file_name,
            right.source_line,
            &right.kind,
            &right.value,
        ))
    });
    let known_files: BTreeSet<_> = source_map.keys().cloned().collect();
    for label_file in label_files.values() {
        debug_assert!(known_files.contains(label_file));
    }

    Ok(RustScriptCompileResult {
        merged_source,
        ordered_files,
        labels,
        references,
        diagnostics,
        elapsed_micros: started.elapsed().as_micros().min(u64::MAX as u128) as u64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orders_reachable_files_before_standalone_entries() {
        let result = compile_sks_sources(vec![
            RustScriptSource {
                file_name: "extra.sks".into(),
                content: "label extra".into(),
            },
            RustScriptSource {
                file_name: "chapter.sks".into(),
                content: "label chapter".into(),
            },
            RustScriptSource {
                file_name: "start.sks".into(),
                content: "label start\njump chapter".into(),
            },
        ])
        .unwrap();
        assert_eq!(result.ordered_files, ["start", "chapter", "extra"]);
        assert!(result.merged_source.contains("__saki_source \"chapter\""));
    }

    #[test]
    fn comments_do_not_create_fake_jumps() {
        let result = compile_sks_sources(vec![RustScriptSource {
            file_name: "start".into(),
            content: "label start\n// jump nowhere\n\"// literal\"".into(),
        }])
        .unwrap();
        assert!(result.diagnostics.is_empty());
    }
}
