/* MIT License
 * 
 * Copyright (c) 2025 veka0
 * Copyright (c) 2026 th4llium
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#ifndef __CONSTANTS_HLSL__
#define __CONSTANTS_HLSL__

#define ENABLE_CLOUDS 0

#define ENABLE_VOLUMETRIC_CLOUDS 1

#define PERFORMANCE_TIER_FAST  0
#define PERFORMANCE_TIER_FANCY 1

#ifndef CURRENT_PERFORMANCE_TIER
#define CURRENT_PERFORMANCE_TIER PERFORMANCE_TIER_FAST
#endif

#if CURRENT_PERFORMANCE_TIER == PERFORMANCE_TIER_FAST
    #define VOLUMETRIC_STEPS               4
    #define VOLUMETRIC_SHADOW_RAYS         1
    #define VOLUMETRIC_CLOUD_STEPS         48
    #define VOLUMETRIC_CLOUD_LIGHT_STEPS   6
    #define VOLUMETRIC_CLOUD_SHADOW_STEPS  6
    #define VOLUMETRIC_LOCAL_LIGHT_COUNT   2
    #define VOLUMETRIC_LOCAL_LIGHT_SHADOW_COUNT 2
    #define VOLUMETRIC_LOCAL_LIGHT_MAX_DISTANCE 28.0
    #define VOLUMETRIC_LOCAL_LIGHT_INTENSITY 0.55
    #define VOLUMETRIC_LOCAL_LIGHT_RADIUS 1.35
    #define PERF_HIGH_RES_GI_RAY_COUNT     1
    #define PERF_HIGH_RES_GI_CHECKERBOARD  0
    #define PERF_HIGH_RES_GI_MIN_BLEND     0.85
    #define PERF_HIGH_RES_GI_CACHE_BOUNCE_STRENGTH 0.12
    #define PERF_CACHE_RAYS_PER_HEMISPHERE 2
    #define PERF_CACHE_POINT_LIGHT_COUNT   1
    #define PERF_IRRADIANCE_CACHE_MAX_LUMINANCE 32.0
    #define PERF_IRRADIANCE_CACHE_RECONSTRUCTION_STRENGTH 0.35
    #define PERF_IRRADIANCE_CACHE_PRIMARY_STRENGTH 0.15
    #define PERF_IRRADIANCE_CACHE_FALLBACK_STRENGTH 0.15
    #define PERF_IRRADIANCE_CACHE_BOUNCE_STRENGTH 0.15
    #define PERF_IRRADIANCE_CACHE_PATH_SUPPRESSION 0.15
    #define PERF_EMISSIVE_SURFACE_INTENSITY 18.0
    #define PERF_TRANSLUCENT_EMISSIVE_SURFACE_INTENSITY 26.0
    #define PERF_EMISSIVE_CACHE_SURFACE_SCALE 0.85
    #define PERF_EMISSIVE_LIGHT_INTENSITY_SCALE 1.85
    #define PERF_EMISSIVE_LIGHT_RADIUS 0.65
    #define PERF_EMISSIVE_LIGHT_SHADOW_BIAS 0.08
    #define PERF_EMISSIVE_CACHE_LIGHT_SCALE 0.55
    #define PERF_PRIMARY_LOCAL_LIGHT_COUNT 8
    #define PERF_SECONDARY_LOCAL_LIGHT_COUNT 2
    #define PERF_GLASS_LOCAL_LIGHT_COUNT   4
    #define PERF_DIELECTRIC_REFLECTION_PROBE_DISTANCE 128.0
    #define PERF_DIELECTRIC_REFLECTION_CACHE_BLEND 0.2
    #define PERF_DIELECTRIC_REFLECTION_AMBIENT_STRENGTH 0.45
    #define PERF_DIELECTRIC_REFLECTION_CACHE_AMBIENT_STRENGTH 0.25
    #define PERF_WATER_MIN_REFLECTION_WEIGHT 0.02
    #define PERF_MAX_PATH_BOUNCES          2
    #define PERF_RUSSIAN_ROULETTE_START    2
#else
    #define VOLUMETRIC_STEPS               16
    #define VOLUMETRIC_SHADOW_RAYS         16
    #define VOLUMETRIC_CLOUD_STEPS         48
    #define VOLUMETRIC_CLOUD_LIGHT_STEPS   6
    #define VOLUMETRIC_CLOUD_SHADOW_STEPS  8
    #define VOLUMETRIC_LOCAL_LIGHT_COUNT   4
    #define VOLUMETRIC_LOCAL_LIGHT_SHADOW_COUNT 3
    #define VOLUMETRIC_LOCAL_LIGHT_MAX_DISTANCE 38.0
    #define VOLUMETRIC_LOCAL_LIGHT_INTENSITY 0.7
    #define VOLUMETRIC_LOCAL_LIGHT_RADIUS 1.75
    #define PERF_HIGH_RES_GI_RAY_COUNT     2
    #define PERF_HIGH_RES_GI_CHECKERBOARD  0
    #define PERF_HIGH_RES_GI_MIN_BLEND     0.65
    #define PERF_HIGH_RES_GI_CACHE_BOUNCE_STRENGTH 0.35
    #define PERF_CACHE_RAYS_PER_HEMISPHERE 4
    #define PERF_CACHE_POINT_LIGHT_COUNT   4
    #define PERF_IRRADIANCE_CACHE_MAX_LUMINANCE 64.0
    #define PERF_IRRADIANCE_CACHE_RECONSTRUCTION_STRENGTH 0.6
    #define PERF_IRRADIANCE_CACHE_PRIMARY_STRENGTH 0.35
    #define PERF_IRRADIANCE_CACHE_FALLBACK_STRENGTH 0.35
    #define PERF_IRRADIANCE_CACHE_BOUNCE_STRENGTH 0.35
    #define PERF_IRRADIANCE_CACHE_PATH_SUPPRESSION 0.35
    #define PERF_EMISSIVE_SURFACE_INTENSITY 24.0
    #define PERF_TRANSLUCENT_EMISSIVE_SURFACE_INTENSITY 34.0
    #define PERF_EMISSIVE_CACHE_SURFACE_SCALE 1.1
    #define PERF_EMISSIVE_LIGHT_INTENSITY_SCALE 2.35
    #define PERF_EMISSIVE_LIGHT_RADIUS 0.9
    #define PERF_EMISSIVE_LIGHT_SHADOW_BIAS 0.08
    #define PERF_EMISSIVE_CACHE_LIGHT_SCALE 0.8
    #define PERF_PRIMARY_LOCAL_LIGHT_COUNT 25
    #define PERF_SECONDARY_LOCAL_LIGHT_COUNT 25
    #define PERF_GLASS_LOCAL_LIGHT_COUNT   25
    #define PERF_DIELECTRIC_REFLECTION_PROBE_DISTANCE 256.0
    #define PERF_DIELECTRIC_REFLECTION_CACHE_BLEND 0.5
    #define PERF_DIELECTRIC_REFLECTION_AMBIENT_STRENGTH 0.6
    #define PERF_DIELECTRIC_REFLECTION_CACHE_AMBIENT_STRENGTH 0.4
    #define PERF_WATER_MIN_REFLECTION_WEIGHT 0.035
    #define PERF_MAX_PATH_BOUNCES          4
    #define PERF_RUSSIAN_ROULETTE_START    3
#endif

float GetEmissiveLightAttenuation(float lightDistance)
{
    float effectiveDistance = max(
        lightDistance - PERF_EMISSIVE_LIGHT_RADIUS,
        0.08);
    return PERF_EMISSIVE_LIGHT_INTENSITY_SCALE
        / max(effectiveDistance * effectiveDistance, 0.001);
}

float GetEmissiveLightShadowTMax(float lightDistance)
{
    return max(lightDistance - PERF_EMISSIVE_LIGHT_SHADOW_BIAS, 0.0);
}

#define INSTANCE_MASK_OPAQUE_OR_ALPHA_TEST_PRIMARY   (1 << 0)
#define INSTANCE_MASK_OPAQUE_OR_ALPHA_TEST_SECONDARY (1 << 1)
#define INSTANCE_MASK_OPAQUE_OR_ALPHA_TEST_CHUNKS    (1 << 2)
#define INSTANCE_MASK_ALPHA_BLEND_PRIMARY            (1 << 3)
#define INSTANCE_MASK_ALPHA_BLEND_SECONDARY          (1 << 4)
#define INSTANCE_MASK_WATER                          (1 << 5)
#define INSTANCE_MASK_SUN_OR_MOON                    (1 << 6)

#define MEDIA_TYPE_WATER 0
#define MEDIA_TYPE_GLASS 1
#define MEDIA_TYPE_AIR   2
#define MEDIA_TYPE_CLOUD 3
#define MEDIA_TYPE_SOLID 4

#define MATERIAL_TYPE_OPAQUE      0
#define MATERIAL_TYPE_ALPHA_TEST  1
#define MATERIAL_TYPE_ALPHA_BLEND 2
#define MATERIAL_TYPE_WATER       3

static const uint kObjectInstanceFlagUsesIrradianceCache    = (1 << 0);
static const uint kObjectInstanceFlagHasMotionVectors       = (1 << 1);
static const uint kObjectInstanceFlagHasSeasonsTexture      = (1 << 2);
static const uint kObjectInstanceFlagMaskedMultiTexture     = (1 << 3);
static const uint kObjectInstanceFlagMultiTexture           = (1 << 4);
static const uint kObjectInstanceFlagMultiplicativeTint     = (1 << 5);
static const uint kObjectInstanceFlagUsesOverlayColor       = (1 << 6);
static const uint kObjectInstanceFlagClouds                 = (1 << 7);
static const uint kObjectInstanceFlagChunk                  = (1 << 8);
static const uint kObjectInstanceFlagSun                    = (1 << 9);
static const uint kObjectInstanceFlagMoon                   = (1 << 10);
static const uint kObjectInstanceFlagRemapTransparencyAlpha = (1 << 11);
static const uint kObjectInstanceFlagAlphaTestThresholdHalf = (1 << 12);
static const uint kObjectInstanceFlagTextureAlphaControlsVertexColor = (1 << 13);
static const uint kObjectInstanceFlagGlint                  = (1 << 14);
static const uint kObjectInstanceFlagUsesUvBiasPacking      = (1 << 15);

static const uint kInvalidPBRTextureHandle = 0xffff;
static const uint kPBRTextureDataFlagHasMaterialTexture             = (1 << 0);
static const uint kPBRTextureDataFlagHasSubsurfaceChannel           = (1 << 1);
static const uint kPBRTextureDataFlagHasNormalTexture               = (1 << 2);
static const uint kPBRTextureDataFlagHasHeightMapTexture            = (1 << 3);
static const uint kPBRTextureDataFlagHasPackedHeightNormalsTexture  = (1 << 4);

static const int kAdaptiveDenoiserLightFlagAddedToList      = (1 << 0);
static const int kAdaptiveDenoiserLightFlagRemovedFromList  = (1 << 1);

#define PI 3.14159265358979323846

#define CELESTIAL_AZIMUTH_OFFSET_RADIANS 0.5585053606
#define CELESTIAL_SHADOW_ANGULAR_RADIUS_RADIANS 0.012

#endif
