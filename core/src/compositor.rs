use crate::types::StyleConfig;

/// Compute the output canvas dimensions given source video size and style config.
///
/// Applies padding and aspect ratio to determine the final canvas.
pub fn compute_output_dimensions(
    source_width: u32,
    source_height: u32,
    style: &StyleConfig,
) -> (u32, u32) {
    let padding = style.padding as u32 * 2;
    let video_w = source_width + padding;
    let video_h = source_height + padding;

    match style.aspect_ratio.aspect_value() {
        Some(target_ratio) => {
            let current_ratio = video_w as f64 / video_h as f64;
            if current_ratio > target_ratio {
                // Too wide — increase height
                let new_h = (video_w as f64 / target_ratio).ceil() as u32;
                (video_w, new_h)
            } else {
                // Too tall — increase width
                let new_w = (video_h as f64 * target_ratio).ceil() as u32;
                (new_w, video_h)
            }
        }
        None => (video_w, video_h), // "auto"
    }
}

/// Parse a hex color string into (r, g, b, a) components.
///
/// Supports formats: "#RGB", "#RRGGBB", "#RRGGBBAA"
pub fn parse_hex_color(hex: &str) -> Result<(u8, u8, u8, u8), String> {
    let hex = hex.trim_start_matches('#');

    match hex.len() {
        3 => {
            let r = u8::from_str_radix(&hex[0..1], 16).map_err(|e| e.to_string())? * 17;
            let g = u8::from_str_radix(&hex[1..2], 16).map_err(|e| e.to_string())? * 17;
            let b = u8::from_str_radix(&hex[2..3], 16).map_err(|e| e.to_string())? * 17;
            Ok((r, g, b, 255))
        }
        6 => {
            let r = u8::from_str_radix(&hex[0..2], 16).map_err(|e| e.to_string())?;
            let g = u8::from_str_radix(&hex[2..4], 16).map_err(|e| e.to_string())?;
            let b = u8::from_str_radix(&hex[4..6], 16).map_err(|e| e.to_string())?;
            Ok((r, g, b, 255))
        }
        8 => {
            let r = u8::from_str_radix(&hex[0..2], 16).map_err(|e| e.to_string())?;
            let g = u8::from_str_radix(&hex[2..4], 16).map_err(|e| e.to_string())?;
            let b = u8::from_str_radix(&hex[4..6], 16).map_err(|e| e.to_string())?;
            let a = u8::from_str_radix(&hex[6..8], 16).map_err(|e| e.to_string())?;
            Ok((r, g, b, a))
        }
        _ => Err(format!("Invalid hex color length: {}", hex.len())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::AspectRatioConfig;

    fn style_with_padding_and_ratio(padding: f64, ratio: &str) -> StyleConfig {
        StyleConfig {
            padding,
            aspect_ratio: AspectRatioConfig {
                ratio: ratio.to_string(),
            },
            ..StyleConfig::default()
        }
    }

    #[test]
    fn auto_aspect_adds_padding_only() {
        let (w, h) = compute_output_dimensions(1920, 1080, &style_with_padding_and_ratio(32.0, "auto"));
        assert_eq!(w, 1984); // 1920 + 64
        assert_eq!(h, 1144); // 1080 + 64
    }

    #[test]
    fn landscape_16x9_widens_if_needed() {
        // Source is 4:3 (800x600) + 0 padding → current ratio 1.33, target 1.78
        let (w, h) = compute_output_dimensions(800, 600, &style_with_padding_and_ratio(0.0, "landscape_16x9"));
        // Should widen: new_w = 600 * (16/9) = 1067
        assert_eq!(h, 600);
        assert!(w > 800);
    }

    #[test]
    fn square_aspect_ratio() {
        let (w, h) = compute_output_dimensions(1920, 1080, &style_with_padding_and_ratio(0.0, "square_1x1"));
        // 1920x1080 → too wide for square, increase height
        assert_eq!(w, 1920);
        assert_eq!(h, 1920);
    }

    #[test]
    fn portrait_9x16() {
        let (w, h) = compute_output_dimensions(1920, 1080, &style_with_padding_and_ratio(0.0, "portrait_9x16"));
        // 1920x1080 → target ratio 0.5625, current 1.78 → way too wide, increase height
        assert_eq!(w, 1920);
        assert!(h > 1080);
    }

    #[test]
    fn zero_padding() {
        let (w, h) = compute_output_dimensions(1920, 1080, &style_with_padding_and_ratio(0.0, "auto"));
        assert_eq!(w, 1920);
        assert_eq!(h, 1080);
    }

    #[test]
    fn parse_hex_6_digit() {
        assert_eq!(parse_hex_color("#1a1a2e").unwrap(), (26, 26, 46, 255));
    }

    #[test]
    fn parse_hex_3_digit() {
        assert_eq!(parse_hex_color("#fff").unwrap(), (255, 255, 255, 255));
    }

    #[test]
    fn parse_hex_8_digit_with_alpha() {
        assert_eq!(parse_hex_color("#ff000080").unwrap(), (255, 0, 0, 128));
    }

    #[test]
    fn parse_hex_no_hash() {
        assert_eq!(parse_hex_color("3b82f6").unwrap(), (59, 130, 246, 255));
    }

    #[test]
    fn parse_hex_invalid() {
        assert!(parse_hex_color("#xyz").is_err());
        assert!(parse_hex_color("#12345").is_err());
    }

    #[test]
    fn default_style_config_is_valid() {
        let style = StyleConfig::default();
        assert_eq!(style.padding, 32.0);
        assert_eq!(style.corner_radius, 12.0);
        assert!(style.shadow_enabled);
        assert_eq!(style.background.bg_type, "solid");
        let color = parse_hex_color(&style.background.hex);
        assert!(color.is_ok());
    }
}
