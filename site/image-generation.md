# Hero image provenance

`public/aviation-data.webp` was generated with OpenAI's built-in image-generation
tool on October 28, 2026, using `image-sources/terrain.webp` as the edit target and style
reference. The generated PNG was converted to WebP at quality 86. The original
terrain asset is kept in `image-sources/`, outside the deployed `public/` folder.
Both are decorative illustrations; the overlays are fictional, not source data or
an operational aviation chart.

## Derived assets

- `public/aviation-data-768.webp` and `public/aviation-data-1152.webp` are the
  hero resized with ImageMagick and re-encoded with `cwebp -q 86`.
- `public/og-image.png` (1200 × 630) is a headless-Chromium render of the hero,
  the compass mark, the site fonts, and the endpoint URL, quantized with
  `pngquant`.
- `public/favicon.ico` (16, 32, and 48 px) is rendered from `public/favicon.svg`.
  `public/apple-touch-icon.png`, `public/icon-192.png`, and `public/icon-512.png`
  use the same mark on a full-bleed square, scaled into the central 80% so
  maskable crops keep the whole compass.

## Generation prompt

Use case: compositing. Asset type: decorative hero illustration for aviation-mcp.org, landscape 1536 x 1024. Input image is the existing hero, used as the edit target and style reference. Create a polished new variant that balances aviation information with terrain: preserve the dark forest/near-black #07110f background, fine pale sage contour-line mountains, oblique 3D cartographic perspective, and chartreuse #c9f66b route accent. Reduce the brightness and visual dominance of the mountain contours slightly. Overlay a coherent, sparse aviation chart layer across the center and right: two small airport runway diagrams, a connected airway route with several triangular waypoint/fix symbols and one aircraft position marker, delicate dashed airspace boundaries with altitude-limit annotations, a VOR compass rose, and two small wind barbs. Use thin sage and ivory strokes plus restrained chartreuse highlights; no panels or UI cards. Include a few crisp tiny monospaced illustrative labels, such as 'FIX 01', 'FIX 02', '270°', 'FL080', '18 / 36'. Labels are accents, not large text or dense paragraphs. This is stylized fictional aviation data, not an operational chart; do not depict real airport identifiers or chart minima. Maintain approximately 35 percent dark empty space at left for the website heading; the strongest overlays should be in the middle-right region and survive cropping on mobile. No headline, no logo, no border, no watermark, no neon blue, no photorealistic clouds. Overall effect: precise, nerd-friendly aviation data visualization, with terrain one supporting layer rather than the sole subject.
