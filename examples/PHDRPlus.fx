/*-----------------------------------------------------------|
| ::                 Perceptual HDR Plus                  :: |
'------------------------------------------------------------|
|  Perceptual HDR Plus                                       |
|  Version: 2.0                                              |
|                                                            |
|  Original PHDR (v1.1) by BarbatosBachiko:                  |
|    https://github.com/BarbatosBachiko/Reshade-Shaders      |
|  Based on: https://github.com/ray075hl/singleLDR2HDR       |
|  Techniques: WLS (Weighted Least Squares smoothing),       |
|    SRS (Selective Reflectance Scaling),                    |
|    VIG (Virtual Illumination Generator),                   |
|    ToneMap (multi-exposure fusion)                         |
|                                                            |
|  Tonal adaptation controls (Lift / Pull sliders)           |
|  derived from the EyeAdaption.fx technique by              |
|  brussell:                                                 |
|    https://github.com/brussell1/Shaders                    |
|                                                            |
|  Split toning uses the usual grading approach: warm        |
|  highlights, cool shadows.                                 |
|                                                            |
|  License: MIT                                              |
|  Adds to PHDR: per-zone Lift and Pull, split toning, three |
|  contrast bands, Purkinje, debanding and dithering.        |
'------------------------------------------------------------*/

//===========================================================|
// :: Inlined from bb_reshade.fxh                         :: |
// :: Credit: BarbatosBachiko / Reshade-Shaders           :: |
//===========================================================|

#if !defined(__RESHADE__) || __RESHADE__ < 30000
    #error "ReShade 3.0+ is required for this shader"
#endif

#define BUFFER_PIXEL_SIZE   float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT)
// Pixel settings are authored against this screen height and converted at
// the point of use, so a preset covers the same fraction of any monitor.
#define REFERENCE_HEIGHT 1080.0

// A swap chain in scRGB or HDR10 means PHDR Source is converting the frame
// for an SDR monitor, and its Output stage debands and dithers for the 8-bit
// cut Windows makes. Here the frame is float, so there is nothing to deband
// against and those passes are compiled out rather than run for nothing.
#ifndef BUFFER_COLOR_SPACE
    #define BUFFER_COLOR_SPACE 1
#endif
#if BUFFER_COLOR_SPACE == 2 || BUFFER_COLOR_SPACE == 3
    #define PHDRP_HDR_CHAIN 1
#else
    #define PHDRP_HDR_CHAIN 0
#endif

#define BUFFER_SCREEN_SIZE  float2(BUFFER_WIDTH, BUFFER_HEIGHT)
#define BUFFER_ASPECT_RATIO (BUFFER_WIDTH * BUFFER_RCP_HEIGHT)

namespace bb
{
    static const float  AspectRatio = BUFFER_WIDTH * BUFFER_RCP_HEIGHT;
    static const float2 PixelSize   = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    static const float2 ScreenSize  = float2(BUFFER_WIDTH, BUFFER_HEIGHT);
}

void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
{
    texcoord.x = (id == 2) ? 2.0 : 0.0;
    texcoord.y = (id == 1) ? 2.0 : 0.0;
    position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

// Everything works on gamma encoded SDR values in [0, 1]. On an HDR swap chain
// PHDR Source converts the frame to that form before this shader runs.
static const float3 LUMA_709 = float3(0.2126, 0.7152, 0.0722);

float GetLuminance(float3 color)
{
    return dot(color, LUMA_709);
}

//----------|
// :: UI :: |
//----------|

uniform float Strength <
    ui_type = "slider";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_label = "INTENSITY";
    ui_category = "General";
> = 0.3;

uniform float DynamicIntensity <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.01;
    ui_label = "Dark Scene Fade";
    ui_category = "General";
    ui_tooltip = "Fades the tone fusion out in very dark scenes, where it mostly\n"
                 "amplifies noise. 0 = off, 1 = full fade.";
> = 0.65;

uniform float DarkFadeThreshold <
    ui_type = "slider";
    ui_min = 0.01; ui_max = 0.60;
    ui_step = 0.005;
    ui_label = "Dark Scene Fade Threshold";
    ui_category = "General";
    ui_tooltip = "Scene brightness at which the fade has fully released. Scene\n"
                 "brightness is a geometric mean, so a night scene holding lamps or\n"
                 "moonlit stone measures higher than it looks and needs more than a cave.";
> = 0.20;

uniform float Radius <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 30.0;
    ui_label = "Smoothing Radius";
    ui_category = "General";
    ui_tooltip = "Window the base layers are smoothed over, which sets the scale of\n"
                 "everything treated as local. In pixels at 1080p, rescaled to the\n"
                 "running resolution. Wider spreads the shading gradient beside bright\n"
                 "objects until it reads as lighting instead of an outline.";
> = 13.5;

uniform float Epsilon <
    ui_type = "slider";
    ui_min = 0.001; ui_max = 0.005;
    ui_label = "Edge Sensitivity";
    ui_category = "General";
    ui_tooltip = "Guided filter epsilon. Raise it to extract more texture as detail, at\n"
                 "the cost of a darker rim beside bright edges.";
> = 0.001;

uniform float DetailLimit <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 4.0;
    ui_step = 0.05;
    ui_label = "Detail Limit";
    ui_category = "General";
    ui_tooltip = "Ceiling on the local detail term, in stops, on the darkening side\n"
                 "only. Buys back the dark rim around bright objects for a little\n"
                 "detail. 0 disables it.";
> = 0.0;

uniform float Contrast_Micro <
    ui_label = "Micro Contrast Boost";
    ui_category = "General";
    ui_tooltip = "Contrast at the finest scale, close to the pixel grid. Above 0 it\n"
                 "starts to look sharpened; below 0 softens fine texture.";
    ui_type = "slider";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float Contrast_Medium <
    ui_label = "Medium Contrast Boost";
    ui_category = "General";
    ui_tooltip = "Contrast at the scale of objects and their shading. The one to raise\n"
                 "for depth without sharpening.";
    ui_type = "slider";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float Contrast_Macro <
    ui_label = "Macro Contrast Boost";
    ui_category = "General";
    ui_tooltip = "Large-scale depth and scene separation. 0 adds none and 1 passes the\n"
                 "band at full strength, so unlike the other two it cannot go negative.";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float Contrast_Macro_Guard <
    ui_label = "Macro Soft Area Guard";
    ui_category = "General";
    ui_tooltip = "Holds Macro Contrast Boost back in soft, featureless areas such as\n"
                 "clouds, haze and out of focus backgrounds, where it darkens whole\n"
                 "patches into blotches. Textured areas keep it. 0 is off.";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.0;

uniform float Contrast_Shadow_Strength <
    ui_label = "Contrast Shadow Strength";
    ui_category = "General";
    ui_tooltip = "Depth of the dark halo on the shadow side of bright edges, as a\n"
                 "fraction of INTENSITY. This is the etched-outline look, so lower it\n"
                 "if objects look drawn on.";
    ui_type = "drag";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.001;
> = 1.0;

uniform float Contrast_Shadow_Threshold <
    ui_label = "Contrast Shadow Threshold";
    ui_category = "General";
    ui_tooltip = "How much darker than its surroundings a pixel must be before the dark\n"
                 "halo acts. Raise it if soft clouds or out of focus backgrounds look\n"
                 "grainy or blotchy; real edges keep their halo. 0 is off.";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.1; ui_step = 0.001;
> = 0.0;

uniform bool EnableDithering <
    hidden = PHDRP_HDR_CHAIN;
    ui_label = "Enable Dithering";
    ui_category = "Dithering";
    ui_tooltip = "Adds a sub-level noise pattern so gradients quantise smoothly.";
> = true;

uniform float DitherStrength <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "slider";
    ui_min = 0.0; ui_max = 3.0;
    ui_step = 0.01;
    ui_label = "Dither Strength";
    ui_category = "Dithering";
    ui_tooltip = "Dither amplitude in quantisation steps. 1.0 is what the maths asks\n"
                 "for; raise it for visible grain.";
> = 1.0;

uniform int DitherPattern <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "combo";
    ui_items = "Gradient Noise\0Blue Noise Mask\0";
    ui_label = "Dither Pattern";
    ui_category = "Dithering";
    ui_tooltip = "Blue Noise Mask needs dz_stbn_512x256.png in the ReShade Textures\n"
                 "folder and hides better at the same amplitude. Gradient Noise is\n"
                 "computed on the spot and is the fallback.";
> = 1;

uniform bool EnableDeband <
    hidden = PHDRP_HDR_CHAIN;
    ui_label = "Enable Debanding";
    ui_category = "Debanding";
    ui_category_closed = true;
    ui_tooltip = "Rebuilds gradients already quantised into visible steps. Dithering\n"
                 "stops banding forming; this repairs banding that is already there.";
> = true;

uniform float DebandMaxCorrection <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "slider";
    ui_min = 0.5; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Deband Correction Limit";
    ui_category = "Debanding";
    ui_tooltip = "Furthest the debander may move a pixel, in quantisation steps. A band\n"
                 "is a step or two tall, so a much larger correction is averaging away\n"
                 "contrast rather than repairing a step.";
> = 2.0;

uniform float DebandSplit <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "slider";
    ui_min = 0.25; ui_max = 8.0;
    ui_step = 0.05;
    ui_label = "Deband Split Point";
    ui_category = "Debanding";
    ui_tooltip = "How far this shader must have moved a pixel before it is handed to the\n"
                 "Shader Effect settings instead of the Source Image ones, in\n"
                 "quantisation steps. Both run every frame; this is the line between them.";
> = 1.0;

uniform int DebandTaps <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "combo";
    ui_items = "8 samples\0"
               "16 samples\0"
               "24 samples\0"
               "32 samples\0";
    ui_label = "Deband Samples";
    ui_category = "Debanding";
    ui_tooltip = "Samples per pass, spread over a disc. Raise this before raising either\n"
                 "threshold, since a loose threshold is usually a badly measured\n"
                 "neighbourhood.";
> = 1;

// ---- Debanding: what this shader reworked ----

uniform bool EnableDebandEffect <
    hidden = PHDRP_HDR_CHAIN;
    ui_label = "Enable";
    ui_category = "Debanding: Shader Effect";
    ui_tooltip = "Deband this shader's output.";
> = true;

uniform float DebandEffectThreshold <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "slider";
    ui_min = 0.5; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Threshold";
    ui_category = "Debanding: Shader Effect";
    ui_tooltip = "How flat an area must be to count as a band, in quantisation steps.";
> = 1.75;

uniform float DebandEffectRadius <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "slider";
    ui_min = 4.0; ui_max = 64.0;
    ui_step = 1.0;
    ui_label = "Radius";
    ui_category = "Debanding: Shader Effect";
    ui_tooltip = "How far the first pass looks for the true value of a flat area, in\n"
                 "pixels at 1080p. Later passes reach further. Wants to be wider than\n"
                 "the bands themselves.";
> = 13.0;

uniform int DebandEffectIterations <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "slider";
    ui_min = 1; ui_max = 4;
    ui_label = "Passes";
    ui_category = "Debanding: Shader Effect";
    ui_tooltip = "How many passes, each reaching further and judging more strictly.";
> = 2;

uniform float DebandEffectDetail <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "slider";
    ui_min = 0.0; ui_max = 4.0;
    ui_step = 0.05;
    ui_label = "Detail Guard";
    ui_category = "Debanding: Shader Effect";
    ui_tooltip = "How much pixel-to-pixel variation marks an area as texture and puts it\n"
                 "out of reach. Lower if texture is flattened, raise if noisy bands\n"
                 "survive. 0 disables the guard.";
> = 1.0;

// ---- Debanding: what this shader left alone ----

uniform bool EnableDebandSource <
    hidden = PHDRP_HDR_CHAIN;
    ui_label = "Enable";
    ui_category = "Debanding: Source Image";
    ui_tooltip = "Deband the game's own frame, before the effect runs.";
> = true;

uniform float DebandSourceThreshold <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "slider";
    ui_min = 0.5; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Threshold";
    ui_category = "Debanding: Source Image";
    ui_tooltip = "How flat an area must be to count as a band, in quantisation steps.";
> = 1.65;

uniform float DebandSourceRadius <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "slider";
    ui_min = 4.0; ui_max = 64.0;
    ui_step = 1.0;
    ui_label = "Radius";
    ui_category = "Debanding: Source Image";
    ui_tooltip = "How far the first pass looks for the true value of a flat area, in\n"
                 "pixels at 1080p. Later passes reach further.";
> = 12.0;

uniform int DebandSourceIterations <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "slider";
    ui_min = 1; ui_max = 4;
    ui_label = "Passes";
    ui_category = "Debanding: Source Image";
    ui_tooltip = "How many passes, each reaching further and judging more strictly.";
> = 1;

uniform float DebandSourceDetail <
    hidden = PHDRP_HDR_CHAIN;
    ui_type = "slider";
    ui_min = 0.0; ui_max = 4.0;
    ui_step = 0.05;
    ui_label = "Detail Guard";
    ui_category = "Debanding: Source Image";
    ui_tooltip = "How much pixel-to-pixel variation marks an area as texture and puts it\n"
                 "out of reach. 0 disables the guard.";
> = 0.85;

uniform bool EnableAdaptation <
    ui_label = "Enable Eye Adaptation";
    ui_category = "Eye Adaptation";
    ui_category_closed = true;
    ui_tooltip = "Measures scene brightness every frame. Off uses Manual Exposure\n"
                 "instead, which keeps a dark scene from being lifted.";
> = true;

uniform float AdaptationTime <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Eye Adaptation Speed";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Seconds for the eye to adjust to a brightness change.";
> = 0.5;

uniform float DarkAdaptationMult <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 8.0;
    ui_step = 0.1;
    ui_label = "Dark Adaptation Multiplier";
    ui_category = "Eye Adaptation";
    ui_tooltip = "How much slower the eye adapts to darkness than to light.";
> = 2.5;

uniform float AdaptMin <
    ui_type = "slider";
    ui_min = 0.01; ui_max = 0.5;
    ui_step = 0.001;
    ui_label = "Adaptation Floor";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Lower clamp on measured scene brightness, so a near-black frame does\n"
                 "not drag the exposure to the floor. Raise it past the Tonal Neutral\n"
                 "Point and the Lift sliders have nothing to act on.";
> = 0.03;

uniform float AdaptMax <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 0.99;
    ui_step = 0.001;
    ui_label = "Adaptation Ceiling";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Upper clamp on measured scene brightness, so a white flash does not\n"
                 "rail the exposure. Lower it past the Tonal Neutral Point and the Pull\n"
                 "sliders have nothing to act on.";
> = 0.85;

uniform float ManualExposure <
    ui_type = "slider";
    ui_min = 0.001; ui_max = 1.0;
    ui_label = "Manual Exposure";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Scene brightness assumed when Eye Adaptation is off. Lower keeps\n"
                 "dark scenes darker.";
> = 0.1;

uniform float AdaptationStrength <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Eye Adaptation Strength";
    ui_category = "Eye Adaptation";
    ui_tooltip = "How strongly eye adaptation shifts the exposure. 0 measures but does\n"
                 "not apply.";
> = 1.0;

uniform int LumaTextureSize <
    ui_type = "combo";
    ui_label = "Luma Texture Size";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Resolution of the internal luminance texture. Smaller is cheaper and\n"
                 "its mip chain collapses sooner, so a given Trigger Radius covers more\n"
                 "of the screen.";
    ui_items = "Full Resolution\0"
               "512 x 512\0"
               "256 x 256\0"
               "128 x 128\0"
               "64 x 64\0";
> = 0;

uniform float TriggerRadius <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 12.0;
    ui_step = 0.1;
    ui_label = "Adaptation Trigger Radius";
    ui_category = "Eye Adaptation";
    ui_tooltip = "Mip level of the luminance texture sampled for average scene\n"
                 "brightness. Higher covers more of the screen, 12 is the whole frame.\n"
                 "Authored at 1080p and shifted to the running resolution.";
> = 8.0;

// The pivot and span serve both Lift and Pull, so they sit in a category of
// their own.

uniform float TonalResponseStops <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 4.0;
    ui_step = 0.05;
    ui_label = "Tonal Response Span";
    ui_category = "Tonal Adaptation";
    ui_tooltip = "How far a scene must sit from the Tonal Neutral Point, in stops,\n"
                 "before Lift or Pull reaches full travel.";
> = 1.5;

uniform float TonalNeutralPoint <
    ui_type = "slider";
    ui_min = 0.10; ui_max = 0.70;
    ui_step = 0.01;
    ui_label = "Tonal Neutral Point";
    ui_category = "Tonal Adaptation";
    ui_tooltip = "Scene brightness treated as average. Darker scenes are handled by the\n"
                 "Lift sliders, brighter ones by Pull. Keep it inside the Adaptation\n"
                 "Floor and Ceiling or one group stops acting.";
> = 0.30;

// Lift and Pull are all neutral at 1.0, which reproduces the original PHDR.

uniform float LiftHighlights <
    ui_type = "slider";
    ui_min = 0.25; ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Highlight Lift";
    ui_category = "Tonal Brightening";
    ui_category_closed = true;
    ui_tooltip = "Brightens highlights in scenes darker than the Tonal Neutral Point.\n"
                 "1.0 is neutral, below it darkens them.";
> = 1.0;

uniform float LiftMidtones <
    ui_type = "slider";
    ui_min = 0.25; ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Midtone Lift";
    ui_category = "Tonal Brightening";
    ui_tooltip = "Midtones in scenes darker than the Tonal Neutral Point. Below 1.0\n"
                 "cancels the brightening the tone fusion adds at night.";
> = 1.0;

uniform float LiftShadows <
    ui_type = "slider";
    ui_min = 0.25; ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Shadow Lift";
    ui_category = "Tonal Brightening";
    ui_tooltip = "Shadows in scenes darker than the Tonal Neutral Point. Lowering it\n"
                 "crushes dark corners; shape night with Midtone Lift instead.";
> = 1.0;

uniform float PullHighlights <
    ui_type = "slider";
    ui_min = 0.25; ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Highlight Pull";
    ui_category = "Tonal Darkening";
    ui_category_closed = true;
    ui_tooltip = "Darkens highlights in scenes brighter than the Tonal Neutral Point.\n"
                 "Raising it flattens the whites; Midtone Pull usually works better.";
> = 1.0;

uniform float PullMidtones <
    ui_type = "slider";
    ui_min = 0.25; ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Midtone Pull";
    ui_category = "Tonal Darkening";
    ui_tooltip = "Above 1.0 darkens daylight midtones, which widens the gap to white\n"
                 "without touching the highlights themselves.";
> = 1.0;

uniform float PullShadows <
    ui_type = "slider";
    ui_min = 0.25; ui_max = 2.0;
    ui_step = 0.01;
    ui_label = "Shadow Pull";
    ui_category = "Tonal Darkening";
    ui_tooltip = "Darkens shadows in bright scenes. Below 1.0 keeps the shadow detail\n"
                 "the tone fusion found.";
> = 1.0;

uniform bool EnableSplitToning <
    ui_label = "Enable Split Toning";
    ui_category = "Adaptive Color Volume";
    ui_category_closed = true;
    ui_tooltip = "Toggles adaptive highlight and shadow tinting.";
> = true;

uniform float HighlightTintTone <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Highlight Tint Tone";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "Hue of the warm highlight tint. 0 = golden, 1 = deep amber.";
> = 0.5;

uniform float ShadowTintTone <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Shadow Tint Tone";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "Hue of the cool shadow tint. 0 = teal, 1 = deep indigo.";
> = 0.5;

uniform float TintOpacityH <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Highlight Tint Base Intensity";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "Amount of the warm tint. Its hue is Highlight Tint Tone.";
> = 0.15;

uniform float TintOpacityS <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_label = "Shadow Tint Base Intensity";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "Amount of the cool tint. It backs off with the Dark Scene Fade, so it\n"
                 "does little at night.";
> = 0.08;

uniform float TintThresholdH <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 5.0;
    ui_step = 0.05;
    ui_label = "Highlight Contrast Threshold";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "How much brighter than the scene average a pixel must be before the\n"
                 "warm tint applies.";
> = 1.25;

uniform float TintThresholdS <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0;
    ui_step = 0.05;
    ui_label = "Shadow Contrast Threshold";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "How much darker than the scene average a pixel must be before the\n"
                 "cool tint applies.";
> = 0.70;

uniform bool EnablePurkinje <
    ui_label = "Enable Purkinje Effect";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "Shifts dark scenes toward blue-green, as night vision does.";
> = true;

uniform float Purkinje_Red_Reduction <
    ui_label = "Purkinje Red Reduction";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "Pulls red toward luminance. In a blue night scene that lifts red, so\n"
                 "keep it low and strengthen the shift with the two bias sliders.";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.5; ui_step = 0.001;
> = 0.10;

uniform float Purkinje_Green_Bias <
    ui_label = "Purkinje Green Bias";
    ui_category = "Adaptive Color Volume";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.05; ui_step = 0.001;
> = 0.010;

uniform float Purkinje_Blue_Bias <
    ui_label = "Purkinje Blue Bias";
    ui_category = "Adaptive Color Volume";
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.05; ui_step = 0.001;
> = 0.012;

uniform float Purkinje_Fade_End <
    ui_label = "Purkinje Fade-Out End";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "Scene brightness above which the shift is gone.";
    ui_type = "slider";
    ui_min = 0.10; ui_max = 0.50; ui_step = 0.01;
> = 0.20;

uniform float Purkinje_Fade_Start <
    ui_label = "Purkinje Fade-Out Start";
    ui_category = "Adaptive Color Volume";
    ui_tooltip = "Scene brightness below which the shift is at full strength.";
    ui_type = "slider";
    ui_min = 0.00; ui_max = 0.20; ui_step = 0.005;
> = 0.05;

uniform bool Debug_Mask <
    ui_label = "Debug: Visualize Contrast Mask";
    ui_category = "Debug";
    ui_category_closed = true;
    ui_type = "radio";
> = false;

uniform bool Debug_Dithering <
    hidden = PHDRP_HDR_CHAIN;
    ui_label = "Debug: Visualize Dithering";
    ui_category = "Debug";
    ui_type = "radio";
> = false;

uniform bool Debug_Deband <
    hidden = PHDRP_HDR_CHAIN;
    ui_label = "Debug: Visualize Debanding";
    ui_category = "Debug";
    ui_type = "radio";
    ui_tooltip = "Shows what the debander moved, amplified. Black means untouched.";
> = false;

uniform float FrameTime < source = "frametime"; >;
uniform int FrameCount < source = "framecount"; >;

// Quantisation step of the output, from the real backbuffer bit depth, so the
// dither and the debander both work in units of one visible level.
#ifndef BUFFER_COLOR_BIT_DEPTH
    #define BUFFER_COLOR_BIT_DEPTH 8
#endif
static const float DitherSteps = float((1 << BUFFER_COLOR_BIT_DEPTH) - 1);

// Layout of the blue noise atlas. Kept in sync with tools/make_stbn.py.
#define STBN_SIZE  64
#define STBN_COLS  8
#define STBN_DEPTH 32

//----------------|
// :: Textures :: |
//----------------|

#define SCALE 2
#define GW (BUFFER_WIDTH / SCALE)
#define GH (BUFFER_HEIGHT / SCALE)

// Enough mip levels for the full-res luma chain to reach 1x1, and no more,
// since ReShade refuses a texture that asks for more than its size allows.
#if (BUFFER_WIDTH >= 4096) || (BUFFER_HEIGHT >= 4096)
    #define LUMA_FULLRES_MIPS 13
#elif (BUFFER_WIDTH >= 2048) || (BUFFER_HEIGHT >= 2048)
    #define LUMA_FULLRES_MIPS 12
#elif (BUFFER_WIDTH >= 1024) || (BUFFER_HEIGHT >= 1024)
    #define LUMA_FULLRES_MIPS 11
#elif (BUFFER_WIDTH >= 512) || (BUFFER_HEIGHT >= 512)
    #define LUMA_FULLRES_MIPS 10
#else
    #define LUMA_FULLRES_MIPS 9
#endif

namespace DZPHDR
{
    texture TexColor : COLOR;
    sampler sTexColor
    {
        Texture = TexColor;
    };

    // Held back one pass so the debander can see its neighbours and the dither
    // runs last. Alpha carries how far this shader moved each pixel.
    // Half float: the debander lands values between the 8-bit levels.
    texture TexCombined
    {
        Width  = BUFFER_WIDTH;
        Height = BUFFER_HEIGHT;
        Format = RGBA16F;
    };

    sampler sTexCombined
    {
        Texture = TexCombined;
    };

    // Spatiotemporal blue noise, generated by tools/make_stbn.py. STBN_DEPTH
    // slices of STBN_SIZE square, laid out left to right and top to bottom, with
    // an independent volume in each of R, G and B.
    texture TexBlueNoise < source = "dz_stbn_512x256.png"; >
    {
        Width  = 512;
        Height = 256;
        Format = RGBA8;
    };

    sampler sTexBlueNoise
    {
        Texture   = TexBlueNoise;
        AddressU  = WRAP;
        AddressV  = WRAP;
        MinFilter = POINT;
        MagFilter = POINT;
        MipFilter = POINT;
    };

    texture TexLuma
    {
        Width     = BUFFER_WIDTH;
        Height    = BUFFER_HEIGHT;
        Format    = R16F;
        MipLevels = LUMA_FULLRES_MIPS;
    };

    sampler sTexLuma
    {
        Texture = TexLuma;
    };

    // Log-luminance copy of TexLuma. Averaging in log space gives a geometric
    // mean, so one bright lamp cannot drag the whole reading up.
    texture TexLumaLog
    {
        Width     = BUFFER_WIDTH;
        Height    = BUFFER_HEIGHT;
        Format    = R16F;
        MipLevels = LUMA_FULLRES_MIPS;
    };

    sampler sTexLumaLog
    {
        Texture = TexLumaLog;
    };

    texture TexLuma512
    {
        Width     = 512;
        Height    = 512;
        Format    = R16F;
        MipLevels = 10;
    };

    sampler sTexLuma512
    {
        Texture = TexLuma512;
    };

    texture TexLuma256
    {
        Width     = 256;
        Height    = 256;
        Format    = R16F;
        MipLevels = 9;
    };

    sampler sTexLuma256
    {
        Texture = TexLuma256;
    };

    texture TexLuma128
    {
        Width     = 128;
        Height    = 128;
        Format    = R16F;
        MipLevels = 8;
    };

    sampler sTexLuma128
    {
        Texture = TexLuma128;
    };

    texture TexLuma64
    {
        Width     = 64;
        Height    = 64;
        Format    = R16F;
        MipLevels = 7;
    };

    sampler sTexLuma64
    {
        Texture = TexLuma64;
    };

    // Horizontal moments for each scale. The vertical passes read them with the
    // same strided taps, so they need a mip chain to prefilter from; six levels
    // cover the widest stride, macro at maximum Radius, with room to spare.
    texture TexTempMeansMedium
    {
        Width     = GW;
        Height    = GH;
        Format    = RG16F;
        MipLevels = 6;
    };

    sampler sTexTempMeansMedium
    {
        Texture = TexTempMeansMedium;
    };

    texture TexStatsMedium
    {
        Width  = GW;
        Height = GH;
        Format = RG16F;
    };

    sampler sTexStatsMedium
    {
        Texture = TexStatsMedium;
    };

    texture TexTempMeansMicro
    {
        Width     = GW;
        Height    = GH;
        Format    = RG16F;
        MipLevels = 6;
    };

    sampler sTexTempMeansMicro
    {
        Texture = TexTempMeansMicro;
    };

    texture TexStatsMicro
    {
        Width  = GW;
        Height = GH;
        Format = RG16F;
    };

    sampler sTexStatsMicro
    {
        Texture = TexStatsMicro;
    };

    texture TexTempMeansMacro
    {
        Width     = GW;
        Height    = GH;
        Format    = RG16F;
        MipLevels = 6;
    };

    sampler sTexTempMeansMacro
    {
        Texture = TexTempMeansMacro;
    };

    texture TexStatsMacro
    {
        Width  = GW;
        Height = GH;
        Format = RG16F;
    };

    sampler sTexStatsMacro
    {
        Texture = TexStatsMacro;
    };

    // Micro, medium and macro bases in RGB. Alpha is the micro scale's a, which
    // the Macro Soft Area Guard reads.
    texture TexVarI
    {
        Width  = BUFFER_WIDTH;
        Height = BUFFER_HEIGHT;
        Format = RGBA16F;
    };

    sampler sTexVarI
    {
        Texture = TexVarI;
    };

    // .r is the adapted brightness the shader uses. .g is a short symmetric
    // pre-filter of the raw measurement, there only to feed .r a steady signal.
    texture TexAdapt
    {
        Format = RG32F;
        Width  = 1;
        Height = 1;
    };

    sampler sTexAdapt
    {
        Texture   = TexAdapt;
        MinFilter = POINT;
        MagFilter = POINT;
        MipFilter = POINT;
    };

    texture TexLastAdapt
    {
        Format = RG32F;
        Width  = 1;
        Height = 1;
    };

    sampler sTexLastAdapt
    {
        Texture   = TexLastAdapt;
        MinFilter = POINT;
        MagFilter = POINT;
        MipFilter = POINT;
    };

    texture TexLastParams
    {
        Format = RGBA32F;
        Width  = 1;
        Height = 1;
    };

    sampler sTexLastParams
    {
        Texture   = TexLastParams;
        MinFilter = POINT;
        MagFilter = POINT;
        MipFilter = POINT;
    };

    struct VS_OUTPUT
    {
        float4 pos : SV_POSITION;
        float2 uv  : TEXCOORD0;
    };

//-----------------|
// :: Functions :: |
//-----------------|

float ScaleFun(float v, float mean_i)
{
    float r = 1.0 - (mean_i * 0.999999);
    return r * (1.0 / (1.0 + exp(-1.0 * (v - mean_i))) - 0.5);
}

float3 GetHighlightTintColor()
{
    float3 yellow = float3(1.0, 0.9,   0.4);
    float3 orange = float3(1.0, 0.78,  0.55);
    float3 amber  = float3(1.0, 0.4,   0.1);

    return HighlightTintTone < 0.5
        ? lerp(yellow, orange, HighlightTintTone * 2.0)
        : lerp(orange, amber,  (HighlightTintTone - 0.5) * 2.0);
}

float3 GetShadowTintColor()
{
    float3 cyan   = float3(0.0, 0.75,  1.0);
    float3 blue   = float3(0.0, 0.365, 1.0);
    float3 indigo = float3(0.0, 0.05,  0.8);

    return ShadowTintTone < 0.5
        ? lerp(cyan, blue,   ShadowTintTone * 2.0)
        : lerp(blue, indigo, (ShadowTintTone - 0.5) * 2.0);
}

// Per-zone tonal delta. The 4.0 coefficient keeps the three zone weights
// summing to 1 across the luma range.
float AdaptionDelta(float luma, float strengthMidtones, float strengthShadows, float strengthHighlights)
{
    float midtones   = (4.0 * strengthMidtones - strengthHighlights - strengthShadows) * luma * (1.0 - luma);
    float shadows    = strengthShadows    * (1.0 - luma);
    float highlights = strengthHighlights * luma;
    return midtones + shadows + highlights;
}

// Biggest curve weight that keeps luma -> luma + delta monotonic, so the
// tonal curve cannot fold back on itself and invert an edge.
float MonotonicCurveLimit(float strengthMidtones, float strengthShadows, float strengthHighlights, bool subtracted)
{
    float A     = 4.0 * strengthMidtones - strengthHighlights - strengthShadows;
    float slope = subtracted ? -((strengthHighlights - strengthShadows) + abs(A))
                             :  ((strengthHighlights - strengthShadows) - abs(A));
    return (slope < 0.0) ? (-1.0 / slope) : 1e6;
}

// Roll a colour whose brightest channel exceeds a soft knee back down to 1.0 by
// scaling all three channels together, so an over-boosted highlight desaturates
// toward white instead of hard-clipping one channel at a time and shifting hue.
float3 GamutSoftClip(float3 c)
{
    const float knee = 0.8;
    float m = max(max(c.r, c.g), c.b);
    [flatten]
    if (m > knee)
    {
        float over       = m - knee;
        float compressed = knee + (1.0 - knee) * (over / (over + (1.0 - knee)));
        c *= compressed / m;
    }
    return c;
}

//---------------------|
// :: Pixel Shaders :: |
//---------------------|

// One voxel of the blue noise volume for this pixel, on the given slice. The
// stored bytes are rank order, so shifting to the centre of each bin turns the
// 256 levels into an unbiased [0,1) rather than a ramp that reaches both ends.
float3 SampleBlueNoise(int2 pixel, int slice)
{
    int2 cell  = int2(slice % STBN_COLS, slice / STBN_COLS);
    int2 coord = cell * STBN_SIZE + (pixel & int2(STBN_SIZE - 1, STBN_SIZE - 1));
    float3 raw = tex2Dfetch(sTexBlueNoise, coord).rgb;
    return (raw * 255.0 + 0.5) / 256.0;
}

void PS_Luma(VS_OUTPUT input, out float luma : SV_Target)
{
    luma = GetLuminance(tex2D(sTexColor, input.uv).rgb);
}

void PS_LumaLog(VS_OUTPUT input, out float logLuma : SV_Target)
{
    // The floor keeps pure black from sending the log to -inf while still
    // letting shadows weigh heavily in the mean.
    float luma = tex2Dlod(sTexLuma, float4(input.uv, 0, 0)).r;
    logLuma = log(max(luma, 1e-4));
}

float PS_Luma512(VS_OUTPUT input) : SV_Target
{
    // Above 1024 a 4-tap box at mip 0 would skip most source pixels and alias the
    // downsample chain, so pull from the mip nearest 1024 instead.
    const float srcMip = max(0.0, ceil(log2(max(BUFFER_WIDTH, BUFFER_HEIGHT) / 1024.0)));
    const float2 ps = exp2(srcMip) * float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
    float v = 0.0;
    v += tex2Dlod(sTexLumaLog, float4(input.uv + float2(-0.5, -0.5) * ps, 0, srcMip)).r;
    v += tex2Dlod(sTexLumaLog, float4(input.uv + float2( 0.5, -0.5) * ps, 0, srcMip)).r;
    v += tex2Dlod(sTexLumaLog, float4(input.uv + float2(-0.5,  0.5) * ps, 0, srcMip)).r;
    v += tex2Dlod(sTexLumaLog, float4(input.uv + float2( 0.5,  0.5) * ps, 0, srcMip)).r;
    return v * 0.25;
}

float PS_Luma256(VS_OUTPUT input) : SV_Target
{
    float2 ps = float2(1.0 / 512.0, 1.0 / 512.0);
    float v = 0.0;
    v += tex2Dlod(sTexLuma512, float4(input.uv + float2(-0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma512, float4(input.uv + float2( 0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma512, float4(input.uv + float2(-0.5,  0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma512, float4(input.uv + float2( 0.5,  0.5) * ps, 0, 0)).r;
    return v * 0.25;
}

float PS_Luma128(VS_OUTPUT input) : SV_Target
{
    float2 ps = float2(1.0 / 256.0, 1.0 / 256.0);
    float v = 0.0;
    v += tex2Dlod(sTexLuma256, float4(input.uv + float2(-0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma256, float4(input.uv + float2( 0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma256, float4(input.uv + float2(-0.5,  0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma256, float4(input.uv + float2( 0.5,  0.5) * ps, 0, 0)).r;
    return v * 0.25;
}

float PS_Luma64(VS_OUTPUT input) : SV_Target
{
    float2 ps = float2(1.0 / 128.0, 1.0 / 128.0);
    float v = 0.0;
    v += tex2Dlod(sTexLuma128, float4(input.uv + float2(-0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma128, float4(input.uv + float2( 0.5, -0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma128, float4(input.uv + float2(-0.5,  0.5) * ps, 0, 0)).r;
    v += tex2Dlod(sTexLuma128, float4(input.uv + float2( 0.5,  0.5) * ps, 0, 0)).r;
    return v * 0.25;
}

// One log-luminance tap from whichever pyramid the Luma Texture Size selects.
float SampleLogLumaAt(float2 uv, float mip)
{
    float4 uvMip = float4(uv, 0.0, mip);
    [branch]
    if (LumaTextureSize == 1)      return tex2Dlod(sTexLuma512, uvMip).r;
    else if (LumaTextureSize == 2) return tex2Dlod(sTexLuma256, uvMip).r;
    else if (LumaTextureSize == 3) return tex2Dlod(sTexLuma128, uvMip).r;
    else if (LumaTextureSize == 4) return tex2Dlod(sTexLuma64,  uvMip).r;
    else                           return tex2Dlod(sTexLumaLog, uvMip).r;
}

// Mip N spans 2^N texels whatever the screen is, so the metering tap has to
// shift with resolution or every scene brightness reading drifts with it.
float MeteringMip()
{
    if (LumaTextureSize != 0)
        return TriggerRadius;

    return max(0.0, TriggerRadius + log2(float(BUFFER_HEIGHT) / REFERENCE_HEIGHT));
}

float SampleAvgLuma()
{
    // The source holds log-luminance, so exp() of a tap that the mip chain has
    // already box averaged gives a geometric mean over the covered region.
    return exp(SampleLogLumaAt(float2(0.5, 0.5), MeteringMip()));
}

// Moments to guided-filter (a, b). Derived at low resolution and bilinearly
// upsampled, which is the fast guided filter and avoids edge halos.
//
// eps scales with the square of the radius ratio. A fixed eps smooths less as
// the window grows, which would let the macro base track the image more
// closely than the medium one and flip the sign of the macro band.
float2 MomentsToAB(float2 m, float eps)
{
    // Clamped because the moments live in half-float. In flat sky E[I^2] is
    // quantised far coarser than the true variance, so the difference can come
    // out slightly negative, and with the micro epsilon that close to zero the
    // division below blows up on single pixels. Those land in the micro base,
    // cancel only when the micro and medium gains match, and otherwise show as
    // isolated black or white specks that crawl with the image.
    float var = max(m.y - m.x * m.x, 0.0);
    float a   = var / (var + eps);
    return float2(a, m.x * (1.0 - a));
}

// Guided filter passes, one horizontal and one vertical per scale.
//
// Integer tap counts keep the window symmetric; a float accumulator can drop
// the endpoint to rounding error and bias the mean.
//
// stepSize = r / 3 pins every scale to 7 taps, so a wide window has taps tens
// of pixels apart. Each tap reads the mip matching its own stride, otherwise
// they are point samples with holes between them and the base shimmers as
// content drifts through the comb.
float ToPixels(float authored)
{
    return max(1.0, authored * (float(BUFFER_HEIGHT) / REFERENCE_HEIGHT));
}

float MipForStride(float stepSize)
{
    return max(0.0, log2(stepSize));
}

void PS_CalcMeansH_Medium(VS_OUTPUT input, out float2 mean_horiz : SV_Target)
{
    float2 ps = bb::PixelSize;
    float r = ToPixels(Radius);
    float stepSize = max(1.0, r / 3.0);
    int taps = int(r / stepSize + 1e-3);
    // Sampling TexLuma, which is full resolution, so the stride is already in texels.
    float lod = MipForStride(stepSize);
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float val = tex2Dlod(sTexLuma, float4(input.uv + float2(i * stepSize * ps.x, 0), 0, lod)).r;
        sum += float2(val, val * val);
    }
    mean_horiz = sum / (2 * taps + 1);
}

void PS_CalcMeansV_Medium(VS_OUTPUT input, out float2 ab : SV_Target)
{
    float2 ps = bb::PixelSize;
    float r = ToPixels(Radius);
    float stepSize = max(1.0, r / 3.0);
    int taps = int(r / stepSize + 1e-3);
    // The offsets are in full-res pixels but the moments texture is 1/SCALE that
    // size, so the stride is that many fewer texels and the matching mip is lower.
    float lod = MipForStride(stepSize / float(SCALE));
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float2 val = tex2Dlod(sTexTempMeansMedium, float4(input.uv + float2(0, i * stepSize * ps.y), 0, lod)).rg;
        sum += val;
    }
    // Medium is the reference scale (ratio 1), so it uses Epsilon unchanged and
    // the default all-sliders-zero output is preserved exactly.
    ab = MomentsToAB(sum / (2 * taps + 1), Epsilon);
}

void PS_CalcMeansH_Micro(VS_OUTPUT input, out float2 mean_horiz : SV_Target)
{
    float2 ps = bb::PixelSize;
    float r = max(1.0, ToPixels(Radius) / 3.0);
    float stepSize = max(1.0, r / 3.0);
    int taps = int(r / stepSize + 1e-3);
    float lod = MipForStride(stepSize);
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float val = tex2Dlod(sTexLuma, float4(input.uv + float2(i * stepSize * ps.x, 0), 0, lod)).r;
        sum += float2(val, val * val);
    }
    mean_horiz = sum / (2 * taps + 1);
}

void PS_CalcMeansV_Micro(VS_OUTPUT input, out float2 ab : SV_Target)
{
    float2 ps = bb::PixelSize;
    float r = max(1.0, ToPixels(Radius) / 3.0);
    float stepSize = max(1.0, r / 3.0);
    int taps = int(r / stepSize + 1e-3);
    float lod = MipForStride(stepSize / float(SCALE));
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float2 val = tex2Dlod(sTexTempMeansMicro, float4(input.uv + float2(0, i * stepSize * ps.y), 0, lod)).rg;
        sum += val;
    }
    // Finer than medium, so a smaller eps keeps the micro base close to the input.
    float ratio = r / ToPixels(Radius);
    ab = MomentsToAB(sum / (2 * taps + 1), Epsilon * ratio * ratio);
}

void PS_CalcMeansH_Macro(VS_OUTPUT input, out float2 mean_horiz : SV_Target)
{
    float2 ps = bb::PixelSize;
    // No ceiling. Cost does not vary with the radius, since the window is
    // always seven strided taps, and a cap here silently froze the coarsest
    // scale once Smoothing Radius passed 30 while leaving the eps ratio below
    // to drift.
    float r = ToPixels(Radius) * 3.0;
    float stepSize = max(1.0, r / 3.0);
    int taps = int(r / stepSize + 1e-3);
    // Widest stride of the three scales, so this is where LOD 0 aliased worst.
    float lod = MipForStride(stepSize);
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float val = tex2Dlod(sTexLuma, float4(input.uv + float2(i * stepSize * ps.x, 0), 0, lod)).r;
        sum += float2(val, val * val);
    }
    mean_horiz = sum / (2 * taps + 1);
}

void PS_CalcMeansV_Macro(VS_OUTPUT input, out float2 ab : SV_Target)
{
    float2 ps = bb::PixelSize;
    float r = ToPixels(Radius) * 3.0;
    float stepSize = max(1.0, r / 3.0);
    int taps = int(r / stepSize + 1e-3);
    float lod = MipForStride(stepSize / float(SCALE));
    float2 sum = 0.0;

    for (int i = -taps; i <= taps; i++)
    {
        float2 val = tex2Dlod(sTexTempMeansMacro, float4(input.uv + float2(0, i * stepSize * ps.y), 0, lod)).rg;
        sum += val;
    }
    // Coarser than medium, so a larger eps forces the macro base to smooth out
    // the medium-scale structure and become the true low-frequency layer.
    float ratio = r / ToPixels(Radius);
    ab = MomentsToAB(sum / (2 * taps + 1), Epsilon * ratio * ratio);
}

void PS_GuidedFilterResult(VS_OUTPUT input, out float4 base_layers : SV_Target)
{
    float I = tex2D(sTexLuma, input.uv).r;

    // Each stats texture holds the low-res coefficients (a, b); bilinear
    // sampling upsamples them and the base is a * I + b.
    float2 ab_medium = tex2D(sTexStatsMedium, input.uv).rg;
    float base_medium = ab_medium.x * I + ab_medium.y;

    float2 ab_micro = tex2D(sTexStatsMicro, input.uv).rg;
    float base_micro = ab_micro.x * I + ab_micro.y;

    float2 ab_macro = tex2D(sTexStatsMacro, input.uv).rg;
    float base_macro = ab_macro.x * I + ab_macro.y;

    // Alpha keeps the micro scale's a: near 0 where the window is flat next to
    // its Epsilon, near 1 on texture. The medium scale reads a cloud's own
    // outline against the sky as structure; the micro scale does not, because
    // a soft cloud has no fine texture even at its edge, while hills, rock and
    // sea do. Upsampled from low resolution, so it describes a region.
    base_layers = float4(base_micro, base_medium, base_macro, ab_micro.x);
}

// Pre-filter length. Long enough to swallow a flickering torch or fire, short
// enough that it costs about a sixth of a second on a real transition.
static const float FlickerRejectTime = 0.15;

void PS_CalcAdapt(VS_OUTPUT input, out float2 adapt : SV_Target)
{
    // Clamp the raw measurement so a fade-to-black or a white flash can't rail
    // the adaptation and slam the tonal curves on the next frame.
    float adaptCeil = max(AdaptMax, AdaptMin + 0.01);
    float measured  = clamp(SampleAvgLuma(), AdaptMin, adaptCeil);
    float2 last     = tex2Dfetch(sTexLastAdapt, 0).rg;
    float dt        = FrameTime * 0.001;

    float4 prevParams = tex2Dfetch(sTexLastParams, 0);
    float4 currParams = float4(float(LumaTextureSize), TriggerRadius, 0.5, 0.5);
    bool paramChanged = any(abs(currParams - prevParams) > 1e-4);

    if (paramChanged || AdaptationTime <= 0.0)
    {
        adapt = max(measured, 1e-5).xx;
        return;
    }

    // Stage 1 is symmetric, so it settles on the true mean. Feeding the stage
    // below a clean signal matters: a fast-up/slow-down filter run straight off a
    // flickering measurement creeps upward, about 10% high next to a campfire.
    float fast = lerp(last.g, measured, 1.0 - exp(-dt / FlickerRejectTime));

    // Stage 2 is the eye model: quick to brighten, slow to dark-adapt. Direction
    // fades across a relative deadband instead of a hard test, otherwise noise
    // around the crossing point flips the time constant every frame. Exponential
    // decay keeps the rate independent of frame rate.
    float deadband = max(0.25 * last.r, 1e-4);
    float rising   = smoothstep(-deadband, deadband, fast - last.r);
    float tau      = AdaptationTime * lerp(DarkAdaptationMult, 1.0, rising);
    float slow     = lerp(last.r, fast, 1.0 - exp(-dt / max(tau, 0.001)));

    adapt = float2(max(slow, 1e-5), max(fast, 1e-5));
}

// Interleaved Gradient Noise, Jimenez's constants. Well spread over a small
// neighbourhood rather than merely random, so it hides in a gradient instead
// of clumping. The stored blue-noise mask is better but needs a texture.
float InterleavedGradientNoise(float2 pos)
{
    const float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
    return frac(magic.z * frac(dot(pos, magic.xy)));
}

// Reshape a uniform sample into a triangular one over [-0.5, 1.5]. Two steps
// wide decorrelates the noise variance as well as the mean, which is what
// holds the noise floor steady across a gradient. Remapped, not summed: a sum
// of two lookups averages away the pattern's spatial arrangement.
float ReshapeUniformToTriangle(float v)
{
    v = frac(v + 0.5);
    float orig = v * 2.0 - 1.0;
    // orig * rsqrt(|orig|) is sign(orig) * sqrt(|orig|); guard the singularity.
    float rnd = (orig == 0.0) ? -1.0 : (orig * rsqrt(abs(orig)));
    return rnd - sign(orig) + 0.5;
}

void PS_SaveParams(VS_OUTPUT input, out float4 save : SV_Target)
{
    save = float4(float(LumaTextureSize), TriggerRadius, 0.5, 0.5);
}

void PS_SaveAdapt(VS_OUTPUT input, out float2 save : SV_Target)
{
    save = tex2Dfetch(sTexAdapt, 0).rg;
}

float4 PS_FinalCombine(VS_OUTPUT input) : SV_Target
{
    float3 original = tex2D(sTexColor, input.uv).rgb;
    float L    = tex2D(sTexLuma, input.uv).r;
    float4 BasesA = tex2D(sTexVarI, input.uv);
    float3 Bases  = BasesA.rgb;

    L    = max(L,    1e-5);
    Bases = max(Bases, 1e-5);

    float Base = Bases.y; // Medium base is default

    // Non-overlapping log-space bands, so each slider owns one scale and the three
    // reconstruct without beating against each other.
    float band_micro  = log(L)       - log(Bases.x);
    float band_medium = log(Bases.x) - log(Bases.y);
    float band_macro  = log(Bases.y) - log(Bases.z);

    // Macro is a bare gain, not 1 + slider like the finer bands, so 0 means no
    // large-scale contrast added rather than the band being subtracted out.
    float macro_gain = max(Contrast_Macro, 0.0);

    // In a soft area with no structure of its own, a cloud or an out of focus
    // background, macro contrast darkens the whole patch against the wider
    // sky, and because the bases follow its outline it goes down as a block.
    // Scale back only where the micro scale saw no fine texture. Read from the
    // shader on a cloudy Odyssey frame: clear sky 0.52 and clouds 0.56 median,
    // the game's own fine noise keeping them off zero; hills 0.91, rock 0.97,
    // sea 0.91.
    // The band is entirely added contrast, so this removes nothing the image had.
    macro_gain *= 1.0 - Contrast_Macro_Guard * (1.0 - smoothstep(0.65, 0.88, BasesA.a));

    float micro_gain = 1.0 + Contrast_Micro;

    float R_val = band_micro  * micro_gain
                + band_medium * (1.0 + Contrast_Medium)
                + band_macro  * macro_gain;

    float sm_manual  = clamp(ManualExposure, 0.01, 0.99);
    float sm_adapt   = EnableAdaptation ? clamp(tex2Dfetch(sTexAdapt, 0).r, 0.01, 0.99) : sm_manual;
    // AdaptationStrength > 1.0 extrapolates the lerp, so re-clamp to keep the
    // scene mean in a range the VIG sigmoid and contrast ratios can handle.
    float scene_mean = EnableAdaptation ? clamp(lerp(sm_manual, sm_adapt, AdaptationStrength), 0.01, 0.99) : sm_manual;

    float R_new = R_val;
    if (L > scene_mean)
    {
        float factor = pow(abs(L / scene_mean), 0.5);
        R_new = R_val * factor;
    }

    // Hold the detail term to a stated number of stops, darkening side only.
    // The artefact is a dark rim on the shadow side of a bright object, so
    // limiting both directions would spend the highlight detail that makes a
    // lit surface read as lit to buy back something only one side is doing.
    [branch]
    if (DetailLimit > 0.0)
    {
        float knee = DetailLimit * 0.6931472; // stops to natural log
        if (R_new < 0.0)
            R_new = -knee * tanh(-R_new / knee);
    }

    float inv_L = 1.0 - L;
    float v1 = 0.2;
    float v3 = scene_mean;
    float v2 = 0.5 * (v1 + v3);
    float v5 = 0.8;
    float v4 = 0.5 * (v3 + v5);
    float A = 0.0, B = 0.0;
    float exp_R_new = exp(R_new);
    float v_scales[5] = { v1, v2, v3, v4, v5 };

    [unroll]
    for (int i = 0; i < 5; i++)
    {
        float fvk = ScaleFun(v_scales[i], scene_mean);
        float I_k = (1.0 + fvk) * (L + fvk * inv_L);
        float Lk  = exp_R_new * I_k;
        float wk  = (i < 3) ? I_k : 0.5 * (1.0 - I_k);
        wk = clamp(wk, 0.001, 1.0);
        A += Lk * wk;
        B += wk;
    }
    float ratio = clamp((A / (B + 1e-6)) / L, 0.0, 3.0);

    // Ramp the fusion down in very dark scenes, where there is little range left
    // to recover and the detail term is mostly noise.
    float fade_lo   = EnableAdaptation ? max(AdaptMin, 0.01) : 0.01;
    float fade_hi   = max(DarkFadeThreshold, fade_lo + 0.005);
    float dark_fade = smoothstep(fade_lo, fade_hi, scene_mean);
    float effective_strength = Strength * lerp(1.0, dark_fade, DynamicIntensity);

    // Soft-clip the boosted colour before blending so a saturated highlight that
    // the ratio pushes past 1.0 desaturates cleanly instead of clipping one
    // channel and shifting hue.
    float3 boosted = GamutSoftClip(original * ratio);
    float3 blended = lerp(original, boosted, effective_strength);

    float adp_luma    = GetLuminance(blended);
    float3 adp_chroma = blended - adp_luma;
    float adp_delta;

    float current_strength = EnableAdaptation ? AdaptationStrength : 1.0;

    // INTENSITY alone, deliberately not effective_strength. The tints and the
    // halo take the faded value because they amplify high-frequency detail that
    // is mostly noise in a dark scene. A global luma remap amplifies nothing, and
    // folding the fade in here would disable Lift in the scenes it exists for.
    current_strength *= Strength;

    // Split point between Lift and Pull. Distance is counted in stops over a
    // fixed span, so moving the pivot slides the response rather than stretching
    // it. Bounded by the Adaptation Floor and Ceiling: a pivot outside that
    // bracket leaves one group's sliders inert.
    float pivot = clamp(TonalNeutralPoint, 0.05, 0.95);

    if (sm_adapt < pivot)
    {
        float mid = LiftMidtones - 1.0, sh = LiftShadows - 1.0, hi = LiftHighlights - 1.0;
        float t     = saturate(log2(pivot / max(sm_adapt, 1e-5)) / TonalResponseStops);
        float curve = current_strength * 0.5 * (t * t * (3.0 - 2.0 * t));
        curve = min(curve, MonotonicCurveLimit(mid, sh, hi, false));
        adp_delta = AdaptionDelta(adp_luma, mid, sh, hi) * curve;
    }
    else
    {
        float mid = PullMidtones - 1.0, sh = PullShadows - 1.0, hi = PullHighlights - 1.0;
        float u     = saturate(log2(max(sm_adapt, 1e-5) / pivot) / TonalResponseStops);
        float curve = current_strength * 0.5 * (u * u * (3.0 - 2.0 * u));
        curve = min(curve, MonotonicCurveLimit(mid, sh, hi, true));
        adp_delta = -AdaptionDelta(adp_luma, mid, sh, hi) * curve;
    }

    adp_luma = saturate(adp_luma + adp_delta);
    blended  = saturate(adp_luma + adp_chroma);

    float purkinje_mask = 0.0;

    // Purkinje shift. The two fade sliders' ranges overlap, Start up to 0.20
    // and End from 0.10, so End is held above Start to keep the smoothstep
    // edges in order.
    float purkinje_fade_end = max(Purkinje_Fade_End, Purkinje_Fade_Start + 0.01);

    [branch]
    if (EnablePurkinje && scene_mean < purkinje_fade_end)
    {
        float pixel_luma  = GetLuminance(blended);

        float shadow_mask = 1.0 - smoothstep(0.0, 0.5, pixel_luma);

        float purkinje_strength = 1.0 - smoothstep(Purkinje_Fade_Start, purkinje_fade_end, scene_mean);

        // INTENSITY, not effective_strength, for the same reason the tonal curve
        // uses it: this is a luma-driven colour remap, not something derived from
        // high-frequency detail, so the Dark Scene Fade has no noise argument to
        // make against it and would only cancel it in the scenes it is for.
        purkinje_strength *= Strength;

        purkinje_mask = purkinje_strength * shadow_mask;

        // Desaturates red toward luminance rather than removing it.
        blended.r = lerp(blended.r, pixel_luma, purkinje_mask * Purkinje_Red_Reduction);

        // Rod vision peaks near 507nm, so green and blue are lifted.
        blended.g = saturate(blended.g + purkinje_mask * Purkinje_Green_Bias * (1.0 - blended.g));
        blended.b = saturate(blended.b + purkinje_mask * Purkinje_Blue_Bias * (1.0 - blended.b));
    }

    [branch]
    if (EnableSplitToning && effective_strength > 0.0)
    {
        float local_luma     = GetLuminance(blended);
        float contrast_ratio = local_luma / (scene_mean + 0.0001);

        // Track effective_strength rather than the raw slider, so the tints back off
        // with the Dark Scene Fade instead of holding full opacity over a scene the
        // tone fusion has already released. The highlight weight is 1.0 in dark
        // scenes, so without this the highlight tint keeps shifting colour there.
        float strength_weight         = pow(effective_strength, 0.75);
        float scene_shadow_weight     = smoothstep(0.0, 0.3, scene_mean);
        float scene_highlight_weight  = smoothstep(1.0, 0.7, scene_mean);

        [branch]
        if (contrast_ratio > TintThresholdH)
        {
            float highlight_factor  = saturate((contrast_ratio - TintThresholdH) * 0.5);
            float final_opacity_H   = TintOpacityH * highlight_factor * strength_weight * scene_highlight_weight;
            blended = lerp(blended, blended * GetHighlightTintColor(), final_opacity_H);
        }
        else if (contrast_ratio < TintThresholdS)
        {
            float shadow_factor   = saturate((TintThresholdS - contrast_ratio) * 2.0);
            float final_opacity_S = TintOpacityS * shadow_factor * strength_weight * scene_shadow_weight;

            // Give way to Purkinje where it is active, or the two stack into mud.
            final_opacity_S *= (1.0 - purkinje_mask);

            blended = lerp(blended, blended * GetShadowTintColor(), final_opacity_S);
        }
    }

    // Simultaneous contrast masking: deepen the shadow side of bright edges.
    // Negative detail means darker than the local base. The 3.0 makes the mask
    // visible, the 0.40 stops it reaching black, and the Base gate keeps it off
    // noise in flat shadows. This is the etched-outline artefact, by design.
    float bright_neighbour = smoothstep(0.15, 0.5, Base);

    // The threshold is subtracted rather than gated, so the halo grows from zero
    // past it with no step. Soft clouds and depth of field blur hold small
    // noisy dips below their base, which the 3.0 turned into dark grain; an
    // edge dips by far more and keeps its halo.
    float hf_detail = L - Base;
    float contrast_shadow = min(saturate(max(-hf_detail - Contrast_Shadow_Threshold, 0.0) * 3.0), 0.40) * Contrast_Shadow_Strength * bright_neighbour * effective_strength;

    if (Debug_Mask)
    {
        // Scaled by 5 so the halo is visible. Alpha 0 keeps the presentation
        // pass from debanding a debug view.
        return float4((contrast_shadow * 5.0).xxx, 0.0);
    }
    blended = saturate(blended * (1.0 - contrast_shadow));

    // Alpha records how far this shader moved the pixel, measured in quantisation
    // steps and taken on the channel that moved most. The presentation pass uses it
    // to decide where debanding is this shader's business: a step it never opened
    // is a step it has no reason to go looking for.
    float moved = max(max(abs(blended.r - original.r),
                          abs(blended.g - original.g)),
                          abs(blended.b - original.b)) * DitherSteps;

    return float4(blended, moved);
}

// Passes small values unchanged and eases larger ones toward limit.
float3 SoftLimit(float3 v, float limit)
{
    float3 a    = abs(v);
    float knee  = limit * 0.5;
    float3 over = max(a - knee, 0.0);
    return sign(v) * min(a, knee + over * knee / (knee + over));
}

// Rebuild a gradient quantised into visible steps.
//
// Three tests have to agree: the neighbourhood average sits close to the
// pixel, the samples agree with each other, and the value does not change
// pixel to pixel. The third carries it, since the first two only measure how
// far apart values are and quiet texture is not far apart. The tests read the
// incoming frame; only the repair lands in output space.
float3 Deband(float2 uv, float3 out_centre, float3 src_centre, float jitter,
              float threshold, float radius, int iterations, int taps, float detail)
{
    float2 ps = bb::PixelSize;
    float step_size = 1.0 / DitherSteps;

    // Frequency test: mean absolute difference to the four nearest neighbours of
    // the source pixel, in steps. Flat inside a band, never flat inside texture.
    float guard = 1.0;

    if (detail > 0.0)
    {
        float3 hf = abs(tex2D(sTexColor, uv + float2( ps.x, 0.0)).rgb - src_centre)
                  + abs(tex2D(sTexColor, uv + float2(-ps.x, 0.0)).rgb - src_centre)
                  + abs(tex2D(sTexColor, uv + float2(0.0,  ps.y)).rgb - src_centre)
                  + abs(tex2D(sTexColor, uv + float2(0.0, -ps.y)).rgb - src_centre);

        float measured = max(max(hf.r, hf.g), hf.b) * 0.25 * DitherSteps;
        guard = 1.0 - smoothstep(detail * 0.5, detail, measured);
    }

    if (guard <= 0.0)
        return out_centre;

    float3 res = out_centre;

    [loop]
    for (int i = 1; i <= iterations; i++)
    {
        // Reach further and judge more strictly each pass, so the first fixes the
        // coarse steps and later ones tidy what is left. Converted like Radius.
        float r_i    = ToPixels(radius) * float(i);
        float bound  = threshold * step_size / float(i);

        // Turn the sampling pattern by a different angle at every pixel, on every
        // frame, and on every pass. A fixed orientation leaves its own faint
        // structure behind; rotating it turns that into something the eye averages
        // away instead.
        float angle = (jitter + float(i) * 0.618034) * 6.2831853;

        float3 src_sum   = 0.0;
        float3 src_sumsq = 0.0;
        float3 out_sum   = 0.0;

        [loop]
        for (int k = 0; k < taps; k++)
        {
            // Golden angle turn with a square-root radius: the samples land evenly
            // over the whole disc rather than bunching on one ring, which is what
            // makes both the average and the scatter worth trusting.
            float t = (float(k) + 0.5) / float(taps);
            float rr = r_i * sqrt(t);
            float a = angle + float(k) * 2.39996323;

            float4 at = float4(uv + float2(cos(a), sin(a)) * rr * ps, 0.0, 0.0);

            // Accumulate offsets from the centre, not the samples, so the sum stays small
            // and does not lose the sub-step precision the repair depends on.
            float3 sd_ = tex2Dlod(sTexColor,    at).rgb - src_centre;
            float3 od_ = tex2Dlod(sTexCombined, at).rgb - out_centre;

            src_sum   += sd_;
            src_sumsq += sd_ * sd_;
            out_sum   += od_;
        }

        float inv = 1.0 / float(taps);

        float3 src_mean = src_sum * inv;
        float3 src_sd   = sqrt(max(src_sumsq * inv - src_mean * src_mean, 0.0));
        float3 out_avg  = out_centre + out_sum * inv;

        // Close to the neighbourhood average: a flat step rather than an edge.
        // src_mean is already the offset from the centre, so it is that distance.
        float3 flat_weight = 1.0 - smoothstep(bound * 0.5, bound, abs(src_mean));

        // Neighbourhood agrees with itself: a gradient rather than texture. The
        // slack is wider than the flatness test because a genuine gradient does
        // vary across the disc, it just varies smoothly.
        float3 calm_weight = 1.0 - smoothstep(bound, bound * 2.0, src_sd);

        res = lerp(res, out_avg, flat_weight * calm_weight * guard);
    }

    // Cap the repair: a band is a step or two tall, so a larger correction is
    // averaging away contrast rather than repairing a step.
    return out_centre + SoftLimit(res - out_centre, DebandMaxCorrection / DitherSteps);
}

// Presentation: repair banding, then dither, then hand the frame over. Dither has
// to be last, because it exists to survive the quantisation that happens on the
// way out, and anything that averages pixels afterwards would undo it.
float3 PS_Present(VS_OUTPUT input) : SV_Target
{
    float4 centre = tex2D(sTexCombined, input.uv);
    float3 blended = centre.rgb;

#if PHDRP_HDR_CHAIN
    return blended;
#else
    // Debug views arrive with alpha 0 and pass straight through.
    bool passthrough = Debug_Mask;

    float3 debanded = blended;

    [branch]
    if (EnableDeband && !passthrough)
    {
        float3 src = tex2D(sTexColor, input.uv).rgb;

        int taps = 8 * (clamp(DebandTaps, 0, 3) + 1);

        // Half a loop away and on a different channel from anything the dither
        // will use on this pixel. Drawn from the same value, the disc rotation and
        // the red dither would be a fixed function of each other, and whatever the
        // debander left behind would land in step with the grain meant to hide it.
        int   slice  = int((uint(FrameCount) + uint(STBN_DEPTH / 2)) % uint(STBN_DEPTH));
        float jitter = SampleBlueNoise(int2(input.uv * bb::ScreenSize), slice).b;

        // Alpha holds how far this shader moved the pixel. Banding the shader opened
        // up can be gone after hard; banding that was already there is treated more
        // gently. Both run every frame, crossfaded rather than switched.
        float effect = smoothstep(DebandSplit * 0.5, DebandSplit, centre.a);

        float3 strong = blended;
        float3 gentle = blended;

        [branch]
        if (EnableDebandEffect && effect > 0.0)
            strong = Deband(input.uv, blended, src, jitter,
                            DebandEffectThreshold, DebandEffectRadius,
                            DebandEffectIterations, taps, DebandEffectDetail);

        [branch]
        if (EnableDebandSource && effect < 1.0)
            gentle = Deband(input.uv, blended, src, jitter,
                            DebandSourceThreshold, DebandSourceRadius,
                            DebandSourceIterations, taps, DebandSourceDetail);

        debanded = lerp(gentle, strong, effect);
    }

    if (Debug_Deband)
        return saturate(abs(debanded - blended) * DitherSteps * 0.5);

    blended = debanded;

    // Triangular dither, one decorrelated pattern per channel.
    float3 dither = 0.0;

    if ((EnableDithering || Debug_Dithering) && !passthrough)
    {
        // A single value shared across the channels only dithers luminance, and
        // leaves a coloured gradient to band in whichever channel crosses its step
        // first, so all three paths below produce three separate values.
        float3 uniform_noise;

        if (DitherPattern == 1)
        {
            // Walk one slice of the volume per frame. The mask is built so that a
            // single pixel's values across the slices are themselves well spread,
            // so the grain settles instead of crawling when nothing is moving.
            int2 pixel = int2(input.uv * bb::ScreenSize);
            int  slice = int(uint(FrameCount) % uint(STBN_DEPTH));
            uniform_noise = SampleBlueNoise(pixel, slice);
        }
        else
        {
            // Scroll the pattern each frame so it reads as animated grain rather
            // than a fixed screen-space texture stuck on top of smooth gradients.
            float2 ign_pos = input.uv * bb::ScreenSize + 5.588238 * float(uint(FrameCount) % 64u);

            // The offsets are large and unrelated so the three land on genuinely
            // different parts of the pattern; the outer multiply of ~53 inside the
            // noise means even a small shift decorrelates them.
            uniform_noise = float3(
                InterleavedGradientNoise(ign_pos),
                InterleavedGradientNoise(ign_pos + float2(113.0, 271.0)),
                InterleavedGradientNoise(ign_pos + float2(571.0, 683.0)));
        }

        dither = float3(
            ReshapeUniformToTriangle(uniform_noise.r),
            ReshapeUniformToTriangle(uniform_noise.g),
            ReshapeUniformToTriangle(uniform_noise.b)) - 0.5;
    }

    // Banding needs a stretch of near-constant colour, so gate the repair on the
    // screen-space slope and leave textured regions alone.
    float lum_dx = abs(ddx(GetLuminance(blended)));
    float lum_dy = abs(ddy(GetLuminance(blended)));

    float gradient = lum_dx + lum_dy;

    float banding_mask = saturate(1.0 - gradient * 64.0);
    banding_mask *= banding_mask;

    // dither spans +/-1 at this point, so strength 1.0 lands one quantisation step
    // either side of the true colour.
    float3 applied = dither * (banding_mask * DitherStrength / DitherSteps);

    if (Debug_Dithering)
    {
        // Back up into step units and halved, so strength 1.0 fills the 0-1 range
        // exactly. The mask is included, so flat areas show the pattern and
        // detailed ones stay grey. Anything above 1.0 clips here, which is the
        // honest reading of a dither driven past the step it is correcting.
        return saturate(applied * DitherSteps * 0.5 + 0.5);
    }

    [branch]
    if (EnableDithering && !passthrough)
    {
        blended = saturate(blended + applied);
    }

    return blended;
#endif
}

technique DZ_PerceptualHDR
<
    ui_label = "Perceptual HDR Plus";
>
{
    pass Luma         { VertexShader = PostProcessVS; PixelShader = PS_Luma;                 RenderTarget = TexLuma;           }
    pass LumaLog      { VertexShader = PostProcessVS; PixelShader = PS_LumaLog;              RenderTarget = TexLumaLog;        }
    pass Luma512      { VertexShader = PostProcessVS; PixelShader = PS_Luma512;              RenderTarget = TexLuma512;        }
    pass Luma256      { VertexShader = PostProcessVS; PixelShader = PS_Luma256;              RenderTarget = TexLuma256;        }
    pass Luma128      { VertexShader = PostProcessVS; PixelShader = PS_Luma128;              RenderTarget = TexLuma128;        }
    pass Luma64       { VertexShader = PostProcessVS; PixelShader = PS_Luma64;               RenderTarget = TexLuma64;         }
    pass CalcAdapt    { VertexShader = PostProcessVS; PixelShader = PS_CalcAdapt;            RenderTarget = TexAdapt;          }
    pass SaveParams   { VertexShader = PostProcessVS; PixelShader = PS_SaveParams;           RenderTarget = TexLastParams;     }
    pass SaveAdapt    { VertexShader = PostProcessVS; PixelShader = PS_SaveAdapt;            RenderTarget = TexLastAdapt;      }

    pass CalcMeansH_Medium
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansH_Medium;
        RenderTarget = TexTempMeansMedium;
    }

    pass CalcMeansV_Medium
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansV_Medium;
        RenderTarget = TexStatsMedium;
    }

    pass CalcMeansH_Micro
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansH_Micro;
        RenderTarget = TexTempMeansMicro;
    }

    pass CalcMeansV_Micro
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansV_Micro;
        RenderTarget = TexStatsMicro;
    }

    pass CalcMeansH_Macro
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansH_Macro;
        RenderTarget = TexTempMeansMacro;
    }

    pass CalcMeansV_Macro
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CalcMeansV_Macro;
        RenderTarget = TexStatsMacro;
    }

    pass GuidedFilter
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_GuidedFilterResult;
        RenderTarget = TexVarI;
    }

    pass Combine
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_FinalCombine;
        RenderTarget = TexCombined;
    }

    pass Present
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_Present;
    }
}

} // namespace DZPHDR
