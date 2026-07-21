use crate::develop::SrgbImage;
use crate::tile::PixelTransform;

/// Global grading controls, expressed as normalized adjustments in `-1.0..=1.0`.
///
/// Values outside that range are clamped, and non-finite values are treated as
/// zero. The default value is an exact identity transform.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GradeParams {
    pub contrast: f32,
    pub highlights: f32,
    pub shadows: f32,
    pub whites: f32,
    pub blacks: f32,
    pub vibrance: f32,
    pub saturation: f32,
}

impl Default for GradeParams {
    fn default() -> Self {
        Self {
            contrast: 0.0,
            highlights: 0.0,
            shadows: 0.0,
            whites: 0.0,
            blacks: 0.0,
            vibrance: 0.0,
            saturation: 0.0,
        }
    }
}

impl GradeParams {
    #[must_use]
    pub fn is_identity(self) -> bool {
        let params = self.sanitized();
        params.contrast == 0.0
            && params.highlights == 0.0
            && params.shadows == 0.0
            && params.whites == 0.0
            && params.blacks == 0.0
            && params.vibrance == 0.0
            && params.saturation == 0.0
    }

    #[must_use]
    pub fn sanitized(self) -> Self {
        Self {
            contrast: sanitize_control(self.contrast),
            highlights: sanitize_control(self.highlights),
            shadows: sanitize_control(self.shadows),
            whites: sanitize_control(self.whites),
            blacks: sanitize_control(self.blacks),
            vibrance: sanitize_control(self.vibrance),
            saturation: sanitize_control(self.saturation),
        }
    }
}

impl PixelTransform for GradeParams {
    fn transform_rgb(&self, rgb: [f32; 3]) -> [f32; 3] {
        grade_rgb(rgb, self)
    }
}

/// Applies global grading to one display-referred RGB pixel.
///
/// Valid input channels are expected in `0.0..=1.0`. Output channels are
/// always finite and clamped to that range. With default parameters, valid
/// inputs are returned bit-for-bit unchanged.
#[must_use]
pub fn grade_rgb(rgb: [f32; 3], params: &GradeParams) -> [f32; 3] {
    let rgb = rgb.map(sanitize_channel);
    let params = params.sanitized();
    if params.is_identity() {
        return rgb;
    }

    let luminance = rgb_luminance(rgb);
    let graded_luminance = grade_luminance(luminance, params);
    let luminance_delta = graded_luminance - luminance;
    let toned = rgb.map(|channel| sanitize_channel(channel + luminance_delta));

    let toned_luminance = rgb_luminance(toned);
    let maximum = toned[0].max(toned[1]).max(toned[2]);
    let minimum = toned[0].min(toned[1]).min(toned[2]);
    let chroma = (maximum - minimum).clamp(0.0, 1.0);
    let saturation_scale = (1.0 + params.saturation).max(0.0);
    let vibrance_scale = (1.0 + params.vibrance * (1.0 - chroma)).max(0.0);
    let color_scale = saturation_scale * vibrance_scale;

    toned.map(|channel| {
        sanitize_channel(toned_luminance + (channel - toned_luminance) * color_scale)
    })
}

/// Applies global grading to an in-memory sRGB image.
///
/// This returns the source unchanged without touching its samples when the
/// parameters are the identity, which keeps the identity path bit-exact.
#[must_use]
pub fn grade_image(image: &SrgbImage, params: &GradeParams) -> SrgbImage {
    if params.is_identity() {
        return image.clone();
    }
    SrgbImage {
        data: image
            .data
            .chunks_exact(3)
            .flat_map(|pixel| grade_rgb([pixel[0], pixel[1], pixel[2]], params))
            .collect(),
        w: image.w,
        h: image.h,
    }
}

fn grade_luminance(luminance: f32, params: GradeParams) -> f32 {
    let mut value = luminance;

    // Contrast pivots around middle gray while retaining the black and white
    // endpoints. The smooth bell-shaped term avoids hard clipping for ordinary
    // adjustments and remains monotonic over the supported range.
    value += params.contrast * 2.0 * (value - 0.5) * value * (1.0 - value);

    // The remaining controls use smooth tonal masks. Each term naturally
    // approaches zero at the opposite end of the range, keeping adjustments
    // local enough for interactive global grading.
    let shadows_mask = (1.0 - value) * (1.0 - value);
    value += params.shadows * shadows_mask * value.max(0.125);

    let highlights_mask = value * value;
    value += params.highlights * highlights_mask * (1.0 - value).max(0.125);

    let black_mask = 1.0 - smoothstep(0.0, 0.5, value);
    value += params.blacks * black_mask * 0.25;

    let white_mask = smoothstep(0.5, 1.0, value);
    value += params.whites * white_mask * 0.25;

    sanitize_channel(value)
}

fn rgb_luminance(rgb: [f32; 3]) -> f32 {
    rgb[0].mul_add(0.2126, rgb[1].mul_add(0.7152, rgb[2] * 0.0722))
}

fn smoothstep(edge0: f32, edge1: f32, value: f32) -> f32 {
    let normalized = ((value - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    normalized * normalized * (3.0 - 2.0 * normalized)
}

fn sanitize_control(value: f32) -> f32 {
    if value.is_finite() {
        value.clamp(-1.0, 1.0)
    } else {
        0.0
    }
}

fn sanitize_channel(value: f32) -> f32 {
    if value.is_finite() {
        value.clamp(0.0, 1.0)
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_grade_is_bit_exact() {
        let pixels = [
            [0.0, 0.25, 1.0],
            [0.123_456_7, 0.765_432_1, 0.5],
            [-0.0, f32::MIN_POSITIVE, 1.0 - f32::EPSILON],
        ];
        for pixel in pixels {
            let output = grade_rgb(pixel, &GradeParams::default());
            for (actual, expected) in output.into_iter().zip(pixel) {
                assert_eq!(actual.to_bits(), expected.to_bits());
            }
        }
    }

    #[test]
    fn grading_preserves_neutral_pixels() {
        let params = GradeParams {
            contrast: 0.7,
            highlights: -0.4,
            shadows: 0.6,
            whites: 0.3,
            blacks: -0.2,
            vibrance: 0.9,
            saturation: 0.5,
        };
        for value in [0.0, 0.02, 0.18, 0.5, 0.9, 1.0] {
            let output = grade_rgb([value; 3], &params);
            assert_eq!(output[0].to_bits(), output[1].to_bits());
            assert_eq!(output[1].to_bits(), output[2].to_bits());
        }
    }

    #[test]
    fn grading_output_is_finite_and_bounded() {
        let params = GradeParams {
            contrast: f32::INFINITY,
            highlights: -10.0,
            shadows: 10.0,
            whites: f32::NAN,
            blacks: -f32::INFINITY,
            vibrance: 4.0,
            saturation: -4.0,
        };
        for pixel in [
            [f32::NAN, f32::INFINITY, f32::NEG_INFINITY],
            [-5.0, 0.5, 8.0],
            [0.1, 0.7, 0.2],
        ] {
            let output = grade_rgb(pixel, &params);
            assert!(
                output
                    .iter()
                    .all(|channel| channel.is_finite() && (0.0..=1.0).contains(channel))
            );
        }
    }
}
