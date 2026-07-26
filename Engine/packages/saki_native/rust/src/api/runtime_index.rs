use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

#[derive(Clone, Debug)]
pub struct RustRuntimeChoice {
    pub text: String,
    pub target_label: String,
}

#[derive(Clone, Debug)]
pub struct RustRuntimeNode {
    pub script_index: u32,
    pub kind: String,
    pub value: Option<String>,
    pub secondary: Option<String>,
    pub dialogue_tag: Option<String>,
    pub source_file: Option<String>,
    pub source_line: Option<u32>,
    pub condition_variable: Option<String>,
    pub condition_value: Option<bool>,
    pub choices: Vec<RustRuntimeChoice>,
}

#[derive(Clone, Debug)]
pub struct RustRuntimeLabelIndex {
    pub label: String,
    pub script_index: u32,
}

#[derive(Clone, Debug)]
pub struct RustRuntimeFlowNode {
    pub id: String,
    pub label: String,
    pub kind: String,
    pub display_name: String,
    pub script_index: u32,
    pub chapter_name: Option<String>,
    pub parent_id: Option<String>,
    pub child_ids: Vec<String>,
    pub branch_text: Option<String>,
    pub parent_ids: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct RustRuntimeIndex {
    pub handle: u64,
    pub labels: Vec<RustRuntimeLabelIndex>,
    pub flow_nodes: Vec<RustRuntimeFlowNode>,
    pub root_ids: Vec<String>,
    pub compact_bytes: u64,
    pub elapsed_micros: u64,
    pub condition_variables: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct RustRuntimePrompt {
    pub dialogue: String,
    pub speaker: Option<String>,
    pub dialogue_tag: Option<String>,
    pub script_index: u32,
    pub source_file: Option<String>,
    pub source_line: Option<u32>,
}

#[derive(Clone, Debug)]
pub struct RustMenuSeekResult {
    pub found: bool,
    pub menu_index: Option<u32>,
    pub prompts: Vec<RustRuntimePrompt>,
    pub visited: u32,
}

struct CompactRuntime {
    nodes: BTreeMap<u32, RustRuntimeNode>,
    labels: HashMap<String, u32>,
    end_index: u32,
}

static RUNTIMES: OnceLock<Mutex<HashMap<u64, CompactRuntime>>> = OnceLock::new();
static NEXT_RUNTIME_HANDLE: AtomicU64 = AtomicU64::new(1);

fn runtimes() -> &'static Mutex<HashMap<u64, CompactRuntime>> {
    RUNTIMES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn chapter_identity(value: &str) -> Option<(String, String)> {
    let lower = value.to_lowercase();
    if let Some(start) = lower.find("chapter") {
        let suffix: String = lower[start + "chapter".len()..]
            .chars()
            .skip_while(|value| matches!(value, '_' | '-' | ' ' | '['))
            .take_while(char::is_ascii_digit)
            .collect();
        if !suffix.is_empty() {
            return Some((format!("chapter_{suffix}"), format!("chapter{suffix}")));
        }
    }
    if lower.contains("prologue") {
        return Some(("chapter_prologue".into(), "prologue".into()));
    }
    if lower.contains("epilogue") {
        return Some(("chapter_epilogue".into(), "epilogue".into()));
    }
    for prefix in ["ch", "ep"] {
        if let Some(start) = lower.find(prefix) {
            let digits: String = lower[start + prefix.len()..]
                .chars()
                .take_while(char::is_ascii_digit)
                .collect();
            if !digits.is_empty() {
                return Some((format!("chapter_{digits}"), format!("chapter{digits}")));
            }
        }
    }
    None
}

fn estimate_bytes(nodes: &[RustRuntimeNode]) -> u64 {
    nodes
        .iter()
        .map(|node| {
            16 + node.kind.len()
                + node.value.as_ref().map_or(0, String::len)
                + node.secondary.as_ref().map_or(0, String::len)
                + node.dialogue_tag.as_ref().map_or(0, String::len)
                + node.source_file.as_ref().map_or(0, String::len)
                + node.condition_variable.as_ref().map_or(0, String::len)
                + node
                    .choices
                    .iter()
                    .map(|choice| choice.text.len() + choice.target_label.len() + 8)
                    .sum::<usize>()
        })
        .sum::<usize>()
        .min(u64::MAX as usize) as u64
}

pub fn build_runtime_index(mut nodes: Vec<RustRuntimeNode>) -> Result<RustRuntimeIndex, String> {
    let started = std::time::Instant::now();
    nodes.sort_unstable_by_key(|node| node.script_index);
    let compact_bytes = estimate_bytes(&nodes);
    let mut condition_variables: Vec<_> = nodes
        .iter()
        .filter_map(|node| node.condition_variable.clone())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    condition_variables.sort_unstable();

    let mut label_indices = HashMap::new();
    let mut jump_counts: HashMap<String, usize> = HashMap::new();
    let mut label_to_jump = HashMap::new();
    let mut active_label: Option<String> = None;
    for node in &nodes {
        match node.kind.as_str() {
            "label" => {
                let label = node.value.clone().unwrap_or_default();
                label_indices.insert(label.clone(), node.script_index);
                active_label = Some(label);
            }
            "jump" => {
                if let Some(target) = &node.value {
                    *jump_counts.entry(target.clone()).or_default() += 1;
                    if let Some(label) = &active_label {
                        label_to_jump
                            .entry(label.clone())
                            .or_insert_with(|| target.clone());
                    }
                }
            }
            _ => {}
        }
    }

    let mut labels: Vec<_> = label_indices
        .iter()
        .map(|(label, script_index)| RustRuntimeLabelIndex {
            label: label.clone(),
            script_index: *script_index,
        })
        .collect();
    labels.sort_unstable_by_key(|entry| entry.script_index);

    let mut option_targets: Vec<(String, String)> = Vec::new();
    let mut flow = BTreeMap::<String, RustRuntimeFlowNode>::new();
    let mut root_ids = Vec::new();
    let mut current_label = String::new();
    let mut current_chapter: Option<(String, String)> = None;
    let mut current_merge: Option<String> = None;

    for node in &nodes {
        match node.kind.as_str() {
            "label" => {
                current_label = node.value.clone().unwrap_or_default();
                current_merge = None;
                if jump_counts.get(&current_label).copied().unwrap_or(0) >= 2 {
                    let id = format!("merge_{current_label}");
                    current_merge = Some(id.clone());
                    flow.entry(id.clone()).or_insert(RustRuntimeFlowNode {
                        id,
                        label: current_label.clone(),
                        kind: "merge".into(),
                        display_name: "merge".into(),
                        script_index: node.script_index,
                        chapter_name: current_chapter.as_ref().map(|(_, display)| display.clone()),
                        parent_id: None,
                        child_ids: Vec::new(),
                        branch_text: None,
                        parent_ids: Vec::new(),
                    });
                }
            }
            "background" => {
                if let Some(value) = node.value.as_deref() {
                    if let Some((id, display)) = chapter_identity(value) {
                        current_chapter = Some((id.clone(), display.clone()));
                        current_merge = None;
                        if !flow.contains_key(&id) {
                            root_ids.push(id.clone());
                            flow.insert(
                                id.clone(),
                                RustRuntimeFlowNode {
                                    id,
                                    label: if current_label.is_empty() {
                                        format!("chapter_{}", node.script_index)
                                    } else {
                                        current_label.clone()
                                    },
                                    kind: "chapter".into(),
                                    display_name: display.clone(),
                                    script_index: node.script_index,
                                    chapter_name: Some(display),
                                    parent_id: None,
                                    child_ids: Vec::new(),
                                    branch_text: None,
                                    parent_ids: Vec::new(),
                                },
                            );
                        }
                    }
                }
            }
            "menu" => {
                let branch_id = format!("branch_{}", node.script_index);
                let parent_id = current_merge.clone().or_else(|| {
                    current_chapter
                        .as_ref()
                        .map(|(chapter_id, _)| chapter_id.clone())
                });
                let child_ids = node
                    .choices
                    .iter()
                    .map(|choice| format!("option_{branch_id}_{}", choice.target_label))
                    .collect::<Vec<_>>();
                flow.insert(
                    branch_id.clone(),
                    RustRuntimeFlowNode {
                        id: branch_id.clone(),
                        label: current_label.clone(),
                        kind: "branch".into(),
                        display_name: "branch".into(),
                        script_index: node.script_index,
                        chapter_name: current_chapter.as_ref().map(|(_, display)| display.clone()),
                        parent_id,
                        child_ids: child_ids.clone(),
                        branch_text: None,
                        parent_ids: Vec::new(),
                    },
                );
                for (choice, option_id) in node.choices.iter().zip(child_ids) {
                    let option_index = label_indices
                        .get(&choice.target_label)
                        .copied()
                        .unwrap_or(node.script_index);
                    option_targets.push((option_id.clone(), choice.target_label.clone()));
                    flow.insert(
                        option_id.clone(),
                        RustRuntimeFlowNode {
                            id: option_id,
                            label: choice.target_label.clone(),
                            kind: "branch".into(),
                            display_name: choice.text.clone(),
                            script_index: option_index,
                            chapter_name: current_chapter
                                .as_ref()
                                .map(|(_, display)| display.clone()),
                            parent_id: Some(branch_id.clone()),
                            child_ids: Vec::new(),
                            branch_text: Some(choice.text.clone()),
                            parent_ids: Vec::new(),
                        },
                    );
                }
            }
            "return" => {
                if let Some(parent_id) = current_merge.clone() {
                    let id = format!("ending_{}", node.script_index);
                    flow.insert(
                        id.clone(),
                        RustRuntimeFlowNode {
                            id,
                            label: current_label.clone(),
                            kind: "ending".into(),
                            display_name: format!("ending:{current_label}"),
                            script_index: node.script_index,
                            chapter_name: current_chapter
                                .as_ref()
                                .map(|(_, display)| display.clone()),
                            parent_id: Some(parent_id),
                            child_ids: Vec::new(),
                            branch_text: None,
                            parent_ids: Vec::new(),
                        },
                    );
                }
            }
            _ => {}
        }
    }

    for (option_id, target_label) in option_targets {
        let final_target = label_to_jump
            .get(&target_label)
            .cloned()
            .unwrap_or(target_label);
        let merge_id = format!("merge_{final_target}");
        if let Some(merge) = flow.get_mut(&merge_id) {
            merge.parent_ids.push(option_id.clone());
            if merge.parent_id.is_none() {
                merge.parent_id = Some(option_id.clone());
            }
            if let Some(option) = flow.get_mut(&option_id) {
                option.child_ids.push(merge_id);
            }
        }
    }

    let parent_edges: Vec<_> = flow
        .values()
        .filter_map(|node| {
            node.parent_id
                .as_ref()
                .map(|parent| (parent.clone(), node.id.clone()))
        })
        .collect();
    for (parent, child) in parent_edges {
        if let Some(node) = flow.get_mut(&parent) {
            if !node.child_ids.contains(&child) {
                node.child_ids.push(child);
            }
        }
    }

    let flow_nodes = flow.into_values().collect();
    let handle = NEXT_RUNTIME_HANDLE.fetch_add(1, Ordering::Relaxed);
    let end_index = nodes
        .last()
        .map(|node| node.script_index.saturating_add(1))
        .unwrap_or(0);
    runtimes()
        .lock()
        .map_err(|_| "script runtime store is poisoned".to_string())?
        .insert(
            handle,
            CompactRuntime {
                nodes: nodes
                    .into_iter()
                    .map(|node| (node.script_index, node))
                    .collect(),
                labels: label_indices,
                end_index,
            },
        );
    Ok(RustRuntimeIndex {
        handle,
        labels,
        flow_nodes,
        root_ids,
        compact_bytes,
        elapsed_micros: started.elapsed().as_micros().min(u64::MAX as u128) as u64,
        condition_variables,
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn runtime_seek_menu(
    handle: u64,
    start_index: u32,
    bool_variables: HashMap<String, bool>,
    max_steps: u32,
) -> Result<RustMenuSeekResult, String> {
    let store = runtimes()
        .lock()
        .map_err(|_| "script runtime store is poisoned".to_string())?;
    let runtime = store
        .get(&handle)
        .ok_or_else(|| format!("unknown script runtime handle: {handle}"))?;
    let mut index = start_index;
    let mut visited_indices = HashSet::new();
    let mut prompts = Vec::new();
    let step_limit = max_steps.clamp(1, 100_000);

    while index < runtime.end_index && visited_indices.len() < step_limit as usize {
        if !visited_indices.insert(index) {
            break;
        }
        let Some(node) = runtime.nodes.get(&index) else {
            index = index.saturating_add(1);
            continue;
        };
        match node.kind.as_str() {
            "menu" => {
                return Ok(RustMenuSeekResult {
                    found: true,
                    menu_index: Some(index),
                    prompts,
                    visited: visited_indices.len().min(u32::MAX as usize) as u32,
                });
            }
            "return" => break,
            "jump" => {
                let condition_matches = match (&node.condition_variable, node.condition_value) {
                    (Some(variable), Some(expected)) => {
                        bool_variables.get(variable).copied().unwrap_or(false) == expected
                    }
                    _ => true,
                };
                if condition_matches {
                    let target = node
                        .value
                        .as_ref()
                        .and_then(|label| runtime.labels.get(label))
                        .copied();
                    let Some(target) = target else {
                        break;
                    };
                    index = target;
                    continue;
                }
            }
            "say" | "conditional_say" => {
                let condition_matches = match (&node.condition_variable, node.condition_value) {
                    (Some(variable), Some(expected)) => {
                        bool_variables.get(variable).copied().unwrap_or(false) == expected
                    }
                    _ => true,
                };
                if condition_matches {
                    prompts.push(RustRuntimePrompt {
                        dialogue: node.value.clone().unwrap_or_default(),
                        speaker: node.secondary.clone(),
                        dialogue_tag: node.dialogue_tag.clone(),
                        script_index: index,
                        source_file: node.source_file.clone(),
                        source_line: node.source_line,
                    });
                }
            }
            _ => {}
        }
        index = index.saturating_add(1);
    }

    Ok(RustMenuSeekResult {
        found: false,
        menu_index: None,
        prompts,
        visited: visited_indices.len().min(u32::MAX as usize) as u32,
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn close_script_runtime(handle: u64) -> Result<bool, String> {
    Ok(runtimes()
        .lock()
        .map_err(|_| "script runtime store is poisoned".to_string())?
        .remove(&handle)
        .is_some())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(index: u32, kind: &str, value: Option<&str>) -> RustRuntimeNode {
        RustRuntimeNode {
            script_index: index,
            kind: kind.into(),
            value: value.map(str::to_string),
            secondary: None,
            dialogue_tag: None,
            source_file: None,
            source_line: None,
            condition_variable: None,
            condition_value: None,
            choices: Vec::new(),
        }
    }

    #[test]
    fn builds_labels_chapters_and_branches() {
        let mut menu = node(3, "menu", None);
        menu.choices.push(RustRuntimeChoice {
            text: "A".into(),
            target_label: "route_a".into(),
        });
        let result = build_runtime_index(vec![
            node(0, "label", Some("start")),
            node(1, "background", Some("chapter1")),
            menu,
            node(4, "label", Some("route_a")),
            node(5, "jump", Some("merge")),
            node(6, "label", Some("route_b")),
            node(7, "jump", Some("merge")),
            node(8, "label", Some("merge")),
            node(9, "return", None),
        ])
        .unwrap();
        assert_eq!(result.labels.len(), 4);
        assert!(result.flow_nodes.iter().any(|node| node.id == "chapter_1"));
        assert!(result.flow_nodes.iter().any(|node| node.id == "branch_3"));
        assert!(result
            .flow_nodes
            .iter()
            .any(|node| node.id == "merge_merge"));
    }
}
