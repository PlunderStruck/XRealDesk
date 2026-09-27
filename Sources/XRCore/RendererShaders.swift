import simd

/// The renderer's Metal shaders and the GPU-side structs of the direct renderer, in XRCore so the
/// self-checks (xrcheck) compile and run exactly what the app runs.
public enum RendererShaders {
    public struct DirectPanel {
        public var arcCenter: Float, height: Float, width: Float, panelHeight: Float
        public var highlight: Float, dim: Float, hasTexture: Float, hasCursor: Float
        public var cursorRect: SIMD4<Float>
        public init(arcCenter: Float, height: Float, width: Float, panelHeight: Float, highlight: Float, dim: Float,
                    hasTexture: Float, hasCursor: Float, cursorRect: SIMD4<Float>) {
            self.arcCenter = arcCenter; self.height = height; self.width = width; self.panelHeight = panelHeight
            self.highlight = highlight; self.dim = dim; self.hasTexture = hasTexture; self.hasCursor = hasCursor
            self.cursorRect = cursorRect
        }
    }

    public struct DirectUniforms {
        public var invView: simd_float4x4
        public var focal: SIMD2<Float>, center: SIMD2<Float>
        public var toCalibrated: SIMD2<Float>, mapSize: SIMD2<Float>
        public var mapStep: Float, lensOn: Float, originX: Float, radius: Float
        public var distance: Float, cornerRadius: Float, sharpen: Float, quality: Float
        public var panelCount: Float, subpixel: Float, subpixelStrength: Float, frame: Float
        /// Rolling scan-out compensation: calibrated picture height in pixels (0 = off) and the scan
        /// direction (+1 top to bottom, -1 bottom to top).
        public var motion: Float, dither: Float, scanRows: Float = 0, scanDir: Float = 1
        public var white: SIMD4<Float>
        /// How far the head turns (eye frame, rotation vector in radians) while the display lights
        /// the picture from its first row to its last.
        public var scan = SIMD4<Float>(0, 0, 0, 0)

        public init(invView: simd_float4x4, focal: SIMD2<Float>, center: SIMD2<Float>, toCalibrated: SIMD2<Float>,
                    mapSize: SIMD2<Float>, mapStep: Float, lensOn: Float, originX: Float, radius: Float, distance: Float,
                    cornerRadius: Float, sharpen: Float, quality: Float, panelCount: Float, subpixel: Float = 0,
                    subpixelStrength: Float = 0.5, frame: Float = 0, motion: Float = 0, dither: Float = 1,
                    white: SIMD4<Float> = SIMD4(1, 1, 1, 1)) {
            self.invView = invView; self.focal = focal; self.center = center; self.toCalibrated = toCalibrated
            self.mapSize = mapSize; self.mapStep = mapStep; self.lensOn = lensOn; self.originX = originX
            self.radius = radius; self.distance = distance; self.cornerRadius = cornerRadius; self.sharpen = sharpen
            self.quality = quality; self.panelCount = panelCount; self.subpixel = subpixel
            self.subpixelStrength = subpixelStrength; self.frame = frame; self.motion = motion; self.dither = dither
            self.white = white
        }
    }

    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 viewProj;
        float arcCenter;
        float height;
        float width;
        float panelHeight;
        float radius;
        float distance;
        float cornerRadius;
        float highlight;
        float hasTexture;
        float dim;
        float sharpen;
        float segments;
        float pixelScale;
        float mode;
        float2 uvMin;
        float2 uvMax;
        float2 pad2;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    // Catmull-Rom bicubic via 9 bilinear taps (level 0).
    float3 catmullRom(texture2d<float> tex, sampler s, float2 uv, float2 texSize) {
        float2 samplePos = uv * texSize;
        float2 t1 = floor(samplePos - 0.5) + 0.5;
        float2 f = samplePos - t1;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 t0 = (t1 - 1.0) / texSize, t3 = (t1 + 2.0) / texSize, t12 = (t1 + w2 / w12) / texSize;
        float3 r = 0;
        r += tex.sample(s, float2(t0.x,  t0.y),  level(0)).rgb * w0.x  * w0.y;
        r += tex.sample(s, float2(t12.x, t0.y),  level(0)).rgb * w12.x * w0.y;
        r += tex.sample(s, float2(t3.x,  t0.y),  level(0)).rgb * w3.x  * w0.y;
        r += tex.sample(s, float2(t0.x,  t12.y), level(0)).rgb * w0.x  * w12.y;
        r += tex.sample(s, float2(t12.x, t12.y), level(0)).rgb * w12.x * w12.y;
        r += tex.sample(s, float2(t3.x,  t12.y), level(0)).rgb * w3.x  * w12.y;
        r += tex.sample(s, float2(t0.x,  t3.y),  level(0)).rgb * w0.x  * w3.y;
        r += tex.sample(s, float2(t12.x, t3.y),  level(0)).rgb * w12.x * w3.y;
        r += tex.sample(s, float2(t3.x,  t3.y),  level(0)).rgb * w3.x  * w3.y;
        return clamp(r, 0.0, 1.0);
    }

    float crWeight(float x) {
        x = abs(x);
        if (x < 1.0) return (1.5 * x - 2.5) * x * x + 1.0;
        if (x < 2.0) return ((-0.5 * x + 2.5) * x - 4.0) * x + 2.0;
        return 0.0;
    }

    // Shrink the supersampled eye image onto one output pixel with a Catmull-Rom kernel (`scale`
    // texels per kernel unit, ≤ 1.5, so 6x6 texels cover it). A single bilinear tap's result depends
    // on where it lands between texels, and that phase drifts as the head moves: text shimmers.
    // Clamped to the range of the texels within one kernel unit, so edges get no halos. Reads are
    // gamma-encoded (see warpFragment). Fixed size and unrolled: 3x faster than a dynamic loop.
    float3 downsample(texture2d<float> eye, float2 uv, float scale) {
        float2 size = float2(eye.get_width(), eye.get_height());
        float2 p = uv * size - 0.5;
        float2 base = floor(p);
        float2 f = p - base;
        float wx[6], wy[6];
        #pragma unroll
        for (int k = 0; k < 6; k++) { wx[k] = crWeight((float(k - 2) - f.x) / scale); wy[k] = crWeight((float(k - 2) - f.y) / scale); }
        int2 b = int2(base) - 2, hiIdx = int2(size) - 1;
        float3 acc = 0.0, lo = 1.0, hi = 0.0;
        #pragma unroll
        for (int j = 0; j < 6; j++) {
            int ty = clamp(b.y + j, 0, hiIdx.y);
            float3 row = 0.0;
            #pragma unroll
            for (int i = 0; i < 6; i++) {
                float3 c = eye.read(uint2(clamp(b.x + i, 0, hiIdx.x), ty)).rgb;
                row += c * wx[i];
                if (i >= 1 && i <= 4 && j >= 1 && j <= 4 && abs(float(i - 2) - f.x) <= scale && abs(float(j - 2) - f.y) <= scale) { lo = min(lo, c); hi = max(hi, c); }
            }
            acc += row * wy[j];
        }
        float sx = 0.0, sy = 0.0;
        for (int k = 0; k < 6; k++) { sx += wx[k]; sy += wy[k]; }
        return clamp(acc / max(sx * sy, 1e-4), lo, hi);
    }

    // --- Final pass: ideal image → glasses, through the lens-distortion map.
    struct WarpUniforms {
        float2 outputSize;
        float2 toCalibrated;
        float mapStep;
        float margin;
        float2 mapSize;
        float2 eyeSize;
        float lensOn;
        float originX;
        float filter;
        float kernelWidth;
    };

    struct WOut { float4 position [[position]]; };

    vertex WOut warpVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);   // full-screen triangle
        WOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    fragment float4 warpFragment(WOut in [[stage_in]], constant WarpUniforms& w [[buffer(0)]],
                                 texture2d<float> eye [[texture(0)]], texture2d<float> map [[texture(1)]],
                                 sampler s [[sampler(0)]]) {
        float2 p = in.position.xy - float2(w.originX, 0.0);   // pixel centre within this eye's image
        float2 ideal = p;
        if (w.lensOn > 0.5) {
            float2 pc = p * w.toCalibrated;              // calibration px
            float2 muv = (pc / w.mapStep + 0.5) / w.mapSize;
            ideal = map.sample(s, muv).xy / w.toCalibrated;
        }
        float2 uv = (ideal + w.margin) / w.eyeSize;
        // `eye` is read gamma-encoded: shrinking in gamma space keeps text as heavy as it is on a
        // real screen. In linear light, light-on-dark text came out ~5% heavier (a glow) and
        // dark-on-light ~9% thinner (measured against the same text drawn natively at 1x).
        float3 c = w.filter < 0.5 ? eye.sample(s, uv).rgb : downsample(eye, uv, w.kernelWidth);
        return float4(select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045), 1.0);
    }

    // Strip of `segments` columns bent onto the layout cylinder.
    vertex VOut panelVertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
        float col = float(vid >> 1);
        bool top = (vid & 1) == 1;
        float uLocal = col / u.segments;
        float vLocal = top ? 0.0 : 1.0;
        float uCoord = mix(u.uvMin.x, u.uvMax.x, uLocal);
        float vCoord = mix(u.uvMin.y, u.uvMax.y, vLocal);
        float s = u.arcCenter + (uCoord - 0.5) * u.width;
        float y = u.height + (0.5 - vCoord) * u.panelHeight;
        float3 p;
        if (u.radius > 0.0) {
            float theta = s / u.radius;
            p = float3(u.radius * sin(theta), y, (u.radius - u.distance) - u.radius * cos(theta));
        } else {
            p = float3(s, y, -u.distance);
        }
        VOut o;
        o.position = u.viewProj * float4(p, 1.0);
        o.uv = u.mode > 0.5 ? float2(uLocal, vLocal) : float2(uCoord, vCoord);
        return o;
    }

    fragment float4 panelFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
        if (u.mode > 0.5) {
            return tex.sample(smp, in.uv);   // cursor: premultiplied RGBA
        }
        // Rounded-rectangle mask in panel units (height = 1).
        float aspect = u.width / u.panelHeight;
        float2 size = float2(aspect, 1.0);
        float2 p = (in.uv - 0.5) * size;
        float2 q = abs(p) - (size * 0.5 - u.cornerRadius);
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - u.cornerRadius;
        float aa = max(fwidth(d), 1e-5);
        float alpha = 1.0 - smoothstep(-aa, aa, d);
        if (alpha <= 0.0) discard_fragment();

        float3 color;
        if (u.hasTexture > 0.5) {
            // Footprint of one output pixel on the screen texture (texels). < 1 = magnified.
            float2 texSize = float2(tex.get_width(), tex.get_height());
            float2 dxT = dfdx(in.uv) * texSize, dyT = dfdy(in.uv) * texSize;
            float footprint = max(length(dxT), length(dyT)) * u.pixelScale;
            float3 c = tex.sample(smp, in.uv).rgb;
            if (footprint < 1.2) {
                // Magnified / ~1:1: Catmull-Rom bicubic keeps text edges crisp between pixels.
                float3 bc = catmullRom(tex, smp, in.uv, texSize);
                c = mix(bc, c, smoothstep(0.9, 1.2, footprint));
            }
            if (u.sharpen > 0.001) {
                // Unsharp mask sized to one output pixel's footprint on the texture.
                float2 dx = dfdx(in.uv) * u.pixelScale, dy = dfdy(in.uv) * u.pixelScale;
                float3 n = tex.sample(smp, in.uv + dy).rgb;
                float3 so = tex.sample(smp, in.uv - dy).rgb;
                float3 e = tex.sample(smp, in.uv + dx).rgb;
                float3 w = tex.sample(smp, in.uv - dx).rgb;
                float3 blur = (n + so + e + w) * 0.25;
                float3 mn = min(c, min(min(n, so), min(e, w)));
                float3 mx = max(c, max(max(n, so), max(e, w)));
                c = clamp(c + (c - blur) * (u.sharpen * 1.6), mn, mx);   // clamped: no halos
            }
            color = c;
        } else {
            // Placeholder while the screen is starting: dim panel with a subtle grid.
            float2 g = abs(fract(in.uv * float2(16.0, 9.0)) - 0.5);
            float line = 1.0 - smoothstep(0.46, 0.5, max(g.x, g.y));
            color = mix(float3(0.10, 0.11, 0.13), float3(0.05, 0.055, 0.065), line);
        }
        color *= (1.0 - u.dim);

        // Accent ring on the screen that has the cursor.
        // ~1.5 px at typical sizes, independent of panel resolution (aa is one pixel in panel units).
        float bw = 1.5 * aa * u.pixelScale;
        float ring = smoothstep(-bw - aa, -bw, d);
        color = mix(color, float3(0.30, 0.62, 1.0), ring * u.highlight * 0.85);

        return float4(color * alpha, alpha);
    }

    // --- Direct renderer: glasses pixel → lens map → ray → curved screen wall → one filtered sample.
    struct DPanel { float arcCenter; float height; float width; float panelHeight;
                    float highlight; float dim; float hasTexture; float hasCursor; float4 cursorRect; };
    struct DUniforms {
        float4x4 invView;
        float2 focal; float2 center;
        float2 toCalibrated; float2 mapSize;
        float mapStep; float lensOn; float originX; float radius;
        float distance; float cornerRadius; float sharpen; float quality;
        float panelCount; float subpixel; float subpixelStrength; float frame;
        float motion; float dither; float scanRows; float scanDir;
        float4 white;   // white-point (warmth) multipliers, linear light
        float4 scan;    // head rotation (eye frame, radians) over one scan-out
    };

    // Eye-local output pixel → point on the layout surface: (arc length, height). false = no hit.
    bool surfaceAt(float2 px, constant DUniforms& u, texture2d<float> map, sampler lin, thread float2& sy) {
        float2 pc = px * u.toCalibrated;
        float2 ideal = pc;
        if (u.lensOn > 0.5) ideal = map.sample(lin, (pc / u.mapStep + 0.5) / u.mapSize).xy;
        float3 dcam = float3((ideal.x - u.center.x) / u.focal.x, (u.center.y - ideal.y) / u.focal.y, -1.0);
        // The display lights its rows one after another, not all at once: while the head turns, a
        // row lit later must be drawn for where the head will be then. The pose is predicted for
        // the middle row; each row's ray turns by its share of the scan-out's rotation.
        if (u.scanRows > 0.0) {
            float row = u.scanDir > 0.0 ? pc.y : u.scanRows - pc.y;
            dcam += (row / u.scanRows - 0.5) * cross(u.scan.xyz, dcam);
        }
        float3 o = (u.invView * float4(0.0, 0.0, 0.0, 1.0)).xyz;
        float3 d = normalize((u.invView * float4(dcam, 0.0)).xyz);
        if (u.radius > 0.0) {
            float c = u.radius - u.distance;          // cylinder axis: x = 0, z = c
            float oz = o.z - c;
            float a = d.x * d.x + d.z * d.z;
            float b = 2.0 * (o.x * d.x + oz * d.z);
            float cc = o.x * o.x + oz * oz - u.radius * u.radius;
            float disc = b * b - 4.0 * a * cc;
            if (disc < 0.0 || a < 1e-8) return false;
            float t = (-b + sqrt(disc)) / (2.0 * a);
            if (t <= 0.0) return false;
            float3 p = o + t * d;
            sy = float2(atan2(p.x, c - p.z) * u.radius, p.y);
        } else {
            if (d.z > -1e-5) return false;
            float t = (-u.distance - o.z) / d.z;
            sy = (o + t * d).xy;
        }
        return true;
    }

    float2 panelUV(DPanel p, float2 sy) {
        return float2((sy.x - p.arcCenter) / p.width + 0.5, 0.5 - (sy.y - p.height) / p.panelHeight);
    }

    // Catmull-Rom shrink, kernel `scale` texels per unit (1..1.5): 6x6 texels, clamped to the texels
    // within one unit (no halos).
    float3 crShrink(texture2d<float> tex, float2 uv, float scale) {
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 p = uv * size - 0.5;
        float2 base = floor(p);
        float2 f = p - base;
        float wx[6], wy[6];
        for (int k = 0; k < 6; k++) { wx[k] = crWeight((float(k - 2) - f.x) / scale); wy[k] = crWeight((float(k - 2) - f.y) / scale); }
        int2 b = int2(base) - 2, hiIdx = int2(size) - 1;
        float3 acc = 0.0, lo = 1.0, hi = 0.0;
        for (int j = 0; j < 6; j++) {
            int ty = clamp(b.y + j, 0, hiIdx.y);
            float3 row = 0.0;
            for (int i = 0; i < 6; i++) {
                float3 c = tex.read(uint2(clamp(b.x + i, 0, hiIdx.x), ty)).rgb;
                row += c * wx[i];
                if (i >= 1 && i <= 4 && j >= 1 && j <= 4 && abs(float(i - 2) - f.x) <= scale && abs(float(j - 2) - f.y) <= scale) {
                    lo = min(lo, c); hi = max(hi, c);
                }
            }
            acc += row * wy[j];
        }
        float sx = 0.0, sy = 0.0;
        for (int k = 0; k < 6; k++) { sx += wx[k]; sy += wy[k]; }
        return clamp(acc / max(sx * sy, 1e-4), lo, hi);
    }

    // One screen sample, filtered for how many texels this pixel covers (gamma-space values).
    float3 shadeScreen(texture2d<float> tex, sampler smp, float2 uv, float2 duvx, float2 duvy, float sharpen, float quality) {
        float2 texSize = float2(tex.get_width(), tex.get_height());
        float footprint = max(length(duvx * texSize), length(duvy * texSize));
        float3 c;
        if (quality < 1.25) {
            c = tex.sample(smp, uv, gradient2d(duvx, duvy)).rgb;
        } else if (footprint < 1.2) {
            float3 bc = catmullRom(tex, smp, uv, texSize);
            float3 bl = tex.sample(smp, uv, level(0)).rgb;
            c = mix(bc, bl, smoothstep(0.9, 1.2, footprint));
        } else if (footprint < 3.2) {
            c = crShrink(tex, uv, clamp(footprint * 0.75, 1.0, 1.5));
        } else {
            c = tex.sample(smp, uv, gradient2d(duvx, duvy)).rgb;
        }
        if (sharpen > 0.001 && footprint < 3.2) {
            float3 n = tex.sample(smp, uv + duvy, level(0)).rgb;
            float3 so = tex.sample(smp, uv - duvy, level(0)).rgb;
            float3 e = tex.sample(smp, uv + duvx, level(0)).rgb;
            float3 w = tex.sample(smp, uv - duvx, level(0)).rgb;
            float3 blur = (n + so + e + w) * 0.25;
            float3 mn = min(c, min(min(n, so), min(e, w)));
            float3 mx = max(c, max(max(n, so), max(e, w)));
            c = clamp(c + (c - blur) * (sharpen * 1.6), mn, mx);
        }
        return c;
    }

    // Subpixel rendering (as ClearType does): each pixel is three colored lights side by side, so each
    // channel is sampled at its own light's position, a third of a pixel apart. That roughly triples
    // the detail across the stripes for text edges. A 1-2-1 blend over neighbouring subpixel
    // positions keeps color fringes down. `mode`: 1 RGB / 2 BGR across, 3 RGB / 4 BGR down.
    float3 shadeSubpixel(texture2d<float> tex, sampler smp, float2 uv, float2 duvx, float2 duvy, int mode, float strength) {
        float2 texSize = float2(tex.get_width(), tex.get_height());
        float2 step = (mode <= 2 ? duvx : duvy) / 3.0;        // one subpixel, in UV
        float order = (mode == 1 || mode == 3) ? 1.0 : -1.0;   // red on the low side for RGB
        float3 s[5];
        for (int k = 0; k < 5; k++) {
            float2 q = clamp(uv + step * float(k - 2), 0.0, 1.0);
            s[k] = catmullRom(tex, smp, q, texSize);
        }
        // Red sits one subpixel toward the low side (RGB) or high side (BGR), blue opposite.
        int r = order > 0 ? 1 : 3, b = order > 0 ? 3 : 1;
        // Strength 0: 1-2-1 blend with the neighbouring subpixels. 1: only the channel's own subpixel.
        float side = 0.25 * (1.0 - clamp(strength, 0.0, 1.0)), mid = 1.0 - 2.0 * side;
        float red = side * s[r - 1].r + mid * s[r].r + side * s[r + 1].r;
        float green = side * s[1].g + mid * s[2].g + side * s[3].g;
        float blue = side * s[b - 1].b + mid * s[b].b + side * s[b + 1].b;
        return float3(red, green, blue);
    }

    // While the picture moves across the display the eye can't resolve fine detail, and sharp
    // filters make edges crawl: a soft 4-tap box over the pixel's footprint (each bilinear tap
    // averages 2x2 texels) looks calm and costs a tenth of the still-picture filter.
    float3 shadeMoving(texture2d<float> tex, sampler smp, float2 uv, float2 duvx, float2 duvy) {
        float2 a = 0.25 * (duvx + duvy), b = 0.25 * (duvx - duvy);
        return 0.25 * (tex.sample(smp, clamp(uv + a, 0.0, 1.0), level(0)).rgb + tex.sample(smp, clamp(uv - a, 0.0, 1.0), level(0)).rgb
                     + tex.sample(smp, clamp(uv + b, 0.0, 1.0), level(0)).rgb + tex.sample(smp, clamp(uv - b, 0.0, 1.0), level(0)).rgb);
    }

    // Contrast-adaptive sharpening (the idea behind AMD FidelityFX CAS): sharpen by how much room the
    // neighbourhood leaves, so soft edges get crisper while already-crisp edges and flat areas are
    // left alone: no halos, no crunch. `c` is this pixel's (subpixel-rendered) color; the four
    // neighbours are one output pixel away. `amount` 0…1 (the Sharpen slider).
    float3 casSharpen(texture2d<float> tex, sampler smp, float2 uv, float2 duvx, float2 duvy, float3 c, float amount) {
        float3 n = tex.sample(smp, uv - duvy, level(0)).rgb;
        float3 s = tex.sample(smp, uv + duvy, level(0)).rgb;
        float3 e = tex.sample(smp, uv + duvx, level(0)).rgb;
        float3 w = tex.sample(smp, uv - duvx, level(0)).rgb;
        // One weight from brightness for all three channels: per-channel weights next to subpixel
        // color turned into colored noise. The peak stays in CAS's range (-1/8 … -1/5), so the
        // divisor never drops below 0.2 (at -1/4 it reached zero: garbage pixels at 100%).
        const float3 luma = float3(0.299, 0.587, 0.114);
        float lc = dot(c, luma), ln = dot(n, luma), ls = dot(s, luma), le = dot(e, luma), lw = dot(w, luma);
        float mn = min(lc, min(min(ln, ls), min(le, lw)));
        float mx = max(lc, max(max(ln, ls), max(le, lw)));
        float amp = sqrt(clamp(min(mn, 1.0 - mx) / max(mx, 1e-4), 0.0, 1.0));
        float wgt = amp * (-1.0 / mix(8.0, 5.0, clamp(amount, 0.0, 1.0)));
        return clamp((c + (n + s + e + w) * wgt) / max(1.0 + 4.0 * wgt, 0.2), 0.0, 1.0);
    }

    float3 toLinear(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }

    fragment float4 directFragment(WOut in [[stage_in]], constant DUniforms& u [[buffer(0)]], constant DPanel* panels [[buffer(1)]],
                                   texture2d<float> map [[texture(0)]], texture2d<float> cursor [[texture(1)]],
                                   array<texture2d<float>, 8> screens [[texture(2)]],
                                   sampler smp [[sampler(0)]], sampler lin [[sampler(1)]]) {
        float2 px = in.position.xy - float2(u.originX, 0.0);
        float2 sy, syx, syy;
        if (!surfaceAt(px, u, map, lin, sy)) return float4(0.0, 0.0, 0.0, 1.0);
        bool hx = surfaceAt(px + float2(1.0, 0.0), u, map, lin, syx);
        bool hy = surfaceAt(px + float2(0.0, 1.0), u, map, lin, syy);
        int n = min(int(u.panelCount), 8);
        for (int i = 0; i < n; i++) {
            DPanel p = panels[i];
            float2 uv = panelUV(p, sy);
            if (uv.x < -0.02 || uv.y < -0.02 || uv.x > 1.02 || uv.y > 1.02) continue;
            float2 duvx = hx ? panelUV(p, syx) - uv : float2(0.0);
            float2 duvy = hy ? panelUV(p, syy) - uv : float2(0.0);
            // Rounded-rectangle mask in panel units (height = 1), antialiased over one pixel.
            float2 size = float2(p.width / p.panelHeight, 1.0);
            float2 q = abs((uv - 0.5) * size) - (size * 0.5 - u.cornerRadius);
            float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - u.cornerRadius;
            float aa = max(max(length(duvx * size), length(duvy * size)), 1e-5);
            float alpha = 1.0 - smoothstep(-0.5 * aa, 0.5 * aa, dist);
            if (alpha <= 0.0) continue;
            float3 color;
            if (p.hasTexture > 0.5) {
                // Still: the sharpest filters (subpixel, sharpening). Moving: they make edges crawl,
                // so blend to the calm filter by how fast the picture moves across the display.
                float3 sharp = 0.0, calm = 0.0;
                if (u.motion < 0.999) {
                    if (u.subpixel > 0.5) {
                        sharp = shadeSubpixel(screens[i], smp, uv, duvx, duvy, int(u.subpixel), u.subpixelStrength);
                        if (u.sharpen > 0.001) sharp = casSharpen(screens[i], smp, clamp(uv, 0.0, 1.0), duvx, duvy, sharp, u.sharpen);
                    } else {
                        sharp = shadeScreen(screens[i], smp, clamp(uv, 0.0, 1.0), duvx, duvy, u.sharpen, u.quality);
                    }
                }
                if (u.motion > 0.001) calm = u.quality < 1.25 ? shadeScreen(screens[i], smp, clamp(uv, 0.0, 1.0), duvx, duvy, 0.0, u.quality)
                                                              : shadeMoving(screens[i], smp, uv, duvx, duvy);
                color = mix(sharp, calm, u.motion);
            } else {
                float2 g = abs(fract(uv * float2(16.0, 9.0)) - 0.5);
                float line = 1.0 - smoothstep(0.46, 0.5, max(g.x, g.y));
                color = mix(float3(0.35, 0.37, 0.40), float3(0.25, 0.26, 0.28), line);   // gamma values of the old placeholder
            }
            if (p.hasCursor > 0.5) {
                float2 rs = p.cursorRect.zw - p.cursorRect.xy;
                float2 cuv = (uv - p.cursorRect.xy) / rs;
                if (all(cuv >= 0.0) && all(cuv <= 1.0)) {
                    float4 cc = cursor.sample(smp, cuv, gradient2d(duvx / rs, duvy / rs));   // premultiplied
                    // Softened with the screens while the picture moves: a small, razor-sharp, high-
                    // contrast cursor is where the eye catches every frame step, so it read as stutter.
                    if (u.motion > 0.001) {
                        float2 ca = 0.25 * (duvx + duvy) / rs, cb = 0.25 * (duvx - duvy) / rs;
                        float4 box = 0.25 * (cursor.sample(smp, cuv + ca, level(0)) + cursor.sample(smp, cuv - ca, level(0))
                                           + cursor.sample(smp, cuv + cb, level(0)) + cursor.sample(smp, cuv - cb, level(0)));
                        cc = mix(cc, box, u.motion);
                    }
                    color = cc.rgb + color * (1.0 - cc.a);
                }
            }
            // Dimming and the accent ring in linear light, exactly like the two-pass renderer
            // (dimming in gamma space came out far darker at the same setting).
            float3 lin = toLinear(color) * (1.0 - p.dim);
            float ring = smoothstep(-2.5 * aa, -1.5 * aa, dist);   // ~1.5 px, on the screen with the cursor
            lin = mix(lin, float3(0.30, 0.62, 1.0), ring * p.highlight * 0.85);
            lin *= alpha * u.white.rgb;
            if (u.dither > 0.5) {
                // Temporal dithering (interleaved gradient noise, two taps → triangular, ±1 step of
                // the 8-bit output, new every frame): gradients stop banding; the eye averages it away.
                float2 q = in.position.xy + u.frame * float2(5.588238, 5.588238);
                float n1 = fract(52.9829189 * fract(dot(q, float2(0.06711056, 0.00583715))));
                float n2 = fract(52.9829189 * fract(dot(q + float2(47.0, 17.0), float2(0.06711056, 0.00583715))));
                float3 e = select(1.055 * pow(lin, 1.0 / 2.4) - 0.055, 12.92 * lin, lin <= 0.0031308);
                e = clamp(e + (n1 + n2 - 1.0) / 255.0, 0.0, 1.0);
                lin = toLinear(e);
            }
            return float4(lin, 1.0);
        }
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    """
}
