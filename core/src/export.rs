//! FFmpeg subprocess orchestration for video export.
//!
//! Pipeline: decode source → apply zoom/style/cursor per frame → encode output.
//! Uses FFmpeg as a subprocess for both decode and encode.

use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};

use crate::compositor;
use crate::types::{ExportConfig, ExportError, ExportProgress};

/// Locate the ffmpeg binary on the system.
pub fn find_ffmpeg() -> Result<String, ExportError> {
    // Check common locations
    let candidates = ["ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"];

    for candidate in candidates {
        let result = Command::new("which").arg(candidate).output();
        if let Ok(output) = result {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if !path.is_empty() {
                    return Ok(path);
                }
            }
        }
    }

    // Try running ffmpeg directly
    if Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok()
    {
        return Ok("ffmpeg".to_string());
    }

    Err(ExportError::FfmpegNotFound {
        message: "FFmpeg not found. Install with: brew install ffmpeg".to_string(),
    })
}

/// Probe the source video to get duration, width, height, and fps.
pub fn probe_video(
    ffmpeg_path: &str,
    input_path: &str,
) -> Result<VideoInfo, ExportError> {
    let ffprobe = ffmpeg_path.replace("ffmpeg", "ffprobe");

    let output = Command::new(&ffprobe)
        .args([
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate,duration",
            "-show_entries", "format=duration",
            "-of", "csv=p=0:s=,",
            input_path,
        ])
        .output()
        .map_err(|e| ExportError::FfmpegNotFound {
            message: format!("Failed to run ffprobe: {}", e),
        })?;

    if !output.status.success() {
        return Err(ExportError::FfmpegFailed {
            message: format!(
                "ffprobe failed: {}",
                String::from_utf8_lossy(&output.stderr)
            ),
        });
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let lines: Vec<&str> = stdout.trim().lines().collect();

    // Parse stream info: width,height,r_frame_rate,duration
    let mut width = 1920u32;
    let mut height = 1080u32;
    let mut fps = 30.0f64;
    let mut duration_secs = 0.0f64;

    for line in &lines {
        let parts: Vec<&str> = line.split(',').collect();
        if parts.len() >= 3 {
            if let Ok(w) = parts[0].parse::<u32>() {
                width = w;
            }
            if let Ok(h) = parts[1].parse::<u32>() {
                height = h;
            }
            // r_frame_rate is like "30/1"
            if let Some((num, den)) = parts[2].split_once('/') {
                if let (Ok(n), Ok(d)) = (num.parse::<f64>(), den.parse::<f64>()) {
                    if d > 0.0 {
                        fps = n / d;
                    }
                }
            }
            if parts.len() >= 4 {
                if let Ok(d) = parts[3].parse::<f64>() {
                    duration_secs = d;
                }
            }
        }
        // Format duration line (single value)
        if parts.len() == 1 {
            if let Ok(d) = parts[0].parse::<f64>() {
                if duration_secs <= 0.0 {
                    duration_secs = d;
                }
            }
        }
    }

    Ok(VideoInfo {
        width,
        height,
        fps,
        duration_secs,
    })
}

#[derive(Debug, Clone)]
pub struct VideoInfo {
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    pub duration_secs: f64,
}

/// Build the FFmpeg filter complex string for the export pipeline.
///
/// Applies zoom (crop+scale), padding, background color, corner radius via
/// FFmpeg filter graph.
fn build_filter_complex(config: &ExportConfig, source_info: &VideoInfo) -> String {
    let style = &config.style_config;

    let (out_w, out_h) = compositor::compute_output_dimensions(
        source_info.width,
        source_info.height,
        style,
    );

    let output_w = if config.output_width > 0 {
        config.output_width
    } else {
        out_w
    };
    let output_h = if config.output_height > 0 {
        config.output_height
    } else {
        out_h
    };

    let padding = style.padding as u32;

    // Background color (solid only for FFmpeg filter; gradient handled differently)
    let bg_color = if style.background.bg_type == "solid" {
        style.background.hex.clone()
    } else if style.background.bg_type == "gradient" {
        style.background.gradient_from_hex.clone()
    } else {
        "#000000".to_string()
    };

    let corner_radius = style.corner_radius as u32;

    // Build filter chain
    let mut filters = Vec::new();

    // Scale source to fit within output minus padding
    let inner_w = output_w.saturating_sub(padding * 2);
    let inner_h = output_h.saturating_sub(padding * 2);
    filters.push(format!(
        "[0:v]scale={}:{}:force_original_aspect_ratio=decrease[scaled]",
        inner_w, inner_h
    ));

    // Apply corner radius with rounded corners mask
    if corner_radius > 0 {
        filters.push(format!(
            "[scaled]format=yuva420p,geq=lum='lum(X,Y)':a='if(gt(abs(X-W/2),W/2-{r})*gt(abs(Y-H/2),H/2-{r}),if(lte(hypot(abs(X-W/2)-W/2+{r},abs(Y-H/2)-H/2+{r}),{r}),255,0),255)'[rounded]",
            r = corner_radius
        ));
    } else {
        filters.push("[scaled]null[rounded]".to_string());
    }

    // Create background and overlay
    filters.push(format!(
        "color=c={}:s={}x{}:d=999[bg]",
        bg_color, output_w, output_h
    ));
    filters.push(format!(
        "[bg][rounded]overlay=(W-w)/2:(H-h)/2:shortest=1[out]",
    ));

    filters.join(";")
}

/// Build FFmpeg command arguments for export.
pub fn build_ffmpeg_args(
    _ffmpeg_path: &str,
    config: &ExportConfig,
    source_info: &VideoInfo,
) -> Vec<String> {
    let filter = build_filter_complex(config, source_info);

    let fps = if config.fps > 0 {
        config.fps
    } else {
        source_info.fps.round() as u32
    };

    let mut args = vec![
        "-y".to_string(),
        "-i".to_string(),
        config.input_video_path.clone(),
        "-filter_complex".to_string(),
        filter,
        "-map".to_string(),
        "[out]".to_string(),
        "-r".to_string(),
        fps.to_string(),
    ];

    // Format-specific encoding settings
    match config.format.format.as_str() {
        "gif" => {
            args.extend([
                "-f".to_string(),
                "gif".to_string(),
            ]);
        }
        "webm" => {
            args.extend([
                "-c:v".to_string(),
                "libvpx-vp9".to_string(),
                "-crf".to_string(),
                "30".to_string(),
                "-b:v".to_string(),
                "0".to_string(),
            ]);
        }
        _ => {
            // MP4 (default)
            args.extend([
                "-c:v".to_string(),
                "libx264".to_string(),
                "-preset".to_string(),
                "medium".to_string(),
                "-crf".to_string(),
                "18".to_string(),
                "-pix_fmt".to_string(),
                "yuv420p".to_string(),
            ]);
        }
    }

    // Copy audio if MP4/WebM
    if config.format.format != "gif" {
        args.extend([
            "-map".to_string(),
            "0:a?".to_string(),
            "-c:a".to_string(),
            "aac".to_string(),
        ]);
    }

    // Progress reporting
    args.extend(["-progress".to_string(), "pipe:2".to_string()]);

    args.push(config.output_path.clone());
    args
}

/// Run the export pipeline.
///
/// Spawns FFmpeg as a subprocess and reports progress via callback.
pub fn run_export(
    config: &ExportConfig,
    progress_callback: impl Fn(ExportProgress),
) -> Result<String, ExportError> {
    let ffmpeg_path = find_ffmpeg()?;

    progress_callback(ExportProgress {
        percent: 0.0,
        stage: "Analyzing source video...".to_string(),
    });

    let source_info = probe_video(&ffmpeg_path, &config.input_video_path)?;
    let total_duration_us = (source_info.duration_secs * 1_000_000.0) as u64;

    progress_callback(ExportProgress {
        percent: 5.0,
        stage: "Starting export...".to_string(),
    });

    let args = build_ffmpeg_args(&ffmpeg_path, config, &source_info);

    log::debug!("FFmpeg command: {} {}", ffmpeg_path, args.join(" "));

    let mut child = Command::new(&ffmpeg_path)
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| ExportError::FfmpegFailed {
            message: format!("Failed to spawn ffmpeg: {}", e),
        })?;

    // Parse progress from stderr
    if let Some(stderr) = child.stderr.take() {
        let reader = BufReader::new(stderr);
        for line in reader.lines() {
            let line = match line {
                Ok(l) => l,
                Err(_) => continue,
            };

            // FFmpeg progress format: out_time_us=<microseconds>
            if let Some(time_str) = line.strip_prefix("out_time_us=") {
                if let Ok(time_us) = time_str.trim().parse::<u64>() {
                    if total_duration_us > 0 {
                        let percent =
                            5.0 + (time_us as f64 / total_duration_us as f64) * 90.0;
                        progress_callback(ExportProgress {
                            percent: percent.min(95.0),
                            stage: "Encoding...".to_string(),
                        });
                    }
                }
            }
        }
    }

    let status = child.wait().map_err(|e| ExportError::FfmpegFailed {
        message: format!("Failed to wait for ffmpeg: {}", e),
    })?;

    if !status.success() {
        return Err(ExportError::FfmpegFailed {
            message: format!("FFmpeg exited with status: {}", status),
        });
    }

    progress_callback(ExportProgress {
        percent: 100.0,
        stage: "Export complete!".to_string(),
    });

    Ok(config.output_path.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::*;

    fn test_config() -> ExportConfig {
        ExportConfig {
            input_video_path: "/tmp/test.mov".to_string(),
            events_json_path: "/tmp/test.events.json".to_string(),
            output_path: "/tmp/test_output.mp4".to_string(),
            zoom_config: ZoomConfig::default(),
            style_config: StyleConfig::default(),
            cursor_config: CursorConfig::default(),
            output_width: 1920,
            output_height: 1080,
            fps: 30,
            format: OutputFormatConfig::default(),
        }
    }

    fn test_source_info() -> VideoInfo {
        VideoInfo {
            width: 1920,
            height: 1080,
            fps: 30.0,
            duration_secs: 10.0,
        }
    }

    #[test]
    fn build_ffmpeg_args_mp4() {
        let config = test_config();
        let info = test_source_info();
        let args = build_ffmpeg_args("ffmpeg", &config, &info);

        assert!(args.contains(&"-y".to_string()));
        assert!(args.contains(&"-i".to_string()));
        assert!(args.contains(&config.input_video_path));
        assert!(args.contains(&"-c:v".to_string()));
        assert!(args.contains(&"libx264".to_string()));
        assert!(args.contains(&config.output_path));
    }

    #[test]
    fn build_ffmpeg_args_gif() {
        let mut config = test_config();
        config.format = OutputFormatConfig {
            format: "gif".to_string(),
        };
        let info = test_source_info();
        let args = build_ffmpeg_args("ffmpeg", &config, &info);

        assert!(args.contains(&"-f".to_string()));
        assert!(args.contains(&"gif".to_string()));
        // GIF should not have audio
        assert!(!args.contains(&"-c:a".to_string()));
    }

    #[test]
    fn build_ffmpeg_args_webm() {
        let mut config = test_config();
        config.format = OutputFormatConfig {
            format: "webm".to_string(),
        };
        let info = test_source_info();
        let args = build_ffmpeg_args("ffmpeg", &config, &info);

        assert!(args.contains(&"libvpx-vp9".to_string()));
        assert!(args.contains(&"-c:a".to_string()));
    }

    #[test]
    fn build_filter_complex_includes_scale_and_overlay() {
        let config = test_config();
        let info = test_source_info();
        let filter = build_filter_complex(&config, &info);

        assert!(filter.contains("scale="));
        assert!(filter.contains("overlay="));
        assert!(filter.contains("color="));
    }

    #[test]
    fn build_filter_complex_with_corner_radius() {
        let mut config = test_config();
        config.style_config.corner_radius = 16.0;
        let info = test_source_info();
        let filter = build_filter_complex(&config, &info);

        assert!(filter.contains("geq="));
    }

    #[test]
    fn build_filter_complex_no_corner_radius() {
        let mut config = test_config();
        config.style_config.corner_radius = 0.0;
        let info = test_source_info();
        let filter = build_filter_complex(&config, &info);

        assert!(filter.contains("null"));
        assert!(!filter.contains("geq="));
    }

    #[test]
    fn build_ffmpeg_args_uses_config_fps() {
        let mut config = test_config();
        config.fps = 60;
        let info = test_source_info();
        let args = build_ffmpeg_args("ffmpeg", &config, &info);

        assert!(args.contains(&"60".to_string()));
    }

    #[test]
    fn build_ffmpeg_args_uses_source_fps_when_zero() {
        let mut config = test_config();
        config.fps = 0;
        let info = test_source_info();
        let args = build_ffmpeg_args("ffmpeg", &config, &info);

        assert!(args.contains(&"30".to_string()));
    }
}
