# Asset Library icon

`icon.svg` is the PostHog square logomark from [PostHog/posthog.com at ebb7459a6f828147d7972c3874a84a135eee5838](https://github.com/PostHog/posthog.com/blob/ebb7459a6f828147d7972c3874a84a135eee5838/static/brand/posthog-logomark-square.svg). Copyright PostHog Inc. The logo identifies PostHog; its use follows the [PostHog website's logo policy](https://github.com/PostHog/posthog.com/blob/ebb7459a6f828147d7972c3874a84a135eee5838/LICENSE).

The PNG is a 256×256 rasterization for the Asset Library, which does not accept SVG icons. These listing assets are not included in the runtime addon ZIP. The SDK's MIT license does not grant trademark rights.

To regenerate the PNG using CairoSVG 2.8.2 and an installed Cairo library:

```sh
uvx --from cairosvg==2.8.2 cairosvg docs/assets/icon.svg \
  --output-width 256 --output-height 256 -o docs/assets/icon.png
```

On macOS, Python may need help locating Homebrew's Cairo library:

```sh
uv run --with cairosvg==2.8.2 python - <<'PY'
import os
os.environ['DYLD_FALLBACK_LIBRARY_PATH'] = '/opt/homebrew/lib'
import cairosvg
cairosvg.svg2png(url='docs/assets/icon.svg', write_to='docs/assets/icon.png',
               output_width=256, output_height=256)
PY
```

Use the raw, commit-pinned PNG URL produced by `scripts/release.py`, not a GitHub HTML page or an SVG URL.
