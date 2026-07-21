use anyhow::{Context, Result, ensure};

use crate::develop::SrgbImage;
use crate::infer::{Restorer, SrgbTile};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: usize,
    pub y: usize,
    pub w: usize,
    pub h: usize,
}

impl Rect {
    pub fn new(x: usize, y: usize, w: usize, h: usize) -> Result<Self> {
        ensure!(
            w > 0 && h > 0,
            "rectangle dimensions must be greater than zero"
        );
        Ok(Self { x, y, w, h })
    }

    pub fn validate_inside(self, image_w: usize, image_h: usize) -> Result<Self> {
        let right = self
            .x
            .checked_add(self.w)
            .ok_or_else(|| anyhow::anyhow!("rectangle x extent overflowed"))?;
        let bottom = self
            .y
            .checked_add(self.h)
            .ok_or_else(|| anyhow::anyhow!("rectangle y extent overflowed"))?;
        ensure!(
            right <= image_w && bottom <= image_h,
            "rectangle lies outside image bounds"
        );
        Ok(self)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct TileOptions {
    pub tile_size: Option<usize>,
    pub overlap: Option<usize>,
    pub memory_budget_bytes: Option<usize>,
}

pub trait RowBandSink {
    fn begin(&mut self, width: usize, height: usize) -> Result<()>;
    fn write_band(&mut self, y: usize, rows: usize, rgb16: &[u16]) -> Result<()>;
    fn finish(&mut self) -> Result<()>;
}

/// Transforms a blended display-referred RGB pixel before output quantization.
pub trait PixelTransform {
    fn transform_rgb(&self, rgb: [f32; 3]) -> [f32; 3];
}

impl<F> PixelTransform for F
where
    F: Fn([f32; 3]) -> [f32; 3] + ?Sized,
{
    fn transform_rgb(&self, rgb: [f32; 3]) -> [f32; 3] {
        self(rgb)
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct IdentityPixelTransform;

impl PixelTransform for IdentityPixelTransform {
    fn transform_rgb(&self, rgb: [f32; 3]) -> [f32; 3] {
        rgb
    }
}

pub fn restore_tiled_to_image(
    image: &SrgbImage,
    restorer: &dyn Restorer,
    crop: Option<Rect>,
    options: TileOptions,
    progress: &dyn Fn(f32),
) -> Result<SrgbImage> {
    restore_tiled_to_image_with_transform(
        image,
        restorer,
        crop,
        options,
        &IdentityPixelTransform,
        progress,
    )
}

pub fn restore_tiled_to_image_with_transform<T: PixelTransform + ?Sized>(
    image: &SrgbImage,
    restorer: &dyn Restorer,
    crop: Option<Rect>,
    options: TileOptions,
    transform: &T,
    progress: &dyn Fn(f32),
) -> Result<SrgbImage> {
    ensure!(
        restorer.scale() == 1,
        "in-memory tiled output is restricted to scale-1 restoration; super-resolution must stream to a row-band sink"
    );
    let mut sink = ImageBufferSink::default();
    process_tiled_with_options_and_transform(
        image, restorer, crop, options, transform, &mut sink, progress,
    )?;
    let data = sink
        .data
        .into_iter()
        .map(|value| f32::from(value) / f32::from(u16::MAX))
        .collect();
    SrgbImage::new(data, sink.width, sink.height)
}

pub fn restore_tiled_to_preview(
    image: &SrgbImage,
    restorer: &dyn Restorer,
    crop: Option<Rect>,
    options: TileOptions,
    max_output_pixels: usize,
    progress: &dyn Fn(f32),
) -> Result<SrgbImage> {
    restore_tiled_to_preview_with_transform(
        image,
        restorer,
        crop,
        options,
        max_output_pixels,
        &IdentityPixelTransform,
        progress,
    )
}

pub fn restore_tiled_to_preview_with_transform<T: PixelTransform + ?Sized>(
    image: &SrgbImage,
    restorer: &dyn Restorer,
    crop: Option<Rect>,
    options: TileOptions,
    max_output_pixels: usize,
    transform: &T,
    progress: &dyn Fn(f32),
) -> Result<SrgbImage> {
    ensure!(
        max_output_pixels > 0,
        "preview output pixel limit must be greater than zero"
    );
    let input = crop.map_or((image.w, image.h), |rect| (rect.w, rect.h));
    let scale = usize::try_from(restorer.scale()).context("model scale does not fit usize")?;
    let output_pixels = input
        .0
        .checked_mul(scale)
        .and_then(|width| {
            input
                .1
                .checked_mul(scale)
                .and_then(|height| width.checked_mul(height))
        })
        .context("preview output dimensions overflowed")?;
    ensure!(
        output_pixels <= max_output_pixels,
        "preview output has {output_pixels} pixels, exceeding limit {max_output_pixels}"
    );
    let mut sink = ImageBufferSink::default();
    process_tiled_with_options_and_transform(
        image, restorer, crop, options, transform, &mut sink, progress,
    )?;
    let data = sink
        .data
        .into_iter()
        .map(|value| f32::from(value) / f32::from(u16::MAX))
        .collect();
    SrgbImage::new(data, sink.width, sink.height)
}

#[derive(Default)]
struct ImageBufferSink {
    width: usize,
    height: usize,
    next_y: usize,
    data: Vec<u16>,
}

impl RowBandSink for ImageBufferSink {
    fn begin(&mut self, width: usize, height: usize) -> Result<()> {
        ensure!(
            self.data.is_empty() && self.next_y == 0,
            "image buffer sink cannot be reused"
        );
        self.width = width;
        self.height = height;
        self.data.reserve(width * height * 3);
        Ok(())
    }

    fn write_band(&mut self, y: usize, rows: usize, rgb16: &[u16]) -> Result<()> {
        ensure!(
            y == self.next_y,
            "image buffer row bands must be contiguous"
        );
        ensure!(
            rgb16.len() == rows * self.width * 3,
            "image buffer row band length mismatch"
        );
        self.data.extend_from_slice(rgb16);
        self.next_y += rows;
        Ok(())
    }

    fn finish(&mut self) -> Result<()> {
        ensure!(
            self.next_y == self.height,
            "image buffer sink did not receive every row"
        );
        Ok(())
    }
}

pub fn process_tiled(
    image: &SrgbImage,
    restorer: &dyn Restorer,
    crop: Option<Rect>,
    sink: &mut dyn RowBandSink,
    progress: &dyn Fn(f32),
) -> Result<()> {
    process_tiled_with_transform(
        image,
        restorer,
        crop,
        &IdentityPixelTransform,
        sink,
        progress,
    )
}

pub fn process_tiled_with_transform<T: PixelTransform + ?Sized>(
    image: &SrgbImage,
    restorer: &dyn Restorer,
    crop: Option<Rect>,
    transform: &T,
    sink: &mut dyn RowBandSink,
    progress: &dyn Fn(f32),
) -> Result<()> {
    process_tiled_with_options_and_transform(
        image,
        restorer,
        crop,
        TileOptions::default(),
        transform,
        sink,
        progress,
    )
}

pub fn process_tiled_with_options(
    image: &SrgbImage,
    restorer: &dyn Restorer,
    crop: Option<Rect>,
    options: TileOptions,
    sink: &mut dyn RowBandSink,
    progress: &dyn Fn(f32),
) -> Result<()> {
    process_tiled_with_options_and_transform(
        image,
        restorer,
        crop,
        options,
        &IdentityPixelTransform,
        sink,
        progress,
    )
}

#[allow(clippy::too_many_lines)]
pub fn process_tiled_with_options_and_transform<T: PixelTransform + ?Sized>(
    image: &SrgbImage,
    restorer: &dyn Restorer,
    crop: Option<Rect>,
    options: TileOptions,
    transform: &T,
    sink: &mut dyn RowBandSink,
    progress: &dyn Fn(f32),
) -> Result<()> {
    ensure!(
        image.w > 0 && image.h > 0,
        "image dimensions must be greater than zero"
    );
    ensure!(
        image.data.len() == image.w * image.h * 3,
        "image data length does not match dimensions"
    );
    let crop = crop
        .unwrap_or(Rect {
            x: 0,
            y: 0,
            w: image.w,
            h: image.h,
        })
        .validate_inside(image.w, image.h)?;
    let scale = usize::try_from(restorer.scale()).context("restorer scale does not fit usize")?;
    ensure!(scale > 0, "restorer scale must be greater than zero");

    let hint = restorer.tile_hint();
    let overlap = options.overlap.unwrap_or(hint.overlap);
    let requested_tile_size = options.tile_size.unwrap_or(hint.size);
    ensure!(
        requested_tile_size > 0,
        "tile size must be greater than zero"
    );
    ensure!(
        overlap * 2 < requested_tile_size,
        "tile overlap must be less than half the tile size"
    );

    let output_w = crop
        .w
        .checked_mul(scale)
        .context("output width overflowed")?;
    let output_h = crop
        .h
        .checked_mul(scale)
        .context("output height overflowed")?;
    let tile_size = fit_tile_size_to_budget(
        requested_tile_size,
        overlap,
        output_w,
        scale,
        options.memory_budget_bytes,
    )?;
    let x_spans = tile_spans(crop.w, tile_size, overlap)?;
    let y_spans = tile_spans(crop.h, tile_size, overlap)?;
    let total_tiles = x_spans.len() * y_spans.len();
    ensure!(total_tiles > 0, "tiling produced no work");

    let ring_rows = tile_size
        .min(crop.h)
        .checked_mul(scale)
        .context("row ring height overflowed")?;
    let row_samples = output_w
        .checked_mul(3)
        .context("output row length overflowed")?;
    let mut accum = vec![0.0_f32; ring_rows * row_samples];
    let mut weights = vec![0.0_f32; ring_rows * output_w];
    let mut completed_tiles = 0;
    let mut flushed_y = 0;

    sink.begin(output_w, output_h)?;
    progress(0.0);

    for (span_y_index, span_y) in y_spans.iter().enumerate() {
        for span_x in &x_spans {
            let input = extract_tile(image, crop, *span_x, *span_y)?;
            let output_tile = restorer.run(&input).with_context(|| {
                format!(
                    "restorer failed for tile at {},{} with size {}x{}",
                    span_x.start, span_y.start, span_x.len, span_y.len
                )
            })?;
            let expected_w = span_x
                .len
                .checked_mul(scale)
                .context("tile output width overflowed")?;
            let expected_h = span_y
                .len
                .checked_mul(scale)
                .context("tile output height overflowed")?;
            ensure!(
                (output_tile.w, output_tile.h) == (expected_w, expected_h),
                "restorer returned {}x{} for tile, expected {}x{}",
                output_tile.w,
                output_tile.h,
                expected_w,
                expected_h
            );

            accumulate_tile(
                &output_tile,
                *span_x,
                *span_y,
                scale,
                output_w,
                ring_rows,
                &mut accum,
                &mut weights,
            );
            completed_tiles += 1;
            progress(progress_fraction(completed_tiles, total_tiles));
        }

        let flush_end = y_spans
            .get(span_y_index + 1)
            .map_or(output_h, |next| next.start * scale);
        flush_rows(
            flushed_y,
            flush_end,
            output_w,
            ring_rows,
            &mut accum,
            &mut weights,
            transform,
            sink,
        )?;
        flushed_y = flush_end;
    }

    ensure!(
        flushed_y == output_h,
        "tiling did not flush the complete output image"
    );
    sink.finish()?;
    progress(1.0);
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TileSpan {
    start: usize,
    len: usize,
    overlap_before: usize,
    overlap_after: usize,
}

fn tile_spans(length: usize, tile_size: usize, overlap: usize) -> Result<Vec<TileSpan>> {
    ensure!(length > 0, "tile axis length must be greater than zero");
    if length <= tile_size {
        return Ok(vec![TileSpan {
            start: 0,
            len: length,
            overlap_before: 0,
            overlap_after: 0,
        }]);
    }

    let stride = tile_size - overlap;
    let mut origins = vec![0];
    while origins.last().copied().unwrap_or(0) + tile_size < length {
        let previous = origins.last().copied().unwrap_or(0);
        let mut next = previous + stride;
        if next + tile_size >= length {
            next = length - tile_size;
        }
        ensure!(next > previous, "tile origin did not advance");
        origins.push(next);
    }

    let mut spans = Vec::with_capacity(origins.len());
    for (index, start) in origins.iter().copied().enumerate() {
        let len = tile_size.min(length - start);
        let overlap_before = if index == 0 {
            0
        } else {
            let previous_start = origins[index - 1];
            (previous_start + tile_size).saturating_sub(start)
        };
        let overlap_after = origins
            .get(index + 1)
            .map_or(0, |next_start| (start + len).saturating_sub(*next_start));
        spans.push(TileSpan {
            start,
            len,
            overlap_before,
            overlap_after,
        });
    }
    Ok(spans)
}

fn fit_tile_size_to_budget(
    requested: usize,
    overlap: usize,
    output_width: usize,
    scale: usize,
    budget: Option<usize>,
) -> Result<usize> {
    let Some(budget) = budget else {
        return Ok(requested);
    };
    ensure!(budget > 0, "memory budget must be greater than zero");
    let bytes_per_ring_row = output_width
        .checked_mul(4 * std::mem::size_of::<f32>())
        .context("row ring byte count overflowed")?;
    let maximum_output_rows = budget / bytes_per_ring_row;
    let maximum_input_rows = maximum_output_rows / scale;
    let minimum = overlap
        .checked_mul(2)
        .and_then(|value| value.checked_add(1))
        .context("minimum tile size overflowed")?;
    ensure!(
        maximum_input_rows >= minimum,
        "memory budget is too small for output row ring; need at least {} bytes",
        bytes_per_ring_row * minimum * scale
    );
    Ok(requested.min(maximum_input_rows).max(minimum))
}

fn extract_tile(
    image: &SrgbImage,
    crop: Rect,
    span_x: TileSpan,
    span_y: TileSpan,
) -> Result<SrgbTile> {
    let mut data = Vec::with_capacity(span_x.len * span_y.len * 3);
    for local_y in 0..span_y.len {
        let source_y = crop.y + span_y.start + local_y;
        let source_x = crop.x + span_x.start;
        let source_offset = (source_y * image.w + source_x) * 3;
        let sample_count = span_x.len * 3;
        data.extend_from_slice(&image.data[source_offset..source_offset + sample_count]);
    }
    SrgbTile::new(data, span_x.len, span_y.len)
}

#[allow(clippy::too_many_arguments)]
fn accumulate_tile(
    tile: &SrgbTile,
    span_x: TileSpan,
    span_y: TileSpan,
    scale: usize,
    output_width: usize,
    ring_rows: usize,
    accum: &mut [f32],
    weights: &mut [f32],
) {
    let overlap_left = span_x.overlap_before * scale;
    let overlap_right = span_x.overlap_after * scale;
    let overlap_top = span_y.overlap_before * scale;
    let overlap_bottom = span_y.overlap_after * scale;
    let global_origin = (span_x.start * scale, span_y.start * scale);

    for local_y in 0..tile.h {
        let global_y = global_origin.1 + local_y;
        let ring_y = global_y % ring_rows;
        let y_weight = feather_weight(local_y, tile.h, overlap_top, overlap_bottom);
        for local_x in 0..tile.w {
            let global_x = global_origin.0 + local_x;
            let weight = y_weight * feather_weight(local_x, tile.w, overlap_left, overlap_right);
            let source_offset = (local_y * tile.w + local_x) * 3;
            let destination_offset = (ring_y * output_width + global_x) * 3;
            accum[destination_offset] += tile.data[source_offset] * weight;
            accum[destination_offset + 1] += tile.data[source_offset + 1] * weight;
            accum[destination_offset + 2] += tile.data[source_offset + 2] * weight;
            weights[ring_y * output_width + global_x] += weight;
        }
    }
}

#[allow(clippy::cast_precision_loss)]
fn feather_weight(
    position: usize,
    length: usize,
    overlap_before: usize,
    overlap_after: usize,
) -> f32 {
    if overlap_before > 0 && position < overlap_before {
        return position as f32 / overlap_before as f32;
    }
    let after_start = length.saturating_sub(overlap_after);
    if overlap_after > 0 && position >= after_start {
        return (length - position) as f32 / overlap_after as f32;
    }
    1.0
}

#[allow(clippy::too_many_arguments)]
fn flush_rows<T: PixelTransform + ?Sized>(
    start_y: usize,
    end_y: usize,
    output_width: usize,
    ring_rows: usize,
    accum: &mut [f32],
    weights: &mut [f32],
    transform: &T,
    sink: &mut dyn RowBandSink,
) -> Result<()> {
    const WRITE_ROWS: usize = 16;
    for band_start in (start_y..end_y).step_by(WRITE_ROWS) {
        let rows = WRITE_ROWS.min(end_y - band_start);
        let mut band = Vec::with_capacity(rows * output_width * 3);
        for global_y in band_start..band_start + rows {
            let ring_y = global_y % ring_rows;
            for x in 0..output_width {
                let weight_index = ring_y * output_width + x;
                let weight = weights[weight_index];
                ensure!(
                    weight > 0.0 && weight.is_finite(),
                    "output pixel {x},{global_y} has invalid blend weight {weight}"
                );
                let offset = weight_index * 3;
                let transformed = transform.transform_rgb([
                    accum[offset] / weight,
                    accum[offset + 1] / weight,
                    accum[offset + 2] / weight,
                ]);
                band.extend(transformed.into_iter().map(quantize_u16));
                accum[offset..offset + 3].fill(0.0);
                weights[weight_index] = 0.0;
            }
        }
        sink.write_band(band_start, rows, &band)?;
    }
    Ok(())
}

#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn quantize_u16(value: f32) -> u16 {
    (value.clamp(0.0, 1.0) * f32::from(u16::MAX)).round() as u16
}

#[allow(clippy::cast_precision_loss)]
fn progress_fraction(done: usize, total: usize) -> f32 {
    done as f32 / total as f32
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::grade::{GradeParams, grade_image};
    use crate::infer::TileHint;

    struct Nearest2x;

    impl Restorer for Nearest2x {
        fn scale(&self) -> u32 {
            2
        }

        fn tile_hint(&self) -> TileHint {
            TileHint {
                size: 64,
                overlap: 8,
            }
        }

        fn run(&self, tile: &SrgbTile) -> Result<SrgbTile> {
            let output_w = tile.w * 2;
            let output_h = tile.h * 2;
            let mut data = vec![0.0; output_w * output_h * 3];
            for y in 0..output_h {
                for x in 0..output_w {
                    let source = ((y / 2) * tile.w + x / 2) * 3;
                    let destination = (y * output_w + x) * 3;
                    data[destination..destination + 3]
                        .copy_from_slice(&tile.data[source..source + 3]);
                }
            }
            SrgbTile::new(data, output_w, output_h)
        }
    }

    struct Identity;

    impl Restorer for Identity {
        fn scale(&self) -> u32 {
            1
        }

        fn tile_hint(&self) -> TileHint {
            TileHint {
                size: 64,
                overlap: 8,
            }
        }

        fn run(&self, tile: &SrgbTile) -> Result<SrgbTile> {
            Ok(tile.clone())
        }
    }

    #[derive(Default)]
    struct VecSink {
        width: usize,
        height: usize,
        next_y: usize,
        data: Vec<u16>,
    }

    impl RowBandSink for VecSink {
        fn begin(&mut self, width: usize, height: usize) -> Result<()> {
            self.width = width;
            self.height = height;
            self.data.reserve(width * height * 3);
            Ok(())
        }

        fn write_band(&mut self, y: usize, rows: usize, rgb16: &[u16]) -> Result<()> {
            ensure!(y == self.next_y, "row bands must be contiguous");
            ensure!(
                rgb16.len() == rows * self.width * 3,
                "row band length mismatch"
            );
            self.data.extend_from_slice(rgb16);
            self.next_y += rows;
            Ok(())
        }

        fn finish(&mut self) -> Result<()> {
            ensure!(self.next_y == self.height, "sink did not receive every row");
            Ok(())
        }
    }

    fn gradient(width: usize, height: usize) -> SrgbImage {
        let mut data = Vec::with_capacity(width * height * 3);
        for y in 0..height {
            for x in 0..width {
                #[allow(clippy::cast_precision_loss)]
                let value = (x + y) as f32 / (width + height - 2) as f32;
                data.extend_from_slice(&[value, value * 0.75, value * 0.5]);
            }
        }
        SrgbImage::new(data, width, height).unwrap()
    }

    #[test]
    fn tiled_matches_direct_pointwise_restoration() {
        let image = gradient(256, 256);
        let restorer = Nearest2x;
        let direct = restorer
            .run(&SrgbTile::new(image.data.clone(), image.w, image.h).unwrap())
            .unwrap();
        let mut sink = VecSink::default();
        process_tiled(&image, &restorer, None, &mut sink, &|_| {}).unwrap();

        for y in 8..direct.h - 8 {
            for x in 8..direct.w - 8 {
                let offset = (y * direct.w + x) * 3;
                for channel in 0..3 {
                    let expected = quantize_u16(direct.data[offset + channel]);
                    assert!(sink.data[offset + channel].abs_diff(expected) < 2);
                }
            }
        }
    }

    #[test]
    fn horizontal_gradient_has_no_tile_seam_spikes() {
        let image = gradient(257, 129);
        let mut sink = VecSink::default();
        process_tiled(&image, &Identity, None, &mut sink, &|_| {}).unwrap();
        let y = sink.height / 2;
        let values = (0..sink.width)
            .map(|x| sink.data[(y * sink.width + x) * 3])
            .collect::<Vec<_>>();
        let max_second_difference = values
            .windows(3)
            .map(|window| {
                let first = i32::from(window[1]) - i32::from(window[0]);
                let second = i32::from(window[2]) - i32::from(window[1]);
                (second - first).unsigned_abs()
            })
            .max()
            .unwrap();
        assert!(
            max_second_difference <= 2,
            "seam spike was {max_second_difference}"
        );
    }

    #[test]
    fn crop_and_progress_are_reported() {
        let image = gradient(100, 80);
        let progress = Mutex::new(Vec::new());
        let mut sink = VecSink::default();
        process_tiled(
            &image,
            &Nearest2x,
            Some(Rect::new(10, 5, 70, 60).unwrap()),
            &mut sink,
            &|value| progress.lock().unwrap().push(value),
        )
        .unwrap();
        assert_eq!((sink.width, sink.height), (140, 120));
        let progress = progress.into_inner().unwrap();
        assert_eq!(progress.first().copied(), Some(0.0));
        assert_eq!(progress.last().copied(), Some(1.0));
        assert!(progress.windows(2).all(|window| window[0] <= window[1]));
    }

    #[test]
    fn memory_budget_reduces_tile_height_without_breaking_overlap() {
        let chosen = fit_tile_size_to_budget(512, 32, 16_000, 4, Some(256 * 1024 * 1024)).unwrap();
        assert!((65..512).contains(&chosen));
    }

    #[test]
    fn streaming_transform_matches_in_memory_grading() {
        let image = gradient(131, 97);
        let params = GradeParams {
            contrast: 0.35,
            highlights: -0.2,
            shadows: 0.25,
            whites: 0.1,
            blacks: -0.15,
            vibrance: 0.4,
            saturation: 0.2,
        };
        let expected = grade_image(&image, &params);
        let mut sink = VecSink::default();
        process_tiled_with_options_and_transform(
            &image,
            &Identity,
            None,
            TileOptions {
                tile_size: Some(48),
                overlap: Some(8),
                memory_budget_bytes: None,
            },
            &params,
            &mut sink,
            &|_| {},
        )
        .unwrap();

        for (actual, expected) in sink
            .data
            .iter()
            .copied()
            .zip(expected.data.iter().copied().map(quantize_u16))
        {
            assert!(
                actual.abs_diff(expected) <= 1,
                "streaming sample {actual} differed from in-memory {expected}"
            );
        }
    }
}
