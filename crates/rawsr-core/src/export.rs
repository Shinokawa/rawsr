use std::fs::File;
use std::io::{BufReader, Seek, Write};
use std::path::Path;

use anyhow::{Context, Result, ensure};
use base64::Engine;
use tiff::decoder::Decoder;
use tiff::encoder::colortype::RGB16;
use tiff::encoder::{ImageEncoder, TiffEncoder, TiffKind};
use tiff::tags::Tag;

use crate::develop::SrgbImage;
use crate::infer::Restorer;
use crate::tile::{
    IdentityPixelTransform, PixelTransform, Rect, RowBandSink, TileOptions,
    process_tiled_with_options_and_transform,
};

const BIG_TIFF_THRESHOLD: u64 = 4_000_000_000;
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
    image: Option<ImageEncoder<'a, W, RGB16, K>>,
    width: usize,
    height: usize,
    next_y: usize,
    begun: bool,
}

impl<'a, W: Write + Seek, K: TiffKind> TiffBandSink<'a, W, K> {
    pub fn new(encoder: &'a mut TiffEncoder<W, K>, width: usize, height: usize) -> Result<Self> {
        let width_u32 = u32::try_from(width).context("TIFF width exceeds u32")?;
        let height_u32 = u32::try_from(height).context("TIFF height exceeds u32")?;
        let mut image = encoder.new_image::<RGB16>(width_u32, height_u32)?;
        image.rows_per_strip(1)?;
        let icc = base64::engine::general_purpose::STANDARD.decode(SRGB_ICC_BASE64)?;
        image.encoder().write_tag(Tag::IccProfile, icc.as_slice())?;
        Ok(Self {
            image: Some(image),
            width,
            height,
            next_y: 0,
            begun: false,
        })
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
        let image = self
            .image
            .as_mut()
            .context("TIFF row-band sink was already finished")?;
        for row in rgb16.chunks_exact(self.width * 3) {
            image.write_strip(row)?;
            self.next_y += 1;
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
    let mut image: ImageEncoder<'_, W, RGB16, K> = encoder.new_image(width, height)?;
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

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn quantize_u16(value: f32) -> u16 {
    (value.clamp(0.0, 1.0) * f32::from(u16::MAX)).round() as u16
}

#[cfg(test)]
mod tests {
    use std::io::BufReader;

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
}
