use crate::decode::LinearImage;

#[derive(Debug, Clone, PartialEq)]
pub struct SrgbImage {
    pub data: Vec<f32>,
    pub w: usize,
    pub h: usize,
}

impl SrgbImage {
    pub fn new(data: Vec<f32>, w: usize, h: usize) -> anyhow::Result<Self> {
        anyhow::ensure!(w > 0 && h > 0, "image dimensions must be greater than zero");
        anyhow::ensure!(
            data.len() == w * h * 3,
            "image data length does not match dimensions"
        );
        anyhow::ensure!(
            data.iter().all(|value| value.is_finite()),
            "image contains NaN or infinity"
        );
        Ok(Self { data, w, h })
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WhiteBalance {
    pub red: f32,
    pub green: f32,
    pub blue: f32,
}

impl Default for WhiteBalance {
    fn default() -> Self {
        Self {
            red: 1.0,
            green: 1.0,
            blue: 1.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BaseCurve {
    Srgb,
    Filmic { contrast: f32 },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DevelopParams {
    pub wb: WhiteBalance,
    pub exposure_ev: f32,
    pub curve: BaseCurve,
}

impl Default for DevelopParams {
    fn default() -> Self {
        Self {
            wb: WhiteBalance::default(),
            exposure_ev: 0.0,
            curve: BaseCurve::Srgb,
        }
    }
}

#[must_use]
pub fn develop(img: &LinearImage, params: &DevelopParams) -> SrgbImage {
    let exposure = 2.0_f32.powf(params.exposure_ev.clamp(-20.0, 20.0));
    let multipliers = [params.wb.red, params.wb.green, params.wb.blue];
    let mut output = Vec::with_capacity(img.data.len());

    for (index, value) in img.data.iter().enumerate() {
        let linear = (value * multipliers[index % 3].max(0.0) * exposure).clamp(0.0, 1.0);
        let curved = match params.curve {
            BaseCurve::Srgb => linear,
            BaseCurve::Filmic { contrast } => filmic_contrast(linear, contrast),
        };
        output.push(linear_to_srgb(curved));
    }

    SrgbImage {
        data: output,
        w: img.w,
        h: img.h,
    }
}

#[must_use]
pub fn linear_to_srgb(value: f32) -> f32 {
    let value = value.clamp(0.0, 1.0);
    if value <= 0.003_130_8 {
        value * 12.92
    } else {
        1.055 * value.powf(1.0 / 2.4) - 0.055
    }
}

fn filmic_contrast(value: f32, contrast: f32) -> f32 {
    let contrast = contrast.clamp(0.25, 4.0);
    if value <= 0.0 || value >= 1.0 {
        return value;
    }
    let raised = value.powf(contrast);
    raised / (raised + (1.0 - value).powf(contrast))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn develop_preserves_neutral_gray() {
        let input = LinearImage::new(vec![0.18, 0.18, 0.18, 0.5, 0.5, 0.5], 2, 1).unwrap();
        let output = develop(&input, &DevelopParams::default());
        for pixel in output.data.chunks_exact(3) {
            assert!((pixel[0] - pixel[1]).abs() < 1.0e-4);
            assert!((pixel[1] - pixel[2]).abs() < 1.0e-4);
        }
    }

    #[test]
    fn srgb_transfer_matches_reference_value() {
        assert!((linear_to_srgb(0.5) - 0.735_357).abs() < 1.0e-5);
    }

    #[test]
    fn exposure_and_white_balance_are_applied_in_linear_space() {
        let input = LinearImage::new(vec![0.1, 0.1, 0.1], 1, 1).unwrap();
        let params = DevelopParams {
            wb: WhiteBalance {
                red: 2.0,
                green: 1.0,
                blue: 0.5,
            },
            exposure_ev: 1.0,
            curve: BaseCurve::Srgb,
        };
        let output = develop(&input, &params);
        assert!((output.data[0] - linear_to_srgb(0.4)).abs() < 1.0e-6);
        assert!((output.data[1] - linear_to_srgb(0.2)).abs() < 1.0e-6);
        assert!((output.data[2] - linear_to_srgb(0.1)).abs() < 1.0e-6);
    }

    #[test]
    fn filmic_curve_is_monotonic_and_midpoint_preserving() {
        let values = [0.1, 0.25, 0.5, 0.75, 0.9];
        let mapped: Vec<f32> = values
            .into_iter()
            .map(|value| filmic_contrast(value, 1.4))
            .collect();
        assert!(mapped.windows(2).all(|window| window[0] < window[1]));
        assert!((mapped[2] - 0.5).abs() < f32::EPSILON);
    }
}
