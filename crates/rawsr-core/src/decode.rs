use std::io::Cursor;
use std::path::Path;

use anyhow::{Context, Result, bail, ensure};
use image::{DynamicImage, GenericImageView, ImageFormat, ImageReader};
use rawler::imgop::matrix::{multiply, normalize, pseudo_inverse};
use rawler::imgop::xyz::{Illuminant, SRGB_TO_XYZ_D65};
use rawler::rawimage::{RawImageData, RawPhotometricInterpretation};
use rawler::{decoders::RawDecodeParams, rawsource::RawSource};
use rayon::prelude::*;

#[derive(Debug, Clone, PartialEq)]
pub struct BasicExif {
    pub make: String,
    pub model: String,
    pub lens_model: Option<String>,
    pub iso: Option<u32>,
    pub exposure_seconds: Option<f32>,
    pub aperture: Option<f32>,
    pub focal_length_mm: Option<f32>,
    pub captured_at: Option<String>,
    pub orientation: Option<u16>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct EmbeddedThumbnail {
    pub jpeg: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub exif: BasicExif,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LinearImage {
    pub data: Vec<f32>,
    pub w: usize,
    pub h: usize,
}

impl LinearImage {
    pub fn new(data: Vec<f32>, w: usize, h: usize) -> Result<Self> {
        ensure!(w > 0 && h > 0, "image dimensions must be greater than zero");
        ensure!(
            data.len() == w * h * 3,
            "image data length does not match dimensions"
        );
        ensure!(
            data.iter().all(|value| value.is_finite()),
            "image contains NaN or infinity"
        );
        Ok(Self { data, w, h })
    }

    #[must_use]
    #[allow(clippy::cast_precision_loss)]
    pub fn mean(&self) -> f32 {
        self.data.iter().sum::<f32>() / self.data.len() as f32
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RawMeta {
    pub make: String,
    pub model: String,
    pub clean_make: String,
    pub clean_model: String,
    pub sensor_w: usize,
    pub sensor_h: usize,
    pub active_x: usize,
    pub active_y: usize,
    pub cfa_pattern: String,
    pub black_levels: Vec<f32>,
    pub white_levels: Vec<f32>,
    pub wb_multipliers: [f32; 3],
    pub camera_to_srgb: [[f32; 3]; 3],
}

pub fn extract_thumbnail(path: &Path) -> Result<EmbeddedThumbnail> {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    if rawler::decoders::supported_extensions()
        .iter()
        .any(|supported| supported.eq_ignore_ascii_case(extension))
    {
        return extract_raw_thumbnail(path);
    }

    let decoded = ImageReader::open(path)
        .with_context(|| format!("failed to open image {}", path.display()))?
        .with_guessed_format()
        .with_context(|| format!("failed to detect image format for {}", path.display()))?
        .decode()
        .with_context(|| format!("failed to decode image {}", path.display()))?;
    let thumbnail = decoded.thumbnail(512, 512);
    encode_thumbnail(
        &thumbnail,
        BasicExif {
            make: String::new(),
            model: String::new(),
            lens_model: None,
            iso: None,
            exposure_seconds: None,
            aperture: None,
            focal_length_mm: None,
            captured_at: None,
            orientation: None,
        },
    )
}

fn extract_raw_thumbnail(path: &Path) -> Result<EmbeddedThumbnail> {
    let source = RawSource::new(path)
        .with_context(|| format!("failed to open RAW source {}", path.display()))?;
    let decoder = rawler::get_decoder(&source)
        .with_context(|| format!("failed to select RAW decoder for {}", path.display()))?;
    let params = RawDecodeParams::default();
    let metadata = decoder
        .raw_metadata(&source, &params)
        .with_context(|| format!("failed to read RAW metadata from {}", path.display()))?;
    let preview = decoder
        .full_image(&source, &params)
        .with_context(|| format!("failed to extract embedded JPEG from {}", path.display()))?
        .or_else(|| decoder.thumbnail_image(&source, &params).ok().flatten())
        .or_else(|| decoder.preview_image(&source, &params).ok().flatten())
        .with_context(|| format!("RAW file {} has no embedded JPEG preview", path.display()))?;
    let exif = metadata.exif;
    let iso = exif
        .iso_speed
        .or(exif.recommended_exposure_index)
        .or(exif.iso_speed_ratings.map(u32::from));
    encode_thumbnail(
        &preview,
        BasicExif {
            make: metadata.make,
            model: metadata.model,
            lens_model: exif.lens_model,
            iso,
            exposure_seconds: exif.exposure_time.map(|value| value.as_f32()),
            aperture: exif.fnumber.map(|value| value.as_f32()),
            focal_length_mm: exif.focal_length.map(|value| value.as_f32()),
            captured_at: exif.date_time_original.or(exif.create_date),
            orientation: exif.orientation,
        },
    )
}

fn encode_thumbnail(image: &DynamicImage, exif: BasicExif) -> Result<EmbeddedThumbnail> {
    let (width, height) = image.dimensions();
    ensure!(
        width > 0 && height > 0,
        "thumbnail dimensions must be non-zero"
    );
    let mut jpeg = Vec::new();
    image
        .write_to(&mut Cursor::new(&mut jpeg), ImageFormat::Jpeg)
        .context("failed to encode thumbnail as JPEG")?;
    ensure!(!jpeg.is_empty(), "encoded thumbnail is empty");
    Ok(EmbeddedThumbnail {
        jpeg,
        width,
        height,
        exif,
    })
}

pub fn decode_raw(path: &Path) -> Result<(LinearImage, RawMeta)> {
    let mut raw = rawler::decode_file(path)
        .with_context(|| format!("failed to decode RAW file {}", path.display()))?;
    ensure!(
        raw.cpp == 1,
        "only single-plane Bayer RAW files are supported, got {} planes",
        raw.cpp
    );

    let cfa = match &raw.photometric {
        RawPhotometricInterpretation::Cfa(config)
            if config.cfa.is_rgb() && config.cfa.width == 2 && config.cfa.height == 2 =>
        {
            config.cfa.clone()
        }
        RawPhotometricInterpretation::Cfa(config) => {
            bail!(
                "only 2x2 RGB Bayer mosaics are supported, got {}",
                config.cfa.name
            )
        }
        interpretation => {
            bail!("RAW photometric interpretation {interpretation:?} is not a Bayer mosaic")
        }
    };

    let sensor_w = raw.width;
    let sensor_h = raw.height;
    let (active_x, active_y, active_w, active_h) = raw
        .active_area
        .as_ref()
        .map_or((0, 0, raw.width, raw.height), |area| {
            (area.p.x, area.p.y, area.d.w, area.d.h)
        });
    let active_right = active_x
        .checked_add(active_w)
        .context("RAW active area x extent overflowed")?;
    let active_bottom = active_y
        .checked_add(active_h)
        .context("RAW active area y extent overflowed")?;
    ensure!(
        active_right <= raw.width && active_bottom <= raw.height,
        "RAW active area lies outside sensor bounds"
    );

    let black_levels = raw.blacklevel.as_vec();
    let white_levels = raw.whitelevel.as_vec();
    let wb_multipliers = normalize_white_balance(raw.wb_coeffs);
    let camera_to_srgb = camera_to_srgb_matrix(&raw)?;

    raw.apply_scaling()
        .context("failed to subtract RAW black level and normalize white level")?;
    let scaled = match &raw.data {
        RawImageData::Float(data) => data,
        RawImageData::Integer(_) => {
            bail!("rawler did not return normalized floating-point samples")
        }
    };

    let mut mosaic = Vec::with_capacity(active_w * active_h);
    for y in active_y..active_bottom {
        let row_start = y * raw.width + active_x;
        mosaic.extend_from_slice(&scaled[row_start..row_start + active_w]);
    }

    let active_cfa = cfa.shift(active_x, active_y);
    let mut rgb = demosaic_malvar(&mosaic, active_w, active_h, &active_cfa)?;
    for pixel in rgb.chunks_exact_mut(3) {
        let camera_rgb = [
            pixel[0] * wb_multipliers[0],
            pixel[1] * wb_multipliers[1],
            pixel[2] * wb_multipliers[2],
        ];
        let srgb = [
            camera_to_srgb[0][0] * camera_rgb[0]
                + camera_to_srgb[0][1] * camera_rgb[1]
                + camera_to_srgb[0][2] * camera_rgb[2],
            camera_to_srgb[1][0] * camera_rgb[0]
                + camera_to_srgb[1][1] * camera_rgb[1]
                + camera_to_srgb[1][2] * camera_rgb[2],
            camera_to_srgb[2][0] * camera_rgb[0]
                + camera_to_srgb[2][1] * camera_rgb[1]
                + camera_to_srgb[2][2] * camera_rgb[2],
        ];
        pixel.copy_from_slice(&clip_color_preserving(srgb));
    }

    let image = LinearImage::new(rgb, active_w, active_h)?;
    let meta = RawMeta {
        make: raw.make,
        model: raw.model,
        clean_make: raw.clean_make,
        clean_model: raw.clean_model,
        sensor_w,
        sensor_h,
        active_x,
        active_y,
        cfa_pattern: active_cfa.name,
        black_levels,
        white_levels,
        wb_multipliers,
        camera_to_srgb,
    };
    Ok((image, meta))
}

pub fn decode_std(path: &Path) -> Result<LinearImage> {
    let decoded = ImageReader::open(path)
        .with_context(|| format!("failed to open image {}", path.display()))?
        .with_guessed_format()
        .with_context(|| format!("failed to detect image format for {}", path.display()))?
        .decode()
        .with_context(|| format!("failed to decode image {}", path.display()))?;
    let rgb = decoded.to_rgb32f();
    let (width, height) = rgb.dimensions();
    let w = usize::try_from(width).context("image width does not fit usize")?;
    let h = usize::try_from(height).context("image height does not fit usize")?;
    let data = rgb.into_raw().into_iter().map(srgb_to_linear).collect();
    LinearImage::new(data, w, h)
}

#[must_use]
pub fn srgb_to_linear(value: f32) -> f32 {
    let value = value.clamp(0.0, 1.0);
    if value <= 0.040_45 {
        value / 12.92
    } else {
        ((value + 0.055) / 1.055).powf(2.4)
    }
}

fn normalize_white_balance(coefficients: [f32; 4]) -> [f32; 3] {
    let green = coefficients[1];
    if coefficients[..3]
        .iter()
        .all(|value| value.is_finite() && *value > 0.0)
        && green > f32::EPSILON
    {
        [coefficients[0] / green, 1.0, coefficients[2] / green]
    } else {
        [1.0; 3]
    }
}

fn camera_to_srgb_matrix(raw: &rawler::RawImage) -> Result<[[f32; 3]; 3]> {
    let color_matrix = raw
        .color_matrix
        .iter()
        .find(|(illuminant, _)| **illuminant == Illuminant::D65)
        .or_else(|| raw.color_matrix.iter().next())
        .map(|(_, matrix)| matrix.as_slice());

    let mut xyz_to_camera = [[0.0; 3]; 3];
    if let Some(matrix) = color_matrix {
        ensure!(
            matrix.len() >= 9,
            "camera color matrix has {} values, expected at least 9",
            matrix.len()
        );
        for row in 0..3 {
            xyz_to_camera[row].copy_from_slice(&matrix[row * 3..row * 3 + 3]);
        }
    } else {
        for (destination, source) in xyz_to_camera.iter_mut().zip(raw.xyz_to_cam.iter()) {
            *destination = *source;
        }
    }

    let rgb_to_camera = normalize(multiply(&xyz_to_camera, &SRGB_TO_XYZ_D65));
    let camera_to_srgb = pseudo_inverse(rgb_to_camera);
    ensure!(
        camera_to_srgb
            .iter()
            .flatten()
            .all(|value| value.is_finite()),
        "camera color matrix could not be inverted"
    );
    Ok(camera_to_srgb)
}

fn clip_color_preserving(rgb: [f32; 3]) -> [f32; 3] {
    let rgb = rgb.map(|value| value.max(0.0));
    let maximum = rgb.into_iter().reduce(f32::max).unwrap_or(0.0);
    if maximum <= 1.0 {
        return rgb;
    }

    let normalized = rgb.map(|value| value / maximum);
    let norm = (rgb.iter().map(|value| value * value).sum::<f32>() / 3.0).sqrt();
    normalized.map(|value| ((value + norm) * 0.5).clamp(0.0, 1.0))
}

const GREEN_AT_RED_OR_BLUE: [[f32; 5]; 5] = [
    [0.0, 0.0, -1.0, 0.0, 0.0],
    [0.0, 0.0, 2.0, 0.0, 0.0],
    [-1.0, 2.0, 4.0, 2.0, -1.0],
    [0.0, 0.0, 2.0, 0.0, 0.0],
    [0.0, 0.0, -1.0, 0.0, 0.0],
];

const RED_OR_BLUE_AT_GREEN_HORIZONTAL: [[f32; 5]; 5] = [
    [0.0, 0.0, 0.5, 0.0, 0.0],
    [0.0, -1.0, 0.0, -1.0, 0.0],
    [-1.0, 4.0, 5.0, 4.0, -1.0],
    [0.0, -1.0, 0.0, -1.0, 0.0],
    [0.0, 0.0, 0.5, 0.0, 0.0],
];

const RED_AT_BLUE_OR_BLUE_AT_RED: [[f32; 5]; 5] = [
    [0.0, 0.0, -1.5, 0.0, 0.0],
    [0.0, 2.0, 0.0, 2.0, 0.0],
    [-1.5, 0.0, 6.0, 0.0, -1.5],
    [0.0, 2.0, 0.0, 2.0, 0.0],
    [0.0, 0.0, -1.5, 0.0, 0.0],
];

fn demosaic_malvar(
    mosaic: &[f32],
    width: usize,
    height: usize,
    cfa: &rawler::CFA,
) -> Result<Vec<f32>> {
    ensure!(
        width > 0 && height > 0,
        "mosaic dimensions must be greater than zero"
    );
    ensure!(
        mosaic.len() == width * height,
        "mosaic data length does not match dimensions"
    );
    ensure!(
        cfa.width == 2 && cfa.height == 2 && cfa.is_rgb(),
        "Malvar demosaic requires a 2x2 RGB Bayer pattern"
    );

    let mut output = vec![0.0; width * height * 3];
    output
        .par_chunks_mut(width * 3)
        .enumerate()
        .for_each(|(y, output_row)| {
            for x in 0..width {
                let sample = mosaic[y * width + x];
                let color = cfa.color_at(y, x);
                let (red, green, blue) = match color {
                    rawler::cfa::CFA_COLOR_R => (
                        sample,
                        filter_5x5(mosaic, width, height, x, y, &GREEN_AT_RED_OR_BLUE),
                        filter_5x5(mosaic, width, height, x, y, &RED_AT_BLUE_OR_BLUE_AT_RED),
                    ),
                    rawler::cfa::CFA_COLOR_G => {
                        let red_is_horizontal = cfa.color_at(y, x + 1) == rawler::cfa::CFA_COLOR_R;
                        let horizontal = filter_5x5(
                            mosaic,
                            width,
                            height,
                            x,
                            y,
                            &RED_OR_BLUE_AT_GREEN_HORIZONTAL,
                        );
                        let vertical = filter_5x5_transposed(
                            mosaic,
                            width,
                            height,
                            x,
                            y,
                            &RED_OR_BLUE_AT_GREEN_HORIZONTAL,
                        );
                        if red_is_horizontal {
                            (horizontal, sample, vertical)
                        } else {
                            (vertical, sample, horizontal)
                        }
                    }
                    rawler::cfa::CFA_COLOR_B => (
                        filter_5x5(mosaic, width, height, x, y, &RED_AT_BLUE_OR_BLUE_AT_RED),
                        filter_5x5(mosaic, width, height, x, y, &GREEN_AT_RED_OR_BLUE),
                        sample,
                    ),
                    other => {
                        unreachable!("validated RGB Bayer pattern returned color index {other}")
                    }
                };
                let offset = x * 3;
                output_row[offset] = red.clamp(0.0, 1.0);
                output_row[offset + 1] = green.clamp(0.0, 1.0);
                output_row[offset + 2] = blue.clamp(0.0, 1.0);
            }
        });
    Ok(output)
}

fn filter_5x5(
    mosaic: &[f32],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    kernel: &[[f32; 5]; 5],
) -> f32 {
    let mut sum = 0.0;
    for (kernel_y, row) in kernel.iter().enumerate() {
        let sample_y = offset_clamped(y, kernel_y, height);
        for (kernel_x, weight) in row.iter().enumerate() {
            let sample_x = offset_clamped(x, kernel_x, width);
            sum += mosaic[sample_y * width + sample_x] * weight;
        }
    }
    sum / 8.0
}

fn filter_5x5_transposed(
    mosaic: &[f32],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    kernel: &[[f32; 5]; 5],
) -> f32 {
    let mut sum = 0.0;
    for kernel_y in 0..5 {
        let sample_y = offset_clamped(y, kernel_y, height);
        for (kernel_x, row) in kernel.iter().enumerate() {
            let sample_x = offset_clamped(x, kernel_x, width);
            sum += mosaic[sample_y * width + sample_x] * row[kernel_y];
        }
    }
    sum / 8.0
}

fn offset_clamped(origin: usize, kernel_index: usize, limit: usize) -> usize {
    match kernel_index {
        0 => origin.saturating_sub(2),
        1 => origin.saturating_sub(1),
        2 => origin,
        3 => origin.saturating_add(1).min(limit - 1),
        4 => origin.saturating_add(2).min(limit - 1),
        _ => unreachable!("5x5 kernel index is always between zero and four"),
    }
}

#[cfg(test)]
mod tests {
    use image::{ImageBuffer, Rgb};
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn decode_std_removes_srgb_transfer_curve() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("sample.png");
        let image =
            ImageBuffer::<Rgb<u8>, _>::from_raw(2, 1, vec![128, 128, 128, 255, 0, 0]).unwrap();
        image.save(&path).unwrap();

        let decoded = decode_std(&path).unwrap();
        assert_eq!((decoded.w, decoded.h), (2, 1));
        assert!((decoded.data[0] - 0.215_86).abs() < 0.000_1);
        assert!((decoded.data[3] - 1.0).abs() < f32::EPSILON);
        assert!(decoded.data[4].abs() < f32::EPSILON);
    }

    #[test]
    fn malvar_reconstructs_constant_bayer_planes() {
        let width = 12;
        let height = 12;
        let cfa = rawler::CFA::new("RGGB");
        let levels = [0.25, 0.5, 0.75];
        let mosaic: Vec<f32> = (0..height)
            .flat_map(|y| {
                (0..width).map({
                    let cfa = &cfa;
                    move |x| levels[cfa.color_at(y, x)]
                })
            })
            .collect();

        let rgb = demosaic_malvar(&mosaic, width, height, &cfa).unwrap();
        for y in 2..height - 2 {
            for x in 2..width - 2 {
                let offset = (y * width + x) * 3;
                for channel in 0..3 {
                    assert!((rgb[offset + channel] - levels[channel]).abs() < 1.0e-6);
                }
            }
        }
    }

    #[test]
    #[ignore = "requires RAWSR_TEST_ARW to point to a local Sony RAW file"]
    fn decode_real_arw() {
        let path =
            std::env::var_os("RAWSR_TEST_ARW").expect("set RAWSR_TEST_ARW to a local .ARW file");
        let (image, meta) = decode_raw(Path::new(&path)).unwrap();
        assert!(image.w > 1000 && image.h > 1000);
        assert!(image.data.iter().all(|value| value.is_finite()));
        assert!(
            (0.01..0.9).contains(&image.mean()),
            "unexpected linear mean: {}",
            image.mean()
        );
        assert_eq!(meta.clean_make, "Sony");
        eprintln!(
            "decoded {} {}: {}x{}, CFA {}, mean {:.6}",
            meta.clean_make,
            meta.clean_model,
            image.w,
            image.h,
            meta.cfa_pattern,
            image.mean()
        );
    }

    #[test]
    #[ignore = "requires RAWSR_TEST_ARW to point to a local Sony RAW file"]
    fn extracts_real_arw_embedded_thumbnail() {
        let path =
            std::env::var_os("RAWSR_TEST_ARW").expect("set RAWSR_TEST_ARW to a local .ARW file");
        let thumbnail = extract_thumbnail(Path::new(&path)).unwrap();
        assert!(thumbnail.jpeg.starts_with(&[0xff, 0xd8]));
        assert!(thumbnail.jpeg.ends_with(&[0xff, 0xd9]));
        assert!(thumbnail.width > 100 && thumbnail.height > 100);
        assert_eq!(thumbnail.exif.make, "Sony");
        assert_eq!(thumbnail.exif.model, "ILCE-7RM2");
    }
}
