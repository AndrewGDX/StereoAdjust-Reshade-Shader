// Stereo_Adjust.fx
#include "ReShade.fxh"

uniform float Shift <
    ui_category = "Screen Shift";
    ui_type = "slider";
    ui_label = "Shift";
    ui_tooltip = "Move screens in X axis";
    ui_min = -30; ui_max = 30; ui_step = 1.0;
>;

uniform float Tilt <
    ui_category = "Screen Shift";
    ui_type = "slider";
    ui_label = "Tilt";
    ui_tooltip = "Move screens in Y axis";
    ui_min = -10; ui_max = 10; ui_step = 1.0;
>;

uniform float Vignette_Size <
    ui_category = "Vignette";
    ui_type = "slider";
    ui_label = "Vignette Size";
    ui_min = 0.0; ui_max = 1; ui_step = 0.01;
> = 0.13;

uniform float Vignette_X <
    ui_category = "Vignette";
    ui_type = "slider";
    ui_label = "X Strength";
    ui_tooltip = "Horizontal vignette strength";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 0.75;

uniform float Vignette_Y <
    ui_category = "Vignette";
    ui_type = "slider";
    ui_label = "Y Strength";
    ui_tooltip = "Vertical vignette strength";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
> = 0.50;

uniform bool Extend_Edges <
    ui_category = "Edge Extend";
    ui_label = "Extend Edges";
    ui_tooltip = "Entend edges of the screen to fill black border";
> = false;

uniform float Extend_Border <
    ui_category = "Edge Extend";
    ui_type = "slider";
    ui_label = "Extend Border";
    ui_tooltip = "How many pixels to cut of the edge";
    ui_min = 0.0; ui_max = 0.1; ui_step = 0.0001;
>;

uniform float Cut_Offset <
    ui_category = "Edge Extend";
    ui_type = "slider";
    ui_label = "Cut border";
    ui_tooltip = "Parameter to cut extended edges of the screen";
    ui_min = 0.0; ui_max = 200.0; ui_step = 1;
>;

uniform float Vignette_Offset <
    ui_category = "Edge Extend";
    ui_type = "slider";
    ui_label = "Vignette Offset";
    ui_tooltip = "Parameter to offset vignette (useful for 4:3 screens)";
    ui_min = 0.0; ui_max = 250.0; ui_step = 1;
>;

// --- Helper Functions ---
float3 srgb_to_linear(float3 color_srgb) { return pow(max(0.0, color_srgb), 2.2); }
// Standard linear to sRGB (gamma 2.2 encoding)
float3 linear_to_srgb(float3 color_linear) { return pow(max(0.0, color_linear), 1.0 / 2.2); }
// Linear to sRGB with dynamic exponent
float3 linear_to_srgb_dynamic(float3 color_linear, float exponent) { return pow(max(0.0, color_linear), exponent); }

float GetLuminance(float3 color_linear) { return dot(color_linear, float3(0.2126, 0.7152, 0.0722)); }
float AdjustLuminanceContrast(float lum, float contrast, float midpoint) { return lerp(midpoint, lum, contrast); }

uniform bool EnableAutoGamma <
    ui_category = "Color Correction";
    ui_label = "Enable Luminance Contrast";
> = false;

uniform float ContrastIntensity <
    ui_category = "Color Correction";
    ui_type = "slider";
    ui_label = "Contrast Intensity";
    ui_tooltip = "Maximum contrast boost applied to mid-tones (1.0 = none, >1.0 increases contrast).";
    ui_min = 0.01; ui_max = 1.0; ui_step = 0.01;
> = 0.92;

uniform float MidpointFocus <
    ui_category = "Color Correction";
    ui_type = "slider";
    ui_label = "Focus (Sharpness)";
    ui_tooltip = "Controls how quickly the contrast effect falls off away from the mid-tones.";
    ui_min = 1.0; ui_max = 8.0; ui_step = 0.1;
> = 2.0;

uniform float ContrastMidpoint <
    ui_category = "Color Correction";
    ui_type = "slider";
    ui_label = "Luminance Midpoint";
    ui_tooltip = "Luminance value considered the center for contrast adjustment.";
    ui_min = 0.5; ui_max = 1.5; ui_step = 0.01;
> = 0.5;

uniform float GammaCompStrength < // ** NEW SLIDER **
    ui_category = "Color Correction";
    ui_type = "slider";
    ui_label = "Auto Gamma Comp. Strength";
    ui_tooltip = "Strength of the automatic gamma compensation (0=off, 1=full attempt). EXPERIMENTAL.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 1; // Default: Moderate compensation attempt

float4 AutoGamma(float2 texcoord, float4 color)
{
    // 1. Get Base Color & Convert to Linear
    float3 color_linear = srgb_to_linear(color.rgb);

    // Store initial linear color
    float3 processed_linear = color_linear;
    float pixelLumLinear = GetLuminance(color_linear); // Original luminance
    float gammaCorrectionFactor = 1.0; // Default: no correction

    // 2. Calculate Contrast Modulation Factor
    float distFromMid = abs(pixelLumLinear - ContrastMidpoint);
    float normRange = max(ContrastMidpoint, 1.0 - ContrastMidpoint);
    float distScaled = saturate(distFromMid / max(normRange, 1e-6));
    float falloff = pow(distScaled, MidpointFocus);
    float contrastModulationFactor = saturate(1.0 - falloff);

    // 3. Calculate and Apply Contrast if factor > 0
    if (contrastModulationFactor > 0.0)
    {
        float dynamicContrast = lerp(1.0, ContrastIntensity, contrastModulationFactor);
        float adjustedLum = AdjustLuminanceContrast(pixelLumLinear, dynamicContrast, ContrastMidpoint);
        adjustedLum = max(0.0, adjustedLum);

        // 4. Calculate Per-Pixel Gamma Compensation Factor (EXPERIMENTAL)
        //    Estimate how much the contrast changed the luminance relative to linear
        float luminanceRatio = adjustedLum / max(pixelLumLinear, 1e-6); // Ratio > 1 means brighter, < 1 means darker

        //    Convert ratio to an approximate EV shift (log2)
        float evShift = log2(max(luminanceRatio, 1e-6));

        //    Calculate a gamma adjustment exponent. We want to counteract the shift.
        //    If evShift > 0 (brighter), we need exponent > (1/2.2) -> higher gamma value in UI terms (darker correction)
        //    If evShift < 0 (darker), we need exponent < (1/2.2) -> lower gamma value in UI terms (brighter correction)
        //    This needs careful scaling. Let's try scaling the *deviation* from standard encoding.
        float base_exponent = 1.0 / 2.2;
        //    Simple scaling: scale the shift by strength and add to base exponent? Might be too strong.
        //    Let's try scaling the *adjustment* factor relative to 1.0 (like the Gamma slider logic).
        //    gammaCorrectionFactor ranges from e.g. 0.5 to 1.5 based on evShift.
        //    Need a mapping function: map evShift (e.g., -1 to +1) to gammaCorrectionFactor (e.g., 1.5 to 0.5)
        //    Let's try: CompFactor = 1.0 - (evShift * CompStrength * Scale). Needs tuning.
        //    Using a simplified approach like the manual slider:
        gammaCorrectionFactor = 1.0 - (evShift * GammaCompStrength * 0.25); // Scaled by 0.25, adjust as needed
        gammaCorrectionFactor = clamp(gammaCorrectionFactor, 0.5, 1.5); // Clamp to reasonable range


        // 5. Reconstruct Color using adjusted luminance
        if (pixelLumLinear <= 1e-6) {
            processed_linear = 0.0;
        } else {
            processed_linear = color_linear * luminanceRatio; // Apply contrast change
        }
    }

    // 6. Apply Final Gamma Correction & Convert back to sRGB
    float final_exponent = (1.0 / 2.2) / gammaCorrectionFactor; // Apply the calculated correction factor
    float3 final_srgb = linear_to_srgb_dynamic(processed_linear, final_exponent);

    return float4(saturate(final_srgb), color.a);
}

uniform bool EnableLuminanceBlend <
    ui_category = "Color Correction";
    ui_label = "Enable Luminance Blend";
> = false;

uniform float Opacity <
    ui_category = "Color Correction";
    ui_type = "slider";
    ui_label = "Max Opacity / Strength";
    ui_tooltip = "Controls the maximum strength of the self-blend effect (at the luminance midpoint)";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.22;

uniform float MidpointFocus2 <
    ui_category = "Color Correction";
    ui_type = "slider";
    ui_label = "Focus (Sharpness)";
    ui_tooltip = "Controls how quickly the blend effect falls off away from the midpoint.";
    ui_min = 1.0; ui_max = 8.0; ui_step = 0.1;
> = 8.0;

uniform float LuminanceMidpoint <
    ui_category = "Color Correction";
    ui_type = "slider";
    ui_label = "Luminance Midpoint";
    ui_tooltip = "Luminance value considered the center for maximum blend strength.";
    ui_min = 0.4; ui_max = 0.5; ui_step = 0.001;
> = 0.5;

float CalculateModulationFactor(float pixelLum, float targetPoint, float focus)
{
    float distFromPoint = abs(pixelLum - targetPoint);
    float normRange = max(targetPoint, 1.0 - targetPoint);
    float distScaled = saturate(distFromPoint / max(normRange, 1e-6));
    float falloff = pow(distScaled, focus);
    return saturate(1.0 - falloff); // 1 near targetPoint, 0 far
}

float3 ApplyBlend(float3 base, float3 blend){ float3 r; r.r=(base.r<0.5)?(2.0*base.r*blend.r):(1.0-2.0*(1.0-base.r)*(1.0-blend.r)); r.g=(base.g<0.5)?(2.0*base.g*blend.g):(1.0-2.0*(1.0-base.g)*(1.0-blend.g)); r.b=(base.b<0.5)?(2.0*base.b*blend.b):(1.0-2.0*(1.0-base.b)*(1.0-blend.b)); return r; }

float3 LuminanceBlend(float3 color)
{
    float pixelLumLinear = GetLuminance(srgb_to_linear(color));
    float blendModFactor = CalculateModulationFactor(pixelLumLinear, LuminanceMidpoint, MidpointFocus2);

    if (blendModFactor <= 0.0) {
        return color;
    }

    float3 blended_full = ApplyBlend(color, color);
    float actualOpacity = Opacity * blendModFactor;

    return saturate(lerp(color, saturate(blended_full), actualOpacity));
}

uniform bool EnableLevels <
    ui_category = "Color Correction";
    ui_label = "Enable Levels";
> = false;

uniform float BlackLevel <
    ui_category = "Color Correction";
    ui_type = "slider";
    ui_label = "Black Level";
    ui_min = 0; ui_max = 16.0; ui_step = 1;
> = 0.0;

uniform float WhiteLevel <
    ui_category = "Color Correction";
    ui_type = "slider";
    ui_label = "White Level";
    ui_min = 0; ui_max = 32.0; ui_step = 1;
> = 0.0;

uniform float Temperature <
    ui_category = "Color Correction";
    ui_label = "Temperature";
    ui_type = "slider";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

float3 Levels(float3 color)
{
    float black_point = BlackLevel / 255.0;
    float white_point = 255.0 / ((255.0 - WhiteLevel) - BlackLevel);
    color *= float3(1.0 + Temperature * 0.1, 1.0, 1.0 - Temperature * 0.1);
    return saturate(color * white_point - (black_point * white_point));
}

texture2D imgTex : COLOR;
sampler imgSampler { Texture = imgTex; };

float4 PS_StereoFix(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 color = 0;
    float shiftUV = Shift / BUFFER_WIDTH;
    float tiltUV = Tilt / BUFFER_WIDTH;

    if (uv.x < 0.5) {
        if (uv.y < tiltUV || uv.y > 1 + tiltUV) return 0;
    } else {
        if (uv.y < -tiltUV || uv.y > 1 - tiltUV) return 0;
    }

    float offsetX = Vignette_Offset / BUFFER_WIDTH;
    float cutOffsetX = Cut_Offset / BUFFER_WIDTH;
    float fadeWidth = (Vignette_Size + 0.001) / 50.0;

    float outerEdge = smoothstep(0.0, fadeWidth, uv.x - lerp(0, offsetX, Extend_Edges)) 
                * smoothstep(1.0, 1.0 - fadeWidth, uv.x + lerp(0, offsetX, Extend_Edges));
    float innerEdge = smoothstep(0.5, 0.5 - fadeWidth, uv.x + lerp(0, offsetX, Extend_Edges)) 
                + smoothstep(0.5, 0.5 + fadeWidth, uv.x - lerp(0, offsetX, Extend_Edges));

    float horizontalFade = outerEdge * innerEdge;
    float verticalFade = smoothstep(0.0, fadeWidth, uv.y 
                            + lerp(lerp(tiltUV, 0, tiltUV > 0), lerp(-tiltUV, 0, tiltUV < 0), uv.x < 0.5))
                * smoothstep(1.0, 1.0 - fadeWidth, uv.y 
                            + lerp(lerp(tiltUV, 0, tiltUV < 0), lerp(-tiltUV, 0, tiltUV > 0), uv.x < 0.5));

    float outerCut = smoothstep(0.0, 0.01, uv.x - cutOffsetX) * smoothstep(1.0, 0.99, uv.x + cutOffsetX);
    float innerCut = smoothstep(0.5, 0.49, uv.x + cutOffsetX) + smoothstep(0.5, 0.51, uv.x - cutOffsetX);

    uv.y = lerp(uv.y - tiltUV, uv.y + tiltUV, uv.x > 0.5);
    uv.x = lerp(min(uv.x + shiftUV, 0.498 - lerp(0, Extend_Border, Extend_Edges)), 
                max(uv.x - shiftUV, 0.5 + lerp(0, Extend_Border, Extend_Edges)), uv.x > 0.5);
    uv.x = lerp(uv.x, clamp(uv.x, Extend_Border, 0.998 - Extend_Border), Extend_Edges);

    color = tex2D(imgSampler, uv);

    if (EnableAutoGamma) {
        color = AutoGamma(uv, color);
    }
    if (EnableLuminanceBlend) {
        color.rgb = LuminanceBlend(color.rgb);
    }
    if (EnableLevels) {
        color.rgb = Levels(color.rgb);
    }
    color *= 1.0 - max(Vignette_X * (1.0 - horizontalFade), Vignette_Y * (1.0 - verticalFade)) 
            - lerp(0, 1.0 - outerCut * innerCut, Extend_Edges && Cut_Offset);
    
    return color;
}

technique Stereo_Adjust
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_StereoFix;
    }
}
