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

#ifndef DEBUG_DISABLE_SVGF
#define DEBUG_DISABLE_SVGF 0
#endif

#define PERFORMANCE_TIER_FAST  0
#define PERFORMANCE_TIER_FANCY 1

#ifndef CURRENT_PERFORMANCE_TIER
#define CURRENT_PERFORMANCE_TIER PERFORMANCE_TIER_FAST
#endif

#define PERF_SCENE_LUX_TO_ENGINE_RADIANCE (1.0 / 30000.0)

#if CURRENT_PERFORMANCE_TIER == PERFORMANCE_TIER_FAST
    #define VOLUMETRIC_STEPS               6
    #define VOLUMETRIC_SHADOW_RAYS         0
    #define VOLUMETRIC_CLOUD_STEPS         32
    #define VOLUMETRIC_CLOUD_LIGHT_STEPS   8
    #define VOLUMETRIC_CLOUD_SHADOW_STEPS  8
    #define VOLUMETRIC_LOCAL_LIGHT_COUNT   1
    #define VOLUMETRIC_LOCAL_LIGHT_SHADOW_COUNT 0
    #define VOLUMETRIC_LOCAL_LIGHT_MAX_DISTANCE 28.0
    #define VOLUMETRIC_LOCAL_LIGHT_INTENSITY 0.55
    #define VOLUMETRIC_LOCAL_LIGHT_RADIUS 1.35
    #define PERF_HIGH_RES_GI_RAY_COUNT     2
    #define PERF_HIGH_RES_GI_CHECKERBOARD  1
    #define PERF_HIGH_RES_GI_MIN_BLEND     0.94
    #define PERF_HIGH_RES_GI_CACHE_BOUNCE_STRENGTH 0.04
    #define PERF_HIGH_RES_GI_FIREFLY_MAX_LUMINANCE 18.0
    #define PERF_HIGH_RES_GI_FIREFLY_SUPPORT_SCALE 3.5
    #define PERF_HIGH_RES_GI_FIREFLY_BIAS 0.45
    #define PERF_CACHE_RAYS_PER_HEMISPHERE 1
    #define PERF_CACHE_POINT_LIGHT_COUNT   1
    #define PERF_IRRADIANCE_CACHE_MAX_LUMINANCE 18.0
    #define PERF_IRRADIANCE_CACHE_RECONSTRUCTION_SCALE_COUNT 1
    #define PERF_IRRADIANCE_CACHE_RECONSTRUCTION_STRENGTH 0.15
    #define PERF_IRRADIANCE_CACHE_PRIMARY_STRENGTH 0.05
    #define PERF_IRRADIANCE_CACHE_FALLBACK_STRENGTH 0.06
    #define PERF_IRRADIANCE_CACHE_BOUNCE_STRENGTH 0.08
    #define PERF_IRRADIANCE_CACHE_PATH_SUPPRESSION 0.15
    #define PERF_EMISSIVE_SURFACE_INTENSITY 360.0
    #define PERF_TRANSLUCENT_EMISSIVE_SURFACE_INTENSITY 430.0
    #define PERF_EMISSIVE_CACHE_SURFACE_SCALE 5.0
    #define PERF_LOCAL_LIGHT_REFERENCE_ILLUMINANCE_LUX 150000.0
    #define PERF_EMISSIVE_LIGHT_INTENSITY_SCALE (PERF_LOCAL_LIGHT_REFERENCE_ILLUMINANCE_LUX * PERF_SCENE_LUX_TO_ENGINE_RADIANCE)
    #define PERF_LOCAL_LIGHT_INTENSITY_GAMMA 0.55
    #define PERF_EMISSIVE_LIGHT_RADIUS 2.25
    #define PERF_EMISSIVE_LIGHT_SHADOW_BIAS 0.08
    #define PERF_EMISSIVE_CACHE_LIGHT_SCALE 1.25
    #define PERF_LOCAL_LIGHT_RADIANCE_SCALE 1.0
    #define PERF_PRIMARY_LOCAL_LIGHT_COUNT 1
    #define PERF_SECONDARY_LOCAL_LIGHT_COUNT 1
    #define PERF_GLASS_LOCAL_LIGHT_COUNT   1
    #define PERF_LOCAL_LIGHT_IMPORTANCE_CANDIDATES 256
    #define PERF_SECONDARY_LOCAL_LIGHT_IMPORTANCE_CANDIDATES 64
    #define PERF_GLASS_LOCAL_LIGHT_IMPORTANCE_CANDIDATES 128
    #define PERF_LOCAL_LIGHT_COVERAGE_MAX_WEIGHT 1.0
    #define PERF_LOCAL_LIGHT_GROUP_SHADOW_MIN_CONFIDENCE 0.30
    #define PERF_LOCAL_LIGHT_GROUP_MAX_ENERGY_RATIO 3.0
    #define PERF_SVGF_ATROUS_MAX_ITERATION 5
    #define PERF_DIFFUSE_TEMPORAL_MIN_ALPHA 0.18
    #define PERF_DIFFUSE_TEMPORAL_MAX_HISTORY 12.0
    #define PERF_DIFFUSE_HISTORY_CLIP_RANGE_SCALE 0.18
    #define PERF_DIFFUSE_HISTORY_CLIP_RELATIVE_EPSILON 0.06
    #define PERF_DIFFUSE_HISTORY_CLIP_ABSOLUTE_EPSILON 0.020
    #define PERF_SVGF_DIFFUSE_NORMAL_EXPONENT 192.0
    #define PERF_SVGF_DIFFUSE_LUMINANCE_SIGMA 2.2
    #define PERF_SVGF_DEPTH_RELATIVE_SCALE 96.0
    #define PERF_SVGF_DEPTH_ABSOLUTE_SCALE 1.0
    #define PERF_DIELECTRIC_REFLECTION_PROBE_DISTANCE 128.0
    #define PERF_WATER_REFLECTION_PROBE_DISTANCE 768.0
    #define PERF_WATER_REFLECTION_HORIZON_FALLBACK 0.45
    #define PERF_DIELECTRIC_REFLECTION_CACHE_BLEND 0.2
    #define PERF_DIELECTRIC_REFLECTION_AMBIENT_STRENGTH 0.45
    #define PERF_DIELECTRIC_REFLECTION_CACHE_AMBIENT_STRENGTH 0.25
    #define PERF_WATER_MIN_REFLECTION_WEIGHT 0.04
    #define PERF_TAA_BASE_ALPHA            0.10
    #define PERF_TAA_SKY_ALPHA             0.06
    #define PERF_TAA_MAX_BLEND             0.92
    #define PERF_MAX_PATH_BOUNCES          2
    #define PERF_RUSSIAN_ROULETTE_START    2
#else
    #define VOLUMETRIC_STEPS               24
    #define VOLUMETRIC_SHADOW_RAYS         1
    #define VOLUMETRIC_CLOUD_STEPS         32
    #define VOLUMETRIC_CLOUD_LIGHT_STEPS   8
    #define VOLUMETRIC_CLOUD_SHADOW_STEPS  8
    #define VOLUMETRIC_LOCAL_LIGHT_COUNT   4
    #define VOLUMETRIC_LOCAL_LIGHT_SHADOW_COUNT 3
    #define VOLUMETRIC_LOCAL_LIGHT_MAX_DISTANCE 38.0
    #define VOLUMETRIC_LOCAL_LIGHT_INTENSITY 0.7
    #define VOLUMETRIC_LOCAL_LIGHT_RADIUS 1.75
    #define PERF_HIGH_RES_GI_RAY_COUNT     2
    #define PERF_HIGH_RES_GI_CHECKERBOARD  1
    #define PERF_HIGH_RES_GI_MIN_BLEND     0.90
    #define PERF_HIGH_RES_GI_CACHE_BOUNCE_STRENGTH 0.08
    #define PERF_HIGH_RES_GI_FIREFLY_MAX_LUMINANCE 28.0
    #define PERF_HIGH_RES_GI_FIREFLY_SUPPORT_SCALE 4.5
    #define PERF_HIGH_RES_GI_FIREFLY_BIAS 0.65
    #define PERF_CACHE_RAYS_PER_HEMISPHERE 4
    #define PERF_CACHE_POINT_LIGHT_COUNT   4
    #define PERF_IRRADIANCE_CACHE_MAX_LUMINANCE 24.0
    #define PERF_IRRADIANCE_CACHE_RECONSTRUCTION_SCALE_COUNT 2
    #define PERF_IRRADIANCE_CACHE_RECONSTRUCTION_STRENGTH 0.25
    #define PERF_IRRADIANCE_CACHE_PRIMARY_STRENGTH 0.08
    #define PERF_IRRADIANCE_CACHE_FALLBACK_STRENGTH 0.10
    #define PERF_IRRADIANCE_CACHE_BOUNCE_STRENGTH 0.14
    #define PERF_IRRADIANCE_CACHE_PATH_SUPPRESSION 0.35
    #define PERF_EMISSIVE_SURFACE_INTENSITY 520.0
    #define PERF_TRANSLUCENT_EMISSIVE_SURFACE_INTENSITY 620.0
    #define PERF_EMISSIVE_CACHE_SURFACE_SCALE 7.0
    #define PERF_LOCAL_LIGHT_REFERENCE_ILLUMINANCE_LUX 220000.0
    #define PERF_EMISSIVE_LIGHT_INTENSITY_SCALE (PERF_LOCAL_LIGHT_REFERENCE_ILLUMINANCE_LUX * PERF_SCENE_LUX_TO_ENGINE_RADIANCE)
    #define PERF_LOCAL_LIGHT_INTENSITY_GAMMA 0.55
    #define PERF_EMISSIVE_LIGHT_RADIUS 3.0
    #define PERF_EMISSIVE_LIGHT_SHADOW_BIAS 0.08
    #define PERF_EMISSIVE_CACHE_LIGHT_SCALE 1.40
    #define PERF_LOCAL_LIGHT_RADIANCE_SCALE 1.0
    #define PERF_PRIMARY_LOCAL_LIGHT_COUNT 1
    #define PERF_SECONDARY_LOCAL_LIGHT_COUNT 1
    #define PERF_GLASS_LOCAL_LIGHT_COUNT   1
    #define PERF_LOCAL_LIGHT_IMPORTANCE_CANDIDATES 384
    #define PERF_SECONDARY_LOCAL_LIGHT_IMPORTANCE_CANDIDATES 128
    #define PERF_GLASS_LOCAL_LIGHT_IMPORTANCE_CANDIDATES 192
    #define PERF_LOCAL_LIGHT_COVERAGE_MAX_WEIGHT 1.0
    #define PERF_LOCAL_LIGHT_GROUP_SHADOW_MIN_CONFIDENCE 0.38
    #define PERF_LOCAL_LIGHT_GROUP_MAX_ENERGY_RATIO 3.5
    #define PERF_SVGF_ATROUS_MAX_ITERATION 5
    #define PERF_DIFFUSE_TEMPORAL_MIN_ALPHA 0.14
    #define PERF_DIFFUSE_TEMPORAL_MAX_HISTORY 16.0
    #define PERF_DIFFUSE_HISTORY_CLIP_RANGE_SCALE 0.22
    #define PERF_DIFFUSE_HISTORY_CLIP_RELATIVE_EPSILON 0.06
    #define PERF_DIFFUSE_HISTORY_CLIP_ABSOLUTE_EPSILON 0.018
    #define PERF_SVGF_DIFFUSE_NORMAL_EXPONENT 224.0
    #define PERF_SVGF_DIFFUSE_LUMINANCE_SIGMA 2.0
    #define PERF_SVGF_DEPTH_RELATIVE_SCALE 112.0
    #define PERF_SVGF_DEPTH_ABSOLUTE_SCALE 1.1
    #define PERF_DIELECTRIC_REFLECTION_PROBE_DISTANCE 256.0
    #define PERF_WATER_REFLECTION_PROBE_DISTANCE 1536.0
    #define PERF_WATER_REFLECTION_HORIZON_FALLBACK 0.55
    #define PERF_DIELECTRIC_REFLECTION_CACHE_BLEND 0.5
    #define PERF_DIELECTRIC_REFLECTION_AMBIENT_STRENGTH 0.6
    #define PERF_DIELECTRIC_REFLECTION_CACHE_AMBIENT_STRENGTH 0.4
    #define PERF_WATER_MIN_REFLECTION_WEIGHT 0.055
    #define PERF_TAA_BASE_ALPHA            0.08
    #define PERF_TAA_SKY_ALPHA             0.05
    #define PERF_TAA_MAX_BLEND             0.94
    #define PERF_MAX_PATH_BOUNCES          4
    #define PERF_RUSSIAN_ROULETTE_START    3
#endif

float GetEmissiveLightAttenuation(float lightDistance)
{
    float radius = max(PERF_EMISSIVE_LIGHT_RADIUS, 0.05);
    float effectiveDistance = max(lightDistance, 0.0);
    float softenedDistanceSq =
        effectiveDistance * effectiveDistance
        + radius * radius;
    float oneBlockSoftenedDistanceSq = 1.0 + radius * radius;
    return PERF_EMISSIVE_LIGHT_INTENSITY_SCALE
        * oneBlockSoftenedDistanceSq
        / max(softenedDistanceSq, 0.001);
}

float GetLocalLightIntensityWeight(float packedIntensity)
{
    return pow(saturate(packedIntensity), PERF_LOCAL_LIGHT_INTENSITY_GAMMA);
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
