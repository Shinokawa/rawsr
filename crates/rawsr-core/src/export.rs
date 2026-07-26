use std::fs::File;
use std::io::{BufReader, Seek, Write};
use std::path::Path;

use anyhow::{Context, Result, ensure};
use base64::Engine;
use image::codecs::jpeg::JpegEncoder;
use image::{ColorType, ImageEncoder};
use tiff::decoder::Decoder;
use tiff::encoder::colortype::RGB16;
use tiff::encoder::{ImageEncoder as TiffImageEncoder, TiffEncoder, TiffKind};
use tiff::tags::Tag;

use crate::develop::SrgbImage;
use crate::infer::Restorer;
use crate::tile::{
    IdentityPixelTransform, PixelTransform, Rect, RowBandSink, TileOptions,
    process_tiled_with_options_and_transform,
};

const BIG_TIFF_THRESHOLD: u64 = 4_000_000_000;
const TIFF_ROWS_PER_STRIP: usize = 16;
const SRGB_ICC_BASE64: &str = "AAACTGxjbXMEQAAAbW50clJHQiBYWVogB+oABwAQABIAFgAjYWNzcE1TRlQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPbWAAEAAAAA0y1sY21zAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALZGVzYwAAAQgAAAA2Y3BydAAAAUAAAABMd3RwdAAAAYwAAAAUY2hhZAAAAaAAAAAsclhZWgAAAcwAAAAUYlhZWgAAAeAAAAAUZ1hZWgAAAfQAAAAUclRSQwAAAggAAAAgZ1RSQwAAAggAAAAgYlRSQwAAAggAAAAgY2hybQAAAigAAAAkbWx1YwAAAAAAAAABAAAADGVuVVMAAAAaAAAAHABzAFIARwBCACAAYgB1AGkAbAB0AC0AaQBuAABtbHVjAAAAAAAAAAEAAAAMZW5VUwAAADAAAAAcAE4AbwAgAGMAbwBwAHkAcgBpAGcAaAB0ACwAIAB1AHMAZQAgAGYAcgBlAGUAbAB5WFlaIAAAAAAAAPbWAAEAAAAA0y1zZjMyAAAAAAABDEIAAAXe///zJQAAB5MAAP2Q///7of///aIAAAPcAADAblhZWiAAAAAAAABvoAAAOPUAAAOQWFlaIAAAAAAAACSfAAAPhAAAtsNYWVogAAAAAAAAYpcAALeHAAAY2XBhcmEAAAAAAAMAAAACZmYAAPKnAAANWQAAE9AAAApbY2hybQAAAAAAAwAAAACj1wAAVHsAAEzNAACZmgAAJmYAAA9c";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TiffContainer {
    Standard,
    Big,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TiffInfo {
    pub width: u32,
    pub height: u32,
    pub icc_profile_bytes: usize,
}

pub fn inspect_tiff(path: &Path) -> Result<TiffInfo> {
    let file =
        File::open(path).with_context(|| format!("failed to open TIFF {}", path.display()))?;
    let mut decoder = Decoder::new(BufReader::new(file))
        .with_context(|| format!("failed to decode TIFF header {}", path.display()))?;
    let (width, height) = decoder.dimensions()?;
    let icc_profile_bytes = decoder
        .get_tag_u8_vec(Tag::IccProfile)
        .map_or(0, |profile| profile.len());
    Ok(TiffInfo {
        width,
        height,
        icc_profile_bytes,
    })
}

pub struct TiffBandSink<'a, W: Write + Seek, K: TiffKind> {
    image: Option<TiffImageEncoder<'a, W, RGB16, K>>,
    width: usize,
    height: usize,
    next_y: usize,
    pending_rows: Vec<u16>,
    begun: bool,
}

/// Collects a bounded, downsampled RGB8 image while the native-resolution tile
/// pipeline streams rows through it. This keeps 4x inference tiled while making
/// a practical JPEG delivery file instead of materialising the full 4x image.
pub struct JpegBandSink {
    source_width: usize,
    source_height: usize,
    width: usize,
    height: usize,
    quality: u8,
    next_source_y: usize,
    next_output_y: usize,
    previous_row: Option<Vec<u16>>,
    current_row: Option<Vec<u16>>,
    data: Vec<u8>,
    begun: bool,
}

impl JpegBandSink {
    pub fn new(
        source_width: usize,
        source_height: usize,
        max_edge: u32,
        quality: u8,
    ) -> Result<Self> {
        ensure!(
            source_width > 0 && source_height > 0,
            "JPEG source dimensions must be positive"
        );
        ensure!(max_edge > 0, "JPEG maximum edge must be positive");
        ensure!(
            (1..=100).contains(&quality),
            "JPEG quality must be in 1..=100"
        );
        let (width, height) =
            fit_dimensions(source_width, source_height, usize::try_from(max_edge)?);
        let byte_len = width
            .checked_mul(height)
            .and_then(|pixels| pixels.checked_mul(3))
            .context("JPEG output size overflowed")?;
        Ok(Self {
            source_width,
            source_height,
            width,
            height,
            quality,
            next_source_y: 0,
            next_output_y: 0,
            previous_row: None,
            current_row: None,
            data: Vec::with_capacity(byte_len),
            begun: false,
        })
    }

    pub fn write_to_path(self, path: &Path) -> Result<()> {
        ensure!(
            self.begun && self.next_output_y == self.height,
            "JPEG sink did not finish"
        );
        let width = u32::try_from(self.width).context("JPEG width exceeds u32")?;
        let height = u32::try_from(self.height).context("JPEG height exceeds u32")?;
        let file = File::create(path)
            .with_context(|| format!("failed to create JPEG {}", path.display()))?;
        JpegEncoder::new_with_quality(file, self.quality)
            .write_image(&self.data, width, height, ColorType::Rgb8.into())
            .with_context(|| format!("failed to write JPEG {}", path.display()))
    }

    #[allow(
        clippy::cast_possible_truncation,
        clippy::cast_precision_loss,
        clippy::cast_sign_loss
    )]
    fn source_y_for_output(&self, output_y: usize) -> (usize, usize, f32) {
        let source_y =
            ((output_y as f64 + 0.5) * self.source_height as f64 / self.height as f64) - 0.5;
        let y0 = source_y.floor().clamp(0.0, (self.source_height - 1) as f64) as usize;
        let y1 = (y0 + 1).min(self.source_height - 1);
        (y0, y1, (source_y - y0 as f64).clamp(0.0, 1.0) as f32)
    }

    #[allow(
        clippy::cast_possible_truncation,
        clippy::cast_precision_loss,
        clippy::cast_sign_loss
    )]
    fn emit_ready_rows(&mut self) -> Result<()> {
        while self.next_output_y < self.height {
            let (y0, y1, ty) = self.source_y_for_output(self.next_output_y);
            if y1 >= self.next_source_y {
                break;
            }
            let current = self
                .current_row
                .as_ref()
                .context("JPEG sink has no source row")?;
            let previous = self.previous_row.as_ref().unwrap_or(current);
            let top = if y0 + 1 == self.next_source_y {
                current
            } else {
                previous
            };
            let bottom = if y1 + 1 == self.next_source_y {
                current
            } else {
                previous
            };
            for output_x in 0..self.width {
                let source_x =
                    ((output_x as f64 + 0.5) * self.source_width as f64 / self.width as f64) - 0.5;
                let x0 = source_x.floor().clamp(0.0, (self.source_width - 1) as f64) as usize;
                let x1 = (x0 + 1).min(self.source_width - 1);
                let tx = (source_x - x0 as f64).clamp(0.0, 1.0) as f32;
                for channel in 0..3 {
                    let top_value = f32::from(top[x0 * 3 + channel])
                        + (f32::from(top[x1 * 3 + channel]) - f32::from(top[x0 * 3 + channel]))
                            * tx;
                    let bottom_value = f32::from(bottom[x0 * 3 + channel])
                        + (f32::from(bottom[x1 * 3 + channel])
                            - f32::from(bottom[x0 * 3 + channel]))
                            * tx;
                    self.data.push(
                        ((top_value + (bottom_value - top_value) * ty) / 257.0).round() as u8,
                    );
                }
            }
            self.next_output_y += 1;
        }
        Ok(())
    }
}

impl RowBandSink for JpegBandSink {
    fn begin(&mut self, width: usize, height: usize) -> Result<()> {
        ensure!(!self.begun, "JPEG row-band sink was already started");
        ensure!(
            (width, height) == (self.source_width, self.source_height),
            "JPEG source dimensions changed after creation"
        );
        self.begun = true;
        Ok(())
    }

    fn write_band(&mut self, y: usize, rows: usize, rgb16: &[u16]) -> Result<()> {
        ensure!(self.begun, "JPEG row-band sink has not started");
        ensure!(y == self.next_source_y, "JPEG row bands must be contiguous");
        ensure!(
            rgb16.len() == rows * self.source_width * 3,
            "JPEG row band length does not match dimensions"
        );
        for row in rgb16.chunks_exact(self.source_width * 3) {
            self.previous_row = self.current_row.replace(row.to_vec());
            self.next_source_y += 1;
            self.emit_ready_rows()?;
        }
        Ok(())
    }

    fn finish(&mut self) -> Result<()> {
        ensure!(self.begun, "JPEG row-band sink has not started");
        self.emit_ready_rows()?;
        ensure!(
            self.next_source_y == self.source_height,
            "JPEG row-band sink received incomplete input"
        );
        ensure!(
            self.next_output_y == self.height,
            "JPEG row-band sink did not produce every row"
        );
        Ok(())
    }
}

impl<'a, W: Write + Seek, K: TiffKind> TiffBandSink<'a, W, K> {
    pub fn new(encoder: &'a mut TiffEncoder<W, K>, width: usize, height: usize) -> Result<Self> {
        let width_u32 = u32::try_from(width).context("TIFF width exceeds u32")?;
        let height_u32 = u32::try_from(height).context("TIFF height exceeds u32")?;
        let mut image = encoder.new_image::<RGB16>(width_u32, height_u32)?;
        image.rows_per_strip(u32::try_from(TIFF_ROWS_PER_STRIP)?)?;
        let icc = base64::engine::general_purpose::STANDARD.decode(SRGB_ICC_BASE64)?;
        image.encoder().write_tag(Tag::IccProfile, icc.as_slice())?;
        Ok(Self {
            image: Some(image),
            width,
            height,
            next_y: 0,
            pending_rows: Vec::with_capacity(width * TIFF_ROWS_PER_STRIP * 3),
            begun: false,
        })
    }

    fn flush_pending_rows(&mut self) -> Result<()> {
        if self.pending_rows.is_empty() {
            return Ok(());
        }
        let image = self
            .image
            .as_mut()
            .context("TIFF row-band sink was already finished")?;
        image.write_strip(&self.pending_rows)?;
        self.pending_rows.clear();
        Ok(())
    }
}

impl<W: Write + Seek, K: TiffKind> RowBandSink for TiffBandSink<'_, W, K> {
    fn begin(&mut self, width: usize, height: usize) -> Result<()> {
        ensure!(!self.begun, "TIFF row-band sink was already started");
        ensure!(
            (width, height) == (self.width, self.height),
            "TIFF row-band dimensions changed after creation"
        );
        self.begun = true;
        Ok(())
    }

    fn write_band(&mut self, y: usize, rows: usize, rgb16: &[u16]) -> Result<()> {
        ensure!(self.begun, "TIFF row-band sink has not started");
        ensure!(y == self.next_y, "TIFF row bands must be contiguous");
        ensure!(rows > 0, "TIFF row band must contain at least one row");
        ensure!(
            rgb16.len() == rows * self.width * 3,
            "TIFF row band length does not match dimensions"
        );
        for row in rgb16.chunks_exact(self.width * 3) {
            self.pending_rows.extend_from_slice(row);
            self.next_y += 1;
            if self.pending_rows.len() == TIFF_ROWS_PER_STRIP * self.width * 3 {
                self.flush_pending_rows()?;
            }
        }
        Ok(())
    }

    fn finish(&mut self) -> Result<()> {
        ensure!(self.begun, "TIFF row-band sink has not started");
        ensure!(
            self.next_y == self.height,
            "TIFF row-band sink received {} of {} rows",
            self.next_y,
            self.height
        );
        self.flush_pending_rows()?;
        self.image
            .take()
            .context("TIFF row-band sink was already finished")?
            .finish()?;
        Ok(())
    }
}

#[must_use]
pub fn choose_tiff_container(width: usize, height: usize) -> TiffContainer {
    let pixel_bytes = u64::try_from(width)
        .unwrap_or(u64::MAX)
        .saturating_mul(u64::try_from(height).unwrap_or(u64::MAX))
        .saturating_mul(6);
    let estimated_bytes = pixel_bytes
        .saturating_add(pixel_bytes / 100)
        .saturating_add(1_048_576);
    if estimated_bytes >= BIG_TIFF_THRESHOLD {
        TiffContainer::Big
    } else {
        TiffContainer::Standard
    }
}

pub fn write_srgb16_tiff(path: &Path, image: &SrgbImage) -> Result<TiffContainer> {
    write_srgb16_tiff_with_transform(path, image, &IdentityPixelTransform)
}

pub fn write_srgb16_tiff_with_transform<T: PixelTransform + ?Sized>(
    path: &Path,
    image: &SrgbImage,
    transform: &T,
) -> Result<TiffContainer> {
    let container = choose_tiff_container(image.w, image.h);
    write_srgb16_tiff_as_with_transform(path, image, container, transform)?;
    Ok(container)
}

pub fn write_srgb16_tiff_as(
    path: &Path,
    image: &SrgbImage,
    container: TiffContainer,
) -> Result<()> {
    write_srgb16_tiff_as_with_transform(path, image, container, &IdentityPixelTransform)
}

pub fn write_srgb16_tiff_as_with_transform<T: PixelTransform + ?Sized>(
    path: &Path,
    image: &SrgbImage,
    container: TiffContainer,
    transform: &T,
) -> Result<()> {
    anyhow::ensure!(
        image.w > 0 && image.h > 0,
        "image dimensions must be greater than zero"
    );
    anyhow::ensure!(
        image.data.len() == image.w * image.h * 3,
        "image data length does not match dimensions"
    );
    let file =
        File::create(path).with_context(|| format!("failed to create TIFF {}", path.display()))?;

    match container {
        TiffContainer::Standard => {
            let encoder = TiffEncoder::new(file).context("failed to initialize TIFF encoder")?;
            encode_srgb16(encoder, image, transform)
        }
        TiffContainer::Big => {
            let encoder =
                TiffEncoder::new_big(file).context("failed to initialize BigTIFF encoder")?;
            encode_srgb16(encoder, image, transform)
        }
    }
    .with_context(|| format!("failed to write TIFF {}", path.display()))
}

pub fn restore_tiled_to_tiff(
    path: &Path,
    source: &SrgbImage,
    restorer: &dyn Restorer,
    crop: Option<Rect>,
    options: TileOptions,
    progress: &dyn Fn(f32),
) -> Result<TiffContainer> {
    restore_tiled_to_tiff_with_transform(
        path,
        source,
        restorer,
        crop,
        options,
        &IdentityPixelTransform,
        progress,
    )
}

pub fn restore_tiled_to_tiff_with_transform<T: PixelTransform + ?Sized>(
    path: &Path,
    source: &SrgbImage,
    restorer: &dyn Restorer,
    crop: Option<Rect>,
    options: TileOptions,
    transform: &T,
    progress: &dyn Fn(f32),
) -> Result<TiffContainer> {
    let crop = crop.unwrap_or(Rect {
        x: 0,
        y: 0,
        w: source.w,
        h: source.h,
    });
    let crop = crop.validate_inside(source.w, source.h)?;
    let scale = usize::try_from(restorer.scale()).context("restorer scale does not fit usize")?;
    let output_w = crop
        .w
        .checked_mul(scale)
        .context("TIFF output width overflowed")?;
    let output_h = crop
        .h
        .checked_mul(scale)
        .context("TIFF output height overflowed")?;
    let container = choose_tiff_container(output_w, output_h);
    let file =
        File::create(path).with_context(|| format!("failed to create TIFF {}", path.display()))?;

    match container {
        TiffContainer::Standard => {
            let mut encoder =
                TiffEncoder::new(file).context("failed to initialize TIFF encoder")?;
            let mut sink = TiffBandSink::new(&mut encoder, output_w, output_h)?;
            process_tiled_with_options_and_transform(
                source,
                restorer,
                Some(crop),
                options,
                transform,
                &mut sink,
                progress,
            )?;
        }
        TiffContainer::Big => {
            let mut encoder =
                TiffEncoder::new_big(file).context("failed to initialize BigTIFF encoder")?;
            let mut sink = TiffBandSink::new(&mut encoder, output_w, output_h)?;
            process_tiled_with_options_and_transform(
                source,
                restorer,
                Some(crop),
                options,
                transform,
                &mut sink,
                progress,
            )?;
        }
    }
    Ok(container)
}

fn encode_srgb16<W, K, T>(
    mut encoder: TiffEncoder<W, K>,
    source: &SrgbImage,
    transform: &T,
) -> Result<()>
where
    W: Write + Seek,
    K: TiffKind,
    T: PixelTransform + ?Sized,
{
    let width = u32::try_from(source.w).context("TIFF width exceeds u32")?;
    let height = u32::try_from(source.h).context("TIFF height exceeds u32")?;
    let mut image: TiffImageEncoder<'_, W, RGB16, K> = encoder.new_image(width, height)?;
    image.rows_per_strip(16)?;
    let icc = base64::engine::general_purpose::STANDARD.decode(SRGB_ICC_BASE64)?;
    image.encoder().write_tag(Tag::IccProfile, icc.as_slice())?;

    let mut source_offset: usize = 0;
    while image.next_strip_sample_count() > 0 {
        let sample_count = usize::try_from(image.next_strip_sample_count())
            .context("strip sample count exceeds usize")?;
        let end = source_offset
            .checked_add(sample_count)
            .context("strip source range overflowed")?;
        let strip = source.data[source_offset..end]
            .chunks_exact(3)
            .flat_map(|pixel| transform.transform_rgb([pixel[0], pixel[1], pixel[2]]))
            .map(quantize_u16)
            .collect::<Vec<_>>();
        image.write_strip(&strip)?;
        source_offset = end;
    }
    image.finish()?;
    Ok(())
}

/// Writes an 8-bit sRGB JPEG, downsampling to `max_edge` when needed.
pub fn write_srgb8_jpeg_with_transform<T: PixelTransform + ?Sized>(
    path: &Path,
    image: &SrgbImage,
    max_edge: u32,
    quality: u8,
    transform: &T,
) -> Result<()> {
    let mut sink = JpegBandSink::new(image.w, image.h, max_edge, quality)?;
    sink.begin(image.w, image.h)?;
    for (y, row) in image.data.chunks_exact(image.w * 3).enumerate() {
        let transformed = row
            .chunks_exact(3)
            .flat_map(|pixel| transform.transform_rgb([pixel[0], pixel[1], pixel[2]]))
            .map(quantize_u16)
            .collect::<Vec<_>>();
        sink.write_band(y, 1, &transformed)?;
    }
    sink.finish()?;
    sink.write_to_path(path)
}

/// Runs tiled restoration at native model resolution, then downsamples directly
/// into an 8-bit JPEG delivery image.
#[allow(clippy::too_many_arguments)]
pub fn restore_tiled_to_jpeg_with_transform<T: PixelTransform + ?Sized>(
    path: &Path,
    source: &SrgbImage,
    restorer: &dyn Restorer,
    crop: Option<Rect>,
    options: TileOptions,
    max_edge: u32,
    quality: u8,
    transform: &T,
    progress: &dyn Fn(f32),
) -> Result<()> {
    let crop = crop
        .unwrap_or(Rect {
            x: 0,
            y: 0,
            w: source.w,
            h: source.h,
        })
        .validate_inside(source.w, source.h)?;
    let scale = usize::try_from(restorer.scale()).context("restorer scale does not fit usize")?;
    let output_width = crop
        .w
        .checked_mul(scale)
        .context("JPEG output width overflowed")?;
    let output_height = crop
        .h
        .checked_mul(scale)
        .context("JPEG output height overflowed")?;
    let mut sink = JpegBandSink::new(output_width, output_height, max_edge, quality)?;
    process_tiled_with_options_and_transform(
        source,
        restorer,
        Some(crop),
        options,
        transform,
        &mut sink,
        progress,
    )?;
    sink.write_to_path(path)
}

fn fit_dimensions(width: usize, height: usize, max_edge: usize) -> (usize, usize) {
    let longest = width.max(height);
    if longest <= max_edge {
        return (width, height);
    }
    if width >= height {
        (max_edge, (height * max_edge / width).max(1))
    } else {
        ((width * max_edge / height).max(1), max_edge)
    }
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn quantize_u16(value: f32) -> u16 {
    (value.clamp(0.0, 1.0) * f32::from(u16::MAX)).round() as u16
}

#[cfg(test)]
mod tests {
    use std::io::BufReader;

    use image::GenericImageView;
    use tempfile::tempdir;
    use tiff::decoder::{Decoder, DecodingResult};

    use super::*;
    use crate::infer::{SrgbTile, TileHint};

    struct Identity;

    impl Restorer for Identity {
        fn scale(&self) -> u32 {
            1
        }

        fn tile_hint(&self) -> TileHint {
            TileHint {
                size: 2,
                overlap: 0,
            }
        }

        fn run(&self, tile: &SrgbTile) -> Result<SrgbTile> {
            Ok(tile.clone())
        }
    }

    fn sample_image() -> SrgbImage {
        SrgbImage::new(vec![0.0, 0.25, 0.5, 0.75, 1.0, 0.125], 2, 1).unwrap()
    }

    #[test]
    fn standard_tiff_round_trips_u16_pixels_and_icc() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("roundtrip.tif");
        write_srgb16_tiff_as(&path, &sample_image(), TiffContainer::Standard).unwrap();

        let mut decoder = Decoder::new(BufReader::new(File::open(path).unwrap())).unwrap();
        assert_eq!(decoder.dimensions().unwrap(), (2, 1));
        let profile = decoder.get_tag_u8_vec(Tag::IccProfile).unwrap();
        assert!(profile.len() > 500);
        let DecodingResult::U16(pixels) = decoder.read_image().unwrap() else {
            panic!("expected RGB16 TIFF pixels");
        };
        let expected = sample_image()
            .data
            .into_iter()
            .map(quantize_u16)
            .collect::<Vec<_>>();
        assert_eq!(pixels, expected);
    }

    #[test]
    fn big_tiff_branch_writes_a_readable_file() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("small-bigtiff.tif");
        write_srgb16_tiff_as(&path, &sample_image(), TiffContainer::Big).unwrap();

        let mut decoder = Decoder::new(BufReader::new(File::open(path).unwrap())).unwrap();
        assert_eq!(decoder.dimensions().unwrap(), (2, 1));
        assert!(matches!(
            decoder.read_image().unwrap(),
            DecodingResult::U16(_)
        ));
    }

    #[test]
    fn large_estimate_selects_big_tiff_without_allocating_image_data() {
        assert_eq!(choose_tiff_container(40_000, 20_000), TiffContainer::Big);
        assert_eq!(choose_tiff_container(8_000, 5_320), TiffContainer::Standard);
    }

    #[test]
    fn tiled_row_band_export_is_readable_and_exact() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("tiled.tif");
        let source = SrgbImage::new(
            vec![0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 0.25],
            2,
            2,
        )
        .unwrap();
        restore_tiled_to_tiff(
            &path,
            &source,
            &Identity,
            None,
            TileOptions::default(),
            &|_| {},
        )
        .unwrap();

        let mut decoder = Decoder::new(BufReader::new(File::open(path).unwrap())).unwrap();
        let DecodingResult::U16(pixels) = decoder.read_image().unwrap() else {
            panic!("expected RGB16 TIFF pixels");
        };
        assert_eq!(
            pixels,
            source
                .data
                .iter()
                .copied()
                .map(quantize_u16)
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn jpeg_delivery_export_downsamples_and_is_readable() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("delivery.jpg");
        let source = SrgbImage::new(
            vec![0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0],
            4,
            1,
        )
        .unwrap();
        write_srgb8_jpeg_with_transform(&path, &source, 2, 92, &IdentityPixelTransform).unwrap();

        let decoded = image::open(path).unwrap();
        assert_eq!(decoded.dimensions(), (2, 1));
    }
}
