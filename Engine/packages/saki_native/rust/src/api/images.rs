use std::fs;
use std::path::Path;

#[derive(Clone, Debug)]
pub struct RustImageMetadata {
    pub path: String,
    pub width: u32,
    pub height: u32,
    pub decoded_rgba_bytes: u64,
    pub file_bytes: u64,
    pub format: String,
    pub error: Option<String>,
}

fn inspect_one(path: String) -> RustImageMetadata {
    let file_bytes = fs::metadata(&path).map(|value| value.len()).unwrap_or(0);
    let format = Path::new(&path)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    match imagesize::size(&path) {
        Ok(size) => {
            let width = size.width.min(u32::MAX as usize) as u32;
            let height = size.height.min(u32::MAX as usize) as u32;
            RustImageMetadata {
                path,
                width,
                height,
                decoded_rgba_bytes: u64::from(width)
                    .saturating_mul(u64::from(height))
                    .saturating_mul(4),
                file_bytes,
                format,
                error: None,
            }
        }
        Err(error) => RustImageMetadata {
            path,
            width: 0,
            height: 0,
            decoded_rgba_bytes: 0,
            file_bytes,
            format,
            error: Some(error.to_string()),
        },
    }
}

pub fn inspect_image_files(paths: Vec<String>) -> Vec<RustImageMetadata> {
    paths.into_iter().map(inspect_one).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_missing_images_without_panicking() {
        let result = inspect_image_files(vec!["/definitely/missing/image.png".into()]);
        assert_eq!(result.len(), 1);
        assert!(result[0].error.is_some());
    }

    #[test]
    fn inspects_external_fixture_when_configured() {
        let Ok(path) = std::env::var("SAKI_TEST_IMAGE") else {
            return;
        };
        let result = inspect_image_files(vec![path]);
        assert_eq!(result.len(), 1);
        assert!(result[0].error.is_none());
        assert!(result[0].width > 0);
        assert!(result[0].height > 0);
        assert!(result[0].decoded_rgba_bytes > 0);
    }
}
