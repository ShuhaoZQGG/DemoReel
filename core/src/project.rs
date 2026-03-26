//! .demoreel project file format.
//!
//! Handles serialization/deserialization of project state including
//! references to recordings, events, and user settings.

use std::fs;
use std::path::Path;

use crate::types::{ProjectError, ProjectFile};

/// Save a project to a .demoreel JSON file.
pub fn save_project(project: &ProjectFile, path: &str) -> Result<(), ProjectError> {
    let json = serde_json::to_string_pretty(project)?;
    fs::write(path, json)?;
    Ok(())
}

/// Load a project from a .demoreel JSON file.
pub fn load_project(path: &str) -> Result<ProjectFile, ProjectError> {
    if !Path::new(path).exists() {
        return Err(ProjectError::IoError {
            message: format!("File not found: {}", path),
        });
    }
    let json = fs::read_to_string(path)?;
    let project: ProjectFile = serde_json::from_str(&json)?;
    if project.version == 0 {
        return Err(ProjectError::InvalidProject {
            message: "Project version must be > 0".to_string(),
        });
    }
    Ok(project)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    fn sample_project() -> ProjectFile {
        ProjectFile {
            version: 1,
            name: "Test Project".to_string(),
            created_at: "2026-03-26T12:00:00Z".to_string(),
            video_path: "/tmp/recording.mov".to_string(),
            events_path: "/tmp/recording.events.json".to_string(),
            zoom_scale: 2.0,
            zoom_ease_in_ms: 300,
            zoom_hold_ms: 600,
            zoom_ease_out_ms: 400,
            zoom_merge_threshold_ms: 300,
            zoom_enabled: true,
            bg_type: "solid".to_string(),
            bg_hex: "#1a1a2e".to_string(),
            bg_gradient_from_hex: "#667eea".to_string(),
            bg_gradient_to_hex: "#764ba2".to_string(),
            bg_gradient_angle: 135.0,
            padding: 32.0,
            corner_radius: 12.0,
            shadow_enabled: true,
            shadow_intensity: 0.5,
            aspect_ratio: "landscape_16x9".to_string(),
            cursor_style: "circle".to_string(),
            cursor_size_multiplier: 1.0,
            cursor_click_highlight: true,
            cursor_highlight_color_hex: "#3b82f6".to_string(),
            trim_start_ms: 0,
            trim_end_ms: 15000,
        }
    }

    #[test]
    fn save_and_load_roundtrip() {
        let project = sample_project();
        let dir = env::temp_dir().join("demoreel_test");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("test.demoreel");
        let path_str = path.to_str().unwrap();

        save_project(&project, path_str).unwrap();
        let loaded = load_project(path_str).unwrap();

        assert_eq!(loaded.version, 1);
        assert_eq!(loaded.name, "Test Project");
        assert_eq!(loaded.video_path, "/tmp/recording.mov");
        assert_eq!(loaded.zoom_scale, 2.0);
        assert_eq!(loaded.bg_type, "solid");
        assert_eq!(loaded.padding, 32.0);
        assert_eq!(loaded.cursor_style, "circle");
        assert_eq!(loaded.trim_start_ms, 0);
        assert_eq!(loaded.trim_end_ms, 15000);

        fs::remove_file(path).unwrap();
        let _ = fs::remove_dir(dir);
    }

    #[test]
    fn load_nonexistent_file_returns_error() {
        let result = load_project("/tmp/nonexistent_demoreel_test_file.demoreel");
        assert!(result.is_err());
        match result.unwrap_err() {
            ProjectError::IoError { message } => {
                assert!(message.contains("not found"));
            }
            _ => panic!("Expected IoError"),
        }
    }

    #[test]
    fn load_invalid_json_returns_error() {
        let dir = env::temp_dir().join("demoreel_test");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("invalid.demoreel");
        fs::write(&path, "not valid json").unwrap();

        let result = load_project(path.to_str().unwrap());
        assert!(result.is_err());
        match result.unwrap_err() {
            ProjectError::ParseError { .. } => {}
            _ => panic!("Expected ParseError"),
        }

        fs::remove_file(path).unwrap();
        let _ = fs::remove_dir(dir);
    }

    #[test]
    fn load_version_zero_returns_error() {
        let mut project = sample_project();
        project.version = 0;
        let dir = env::temp_dir().join("demoreel_test");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v0.demoreel");
        let json = serde_json::to_string(&project).unwrap();
        fs::write(&path, json).unwrap();

        let result = load_project(path.to_str().unwrap());
        assert!(result.is_err());
        match result.unwrap_err() {
            ProjectError::InvalidProject { .. } => {}
            _ => panic!("Expected InvalidProject"),
        }

        fs::remove_file(path).unwrap();
        let _ = fs::remove_dir(dir);
    }

    #[test]
    fn saved_file_is_valid_json() {
        let project = sample_project();
        let dir = env::temp_dir().join("demoreel_test");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("json_check.demoreel");
        let path_str = path.to_str().unwrap();

        save_project(&project, path_str).unwrap();

        let contents = fs::read_to_string(&path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&contents).unwrap();
        assert_eq!(parsed["version"], 1);
        assert_eq!(parsed["name"], "Test Project");

        fs::remove_file(path).unwrap();
        let _ = fs::remove_dir(dir);
    }
}
