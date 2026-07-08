#include "IrradianceCache.hlsl"

#ifndef WATER_INTERFACE_ROUGHNESS
#define WATER_INTERFACE_ROUGHNESS 0.035
#endif

#ifndef WATER_FRESNEL_BOOST
#define WATER_FRESNEL_BOOST 1.25
#endif

#ifndef MCRTX_PRIMARY_GUIDE_ONLY
#define MCRTX_PRIMARY_GUIDE_ONLY 0
#endif

float2 GetBlueNoise2D(inout RayState rayState) {
    uint3 noiseCoord = uint3(rayState.pixelCoord.xy % uint2(64, 32), g_view.frameCount % 8);
    float4 baseBlueNoise = blueNoiseTexture.Load(uint4(noiseCoord, 0));
    float2 offset = float2(rayState.blueNoiseSequence * 0.61803398875, rayState.blueNoiseSequence * 0.38196601125);
    rayState.blueNoiseSequence++;
    return frac(baseBlueNoise.xy + offset);
}

float GetBlueNoise1D(inout RayState rayState) {
    uint3 noiseCoord = uint3(rayState.pixelCoord.xy % uint2(64, 32), g_view.frameCount % 8);
    float4 baseBlueNoise = blueNoiseTexture.Load(uint4(noiseCoord, 0));
    float sampleValue =
        frac(baseBlueNoise.z + rayState.blueNoiseSequence * 0.61803398875);
    rayState.blueNoiseSequence++;
    return sampleValue;
}

#ifndef POINT_LIGHT_MAX_COUNT
#define POINT_LIGHT_MAX_COUNT 25
#endif

#ifndef POINT_LIGHT_SHADOW_RADIUS
#define POINT_LIGHT_SHADOW_RADIUS 0.035
#endif

#ifndef POINT_LIGHT_SHADOW_SAMPLES
#define POINT_LIGHT_SHADOW_SAMPLES 1
#endif

#ifndef POINT_LIGHT_BRDF_SCALE
#define POINT_LIGHT_BRDF_SCALE 700.0
#endif

float2 GetPointLightBlueNoise(uint2 pixelCoord)
{
    uint3 noiseCoord = uint3(pixelCoord.xy % uint2(64, 32), g_view.frameCount % 8);
    return blueNoiseTexture.Load(uint4(noiseCoord, 0)).xy;
}

void EvaluatePointLightBRDF(
    float3 normal,
    float3 V,
    float3 lightDirection,
    float3 F0,
    float3 diffuseColor,
    float roughness,
    float subsurface,
    out float3 diffuseBRDF,
    out float3 specularBRDF)
{
    float NdotV = max(dot(normal, V), 0.0001);
    float NdotL = max(dot(normal, lightDirection), 0.0001);
    float3 H = safeNormalize(V + lightDirection, normal);
    float NdotH = max(dot(normal, H), 0.0);
    float LdotH = max(dot(lightDirection, H), 0.0);

    float3 F = F_Schlick(max(dot(H, V), 0.0), F0);
    float D = D_GGX(NdotH, roughness);
    float G = G_Smith(NdotV, NdotL, roughness);
    float3 multipleScatter =
        FdezAgueraMultipleScattering(NdotV, NdotL, roughness, F0);
    specularBRDF =
        ((F * D * G) / (4.0 * max(NdotV * NdotL, 0.001)))
        + multipleScatter;

    diffuseBRDF = DisneyDiffuse(
        NdotL, NdotV, LdotH, roughness, diffuseColor);
    if (subsurface > 0.001) {
        diffuseBRDF = lerp(
            diffuseBRDF,
            BurleyNormalizedSSS(
                NdotL, NdotV, LdotH, roughness, diffuseColor),
            subsurface);
    }
    diffuseBRDF *= DiffuseEnergyWeight(F, multipleScatter);
}

float3 TracePointLightDiskShadow(
    float3 position,
    float3 normal,
    float3 lightDirection,
    float lightDistance,
    float2 blueNoise,
    int lightIndex)
{
    float3 T = safeNormalize(
        cross(
            abs(lightDirection.z) < 0.999
                ? float3(0, 0, 1)
                : float3(1, 0, 0),
            lightDirection),
        float3(1, 0, 0));
    float3 B = cross(lightDirection, T);
    float3 shadowTransmission = 0.0;

    [loop]
    for (int sampleIndex = 0; sampleIndex < POINT_LIGHT_SHADOW_SAMPLES; sampleIndex++) {
        float sampleSeed = (float)(
            sampleIndex + lightIndex * POINT_LIGHT_SHADOW_SAMPLES);
        float2 Xi = frac(
            blueNoise
            + float2(
                sampleSeed * 0.61803398875,
                sampleSeed * 0.38196601125));

        float r = POINT_LIGHT_SHADOW_RADIUS * sqrt(Xi.x);
        float theta = 2.0 * PI * Xi.y;
        float2 disk = r * float2(cos(theta), sin(theta));
        float3 sampleDirection = safeNormalize(
            lightDirection + disk.x * T + disk.y * B,
            lightDirection);

        RayDesc shadowRay;
        shadowRay.Origin = position + 1.0e-4 * normal;
        shadowRay.Direction = sampleDirection;
        shadowRay.TMin = 0.0;
        shadowRay.TMax = max(lightDistance - 0.55, 0.0);

        if (shadowRay.TMax <= 0.0) {
            shadowTransmission += 1.0;
        } else {
            ShadowPayload payload;
            TraceShadowRay(shadowRay, payload);
            shadowTransmission += payload.transmission;
        }
    }

    return shadowTransmission / (float)POINT_LIGHT_SHADOW_SAMPLES;
}

void AccumulateShadowedPointLights(
    float3 position,
    float3 normal,
    float3 V,
    float3 F0,
    float3 diffuseColor,
    float roughness,
    float subsurface,
    float2 blueNoise,
    out float3 directDiffuse,
    out float3 directSpecular)
{
    directDiffuse = 0.0;
    directSpecular = 0.0;

    int lightCount = min(POINT_LIGHT_MAX_COUNT, (int)g_view.cpuLightsCount);

    [loop]
    for (int lightIndex = 0; lightIndex < lightCount; lightIndex++) {
        LightInfo lightInfo = inputLightsBuffer[lightIndex];
        LightData lightData = UnpackLight(lightInfo.packedData);

        float3 toLight = lightInfo.position - position;
        float lightDistance = length(toLight);
        if (lightDistance <= 0.001)
            continue;

        float3 lightDirection = toLight / lightDistance;
        float NdotL = max(dot(normal, lightDirection), 0.0);
        if (NdotL <= 0.0)
            continue;

        float attenuation =
            NdotL / max(lightDistance * lightDistance, 1.0e-4);
        float3 shadowTransmission =
            TracePointLightDiskShadow(
                position,
                normal,
                lightDirection,
                lightDistance,
                blueNoise,
                lightIndex);
        float3 lightColor =
            lightData.intensity
            * lightData.color
            * shadowTransmission;

        if (!any(lightColor > 0.0))
            continue;

        float3 diffuseBRDF;
        float3 specularBRDF;
        EvaluatePointLightBRDF(
            normal,
            V,
            lightDirection,
            F0,
            diffuseColor,
            roughness,
            subsurface,
            diffuseBRDF,
            specularBRDF);

        float3 lightContrib =
            lightColor * attenuation * POINT_LIGHT_BRDF_SCALE;
        directDiffuse += lightContrib * diffuseBRDF;
        directSpecular += lightContrib * specularBRDF;
    }
}

int GetStableLocalLightCandidateIndex(
    int candidateIndex,
    int candidateCount,
    int totalCount)
{
    if (candidateCount <= 0 || totalCount <= candidateCount)
        return candidateIndex;

    return min(
        (candidateIndex * totalCount + totalCount / 2) / candidateCount,
        totalCount - 1);
}

float GetStableLocalLightCoverageWeight(
    int candidateCount,
    int totalCount)
{
    if (candidateCount <= 0 || totalCount <= candidateCount)
        return 1.0;

    return min(
        (float)totalCount / max((float)candidateCount, 1.0),
        PERF_LOCAL_LIGHT_COVERAGE_MAX_WEIGHT);
}

float GetStableLocalLightGroupShadowConfidence(
    float representativeCoherence,
    float representativeDominance)
{
    float representativeQuality =
        max(representativeCoherence, representativeDominance);
    return saturate(
        lerp(
            PERF_LOCAL_LIGHT_GROUP_SHADOW_MIN_CONFIDENCE,
            1.0,
            representativeQuality));
}

float3 ApplyStableLocalLightGroupVisibility(
    float3 unshadowedRadiance,
    float3 representativeTransmission,
    float representativeCoherence,
    float representativeDominance,
    float dominantLuminance)
{
    float confidence = GetStableLocalLightGroupShadowConfidence(
        representativeCoherence,
        representativeDominance);
    float3 groupVisibility =
        lerp((1.0).xxx, representativeTransmission, confidence);
    float3 visibleRadiance = unshadowedRadiance * groupVisibility;
    float visibleLuminance =
        getLuminance(max(visibleRadiance, (0.0).xxx));
    float maxLuminance =
        max(
            dominantLuminance * PERF_LOCAL_LIGHT_GROUP_MAX_ENERGY_RATIO,
            1.0e-4);
    return visibleLuminance > maxLuminance
        ? visibleRadiance * (maxLuminance / visibleLuminance)
        : visibleRadiance;
}

static const int MAX_PATH_BOUNCES = PERF_MAX_PATH_BOUNCES;
static const int RUSSIAN_ROULETTE_START_BOUNCE = PERF_RUSSIAN_ROULETTE_START;

float3 GetDielectricExtinction(float3 color, float opacity)
{
    float3 clampedColor = max(saturate(color), 0.001);
    float maximumChannel = max(
        clampedColor.r, max(clampedColor.g, clampedColor.b));
    float minimumChannel = min(
        clampedColor.r, min(clampedColor.g, clampedColor.b));
    float saturation = (maximumChannel - minimumChannel) / maximumChannel;
    float tintStrength = saturate(opacity) * smoothstep(0.08, 0.35, saturation);
    float3 tint = clampedColor / maximumChannel;
    float3 transmittancePerBlock = lerp((1.0).xxx, tint, tintStrength);
    return -log(clamp(transmittancePerBlock, 0.02, 1.0)) * 0.65;
}

float3 GetThinSurfaceTransmittance(float3 color, float opacity)
{
    float3 thinTint = clamp(saturate(color), 0.04, 1.0);
    float opticalDepth = saturate(opacity) * 0.35;
    return exp(log(thinTint) * opticalDepth);
}

float3 ClampIndirectRadiance(float3 radiance, float maxLuminance)
{
    float luminance = getLuminance(max(radiance, 0.0));
    return luminance > maxLuminance
        ? radiance * (maxLuminance / luminance)
        : radiance;
}

float GetEnvironmentCloudDither(float3 position, float3 direction)
{
    float2 hashInput =
        position.xz * 0.071
        + direction.xy * 17.0
        + (float)(g_view.frameCount & 127u) * float2(0.17, 0.31);
    return Hash21(hashInput);
}

float3 GetCloudyTransparentEnvironmentSky(
    float3 origin,
    float3 direction,
    float dither)
{
    float3 rayDirection = safeNormalize(direction, float3(0, 1, 0));
    float3 environment = GetTransparentEnvironmentSky(rayDirection);

#if ENABLE_VOLUMETRIC_CLOUDS
    float cloudTransmittance;
    float3 cloudInscatter;
    ComputeDirectVolumetricClouds(
        origin,
        rayDirection,
        65504.0,
        dither,
        cloudTransmittance,
        cloudInscatter);
    environment = environment * cloudTransmittance + cloudInscatter;
#endif

    return max(environment, 0.0);
}

float3 EvaluateDielectricReflectionAmbient(
    HitInfo hitInfo,
    ObjectInstance objectInstance)
{
    GeometryInfo geometryInfo =
        GetGeometryInfo(hitInfo, objectInstance);
    SurfaceInfo surfaceInfo =
        MaterialVanilla(hitInfo, geometryInfo, objectInstance);

    if (surfaceInfo.shouldDiscard)
        return (0.0).xxx;

    float3 diffuseColor =
        surfaceInfo.color * (1.0 - surfaceInfo.metalness);
    float3 ambientRadiance = 0.0;

    IrradianceCacheSample incoming =
        SampleIncomingIrradianceCache(hitInfo, objectInstance);
    ambientRadiance += diffuseColor
        * incoming.irradiance
        * (incoming.confidence
            * PERF_DIELECTRIC_REFLECTION_CACHE_AMBIENT_STRENGTH / PI);

    if (surfaceInfo.emissive > 0.0) {
        ambientRadiance += surfaceInfo.color
            * surfaceInfo.emissive
            * PERF_EMISSIVE_CACHE_SURFACE_SCALE;
    }

    return ClampIndirectRadiance(ambientRadiance, 32.0);
}

float3 TraceDielectricReflectionProbe(
    float3 position,
    float3 normal,
    float3 direction,
    float maxDistance,
    bool useWaterFallback)
{
    RayDesc reflectionRay;
    reflectionRay.Origin =
        position
        + normal * (dot(direction, normal) >= 0.0 ? 1.0e-3 : -1.0e-3);
    reflectionRay.Direction = safeNormalize(direction, normal);
    reflectionRay.TMin = 0.0;
    reflectionRay.TMax = maxDistance;

    RayQuery<RAY_FLAG_NONE> query;
    query.TraceRayInline(
        SceneBVH,
        RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES,
        INSTANCE_MASK_OPAQUE_OR_ALPHA_TEST_SECONDARY,
        reflectionRay);

    while (query.Proceed())
    {
        HitInfo candidate = GetCandidateHitInfo(query);
        if (AlphaTestHitLogic(candidate))
            query.CommitNonOpaqueTriangleHit();
    }

    if (query.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
    {
        HitInfo reflectedHit = GetCommittedHitInfo(query);
        ObjectInstance reflectedObject =
            objectInstances[reflectedHit.objectInstanceIndex];
        float cacheConfidence;
        float3 cachedRadiance = SampleOutgoingRadianceCache(
            reflectedHit, reflectedObject, cacheConfidence);
        float3 directRadiance = EvaluateCachedOutgoingRadiance(
            reflectedHit, reflectedObject, (0.0).xxx);
        float3 ambientRadiance = EvaluateDielectricReflectionAmbient(
            reflectedHit, reflectedObject);
        float ambientBlend = saturate(
            1.0 - getLuminance(directRadiance)
                / max(getLuminance(ambientRadiance) * 2.0, 1.0e-4));
        float3 uncachedRadiance =
            directRadiance + ambientRadiance * ambientBlend;
        return ClampIndirectRadiance(
            lerp(
                uncachedRadiance,
                cachedRadiance,
                cacheConfidence
                    * PERF_DIELECTRIC_REFLECTION_CACHE_BLEND),
            64.0);
    }

    float3 environment = GetCloudyTransparentEnvironmentSky(
        reflectionRay.Origin,
        direction,
        GetEnvironmentCloudDither(position, direction));

    if (useWaterFallback) {
        float horizonFallback =
            1.0 - smoothstep(0.02, 0.28, reflectionRay.Direction.y);
        float3 horizonDirection =
            safeNormalize(
                float3(
                    reflectionRay.Direction.x,
                    max(reflectionRay.Direction.y, 0.04),
                    reflectionRay.Direction.z),
                float3(0, 1, 0));
        float3 horizonSky =
            GetTransparentEnvironmentSky(horizonDirection);
        environment = max(
            environment,
            horizonSky
                * (PERF_WATER_REFLECTION_HORIZON_FALLBACK
                    * horizonFallback));
    }

    return environment;
}

float2 GetRainPuddleDiskOffset(float2 sampleValue)
{
    float radius = sqrt(saturate(sampleValue.x));
    float angle = sampleValue.y * 2.0 * PI;
    return float2(cos(angle), sin(angle)) * radius;
}

bool IsRainPuddleSkyVisible(
    float3 position,
    float3 normal,
    float2 sampleValue)
{
    float3 tangentReference =
        abs(normal.y) < 0.999
            ? float3(0.0, 1.0, 0.0)
            : float3(1.0, 0.0, 0.0);
    float3 tangent = safeNormalize(
        cross(tangentReference, normal),
        float3(1.0, 0.0, 0.0));
    float3 bitangent = cross(normal, tangent);
    float2 diskOffset = GetRainPuddleDiskOffset(sampleValue) * 0.42;

    RayDesc skyRay;
    skyRay.Origin =
        position
        + normal * 0.080
        + tangent * diskOffset.x
        + bitangent * diskOffset.y;
    skyRay.Direction =
        safeNormalize(
            float3(
                (sampleValue.x - 0.5) * 0.22,
                1.0,
                (sampleValue.y - 0.5) * 0.22),
            float3(0.0, 1.0, 0.0));
    skyRay.TMin = 0.050;
    skyRay.TMax = WEATHER_RAIN_PUDDLE_SKY_TEST_DISTANCE;

    RayQuery<
        RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES
        | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> query;
    query.TraceRayInline(
        SceneBVH,
        RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES
            | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH,
        INSTANCE_MASK_OPAQUE_OR_ALPHA_TEST_SECONDARY
            | INSTANCE_MASK_ALPHA_BLEND_SECONDARY,
        skyRay);

    while (query.Proceed())
    {
        HitInfo hitInfo;
        hitInfo.rayT = query.CandidateTriangleRayT();
        hitInfo.frontFacing = query.CandidateTriangleFrontFace();
        hitInfo.barycentric2 = query.CandidateTriangleBarycentrics();
        hitInfo.materialType = query.CandidateInstanceID();
        hitInfo.objectInstanceIndex = query.CandidateInstanceIndex();
        hitInfo.primitiveId = query.CandidatePrimitiveIndex();

        ObjectInstance object =
            objectInstances[hitInfo.objectInstanceIndex];
        bool isCloud =
            (object.flags & kObjectInstanceFlagClouds)
            || ((object.offsetPack5 >> 8) == MEDIA_TYPE_CLOUD);
        if (isCloud)
            continue;

        if (hitInfo.materialType == MATERIAL_TYPE_ALPHA_TEST
            && !AlphaTestHitLogic(hitInfo))
        {
            continue;
        }

        query.CommitNonOpaqueTriangleHit();
    }

    return query.CommittedStatus() == COMMITTED_NOTHING;
}

float GetRainPuddleAmount(
    float3 position,
    float3 normal,
    float2 skySampleValue)
{
    float wetness = GetWeatherSurfaceWetness();
    float rainAmount = GetWeatherRainAmount();
    if (wetness <= 0.001 || rainAmount <= 0.001)
        return 0.0;

    float topSurface = smoothstep(0.58, 0.92, normal.y);
    if (topSurface <= 0.0)
        return 0.0;

    float3 stablePosition = GetCloudStableWorldPosition(position);
    float2 puddleCoord = stablePosition.xz * WEATHER_RAIN_PUDDLE_NOISE_SCALE;
    float broadNoise = WeatherNoise2D(puddleCoord);
    float detailNoise =
        WeatherNoise2D(puddleCoord * 3.7 + float2(17.1, 43.7));
    float puddleNoise =
        smoothstep(
            0.30,
            0.67,
            broadNoise * 0.72 + detailNoise * 0.28 + wetness * 0.22);

    bool skyVisible =
        IsRainPuddleSkyVisible(position, normal, skySampleValue);

    return saturate(
        (skyVisible ? 1.0 : 0.0)
        * topSurface
        * puddleNoise
        * wetness
        * rainAmount
        * WEATHER_RAIN_PUDDLE_STRENGTH);
}

float3 GetSurfaceMediumExtinction(
    uint mediumType,
    float3 color,
    float opacity)
{
    if (mediumType == MEDIA_TYPE_GLASS)
        return GetDielectricExtinction(color, opacity);

    float3 engineExtinction = max(
        g_view.mediaExtinction[min(mediumType, 4u)].rgb,
        0.0);
    if (mediumType == MEDIA_TYPE_WATER) {
        return GetWaterExtinctionCoefficient(engineExtinction);
    }
    return engineExtinction;
}

void StorePrimarySurfaceMetadata(
    inout RayState rayState,
    SurfaceInfo surfaceInfo,
    float3 baseColor,
    float3 diffuseColor,
    float metalness,
    float roughness,
    uint materialClass)
{
    if (rayState.foundPrimarySurface)
        return;

    rayState.primaryBaseColor = baseColor;
    rayState.primaryAlbedo = diffuseColor;
    rayState.primaryNormal = surfaceInfo.normal;
    rayState.primaryRoughness = max(roughness, 0.02);
    rayState.primaryMetalness = metalness;
    rayState.primaryOpacity = saturate(surfaceInfo.alpha);
    rayState.primarySubsurface = saturate(surfaceInfo.subsurface);
    rayState.primaryWorldPosition = surfaceInfo.position;
    rayState.primaryViewDirection = rayState.rayDesc.Direction;
    rayState.primaryThroughputAtHit = rayState.throughput;
    rayState.primaryMaterialClass = materialClass;
}

void StorePrimarySurfaceDistanceAndMotion(
    inout RayState rayState,
    float hitDistance,
    float3 position,
    float3 previousPosition)
{
    if (rayState.foundPrimarySurface)
        return;

    rayState.distance = rayState.accumulatedDistance + hitDistance;
    rayState.motion = position - previousPosition;
}

bool ContinueOpaquePath(
    inout RayState rayState,
    float3 position,
    float3 normal,
    float3 direction,
    float3 pathWeight,
    bool isSpecular,
    float roughness,
    float rayConeRadiusAtHit)
{
    if (any(isnan(pathWeight)) || any(isinf(pathWeight)) || all(pathWeight <= 0.0)) {
        rayState.terminate = true;
        return false;
    }

    rayState.throughput *= max(pathWeight, 0.0);
    if (any(isnan(rayState.throughput)) || any(isinf(rayState.throughput))) {
        rayState.terminate = true;
        return false;
    }

    if (rayState.primaryLobe == kPrimaryLobeNone)
        rayState.primaryLobe = isSpecular
            ? kPrimaryLobeSpecular
            : kPrimaryLobeDiffuse;

    rayState.bounceCount++;
    if (rayState.bounceCount >= MAX_PATH_BOUNCES) {
        rayState.terminate = true;
        return false;
    }

    if (rayState.bounceCount >= RUSSIAN_ROULETTE_START_BOUNCE) {
        float surviveProbability = clamp(
            max(rayState.throughput.r, max(rayState.throughput.g, rayState.throughput.b)),
            0.35, 0.95);
        if (GetBlueNoise1D(rayState) > surviveProbability) {
            rayState.terminate = true;
            return false;
        }
        rayState.throughput /= surviveProbability;
    }

    float coneRoughness = isSpecular ? roughness * roughness : 0.5;
    rayState.rayConeRadius = rayConeRadiusAtHit;
    rayState.rayConeSpread = sqrt(
        rayState.rayConeSpread * rayState.rayConeSpread + coneRoughness * coneRoughness);
    rayState.hasRayCone = true;
    rayState.rayDesc.Origin = position + normal * 1.0e-4;
    rayState.rayDesc.Direction = safeNormalize(direction, normal);
    rayState.rayDesc.TMin = 0.0;
    return true;
}

void RenderVanilla(HitInfo hitInfo, inout RayState rayState)
{
    ObjectInstance objectInstance = objectInstances[hitInfo.objectInstanceIndex];
    GeometryInfo geometryInfo = GetGeometryInfo(hitInfo, objectInstance);
    float rayConeRadiusAtHit = min(
        rayState.rayConeRadius + rayState.rayConeSpread * max(hitInfo.rayT, 0.0),
        10000.0);
    float materialRayConeRadius =
        rayState.hasRayCone ? rayConeRadiusAtHit : 0.0;
    SurfaceInfo surfaceInfo = MaterialVanilla(
        hitInfo, geometryInfo, objectInstance, materialRayConeRadius, rayState.rayDesc.Direction);
    
    if (hitInfo.materialType == MATERIAL_TYPE_WATER) {
        surfaceInfo.normal = GetWaterNormal(surfaceInfo.position, g_view.time, surfaceInfo.normal);
    }

    if (hitInfo.materialType == MATERIAL_TYPE_OPAQUE || hitInfo.materialType == MATERIAL_TYPE_ALPHA_TEST) surfaceInfo.alpha = 1;

    bool isCloud = (objectInstance.flags & kObjectInstanceFlagClouds) || ((objectInstance.offsetPack5 >> 8) == MEDIA_TYPE_CLOUD);
    if (isCloud)
    {
#if !ENABLE_CLOUDS
        rayState.rayDesc.TMin = hitInfo.rayT + 0.001;
        return;
#endif
    }

    const bool isBlockBreakingOverlay = objectInstance.flags == (kObjectInstanceFlagAlphaTestThresholdHalf | kObjectInstanceFlagTextureAlphaControlsVertexColor);

    bool isRainPuddleCandidate =
        rayState.bounceCount == 0
        && !rayState.foundPrimarySurface
        && hitInfo.materialType == MATERIAL_TYPE_OPAQUE
        && (objectInstance.flags & kObjectInstanceFlagChunk)
        && surfaceInfo.emissive <= 0.001
        && surfaceInfo.metalness < 0.5
        && GetWeatherRainAmount() > 0.001
        && GetWeatherSurfaceWetness() > 0.001;
    float rainPuddleAmount = isRainPuddleCandidate
        ? GetRainPuddleAmount(
            surfaceInfo.position,
            surfaceInfo.normal,
            GetBlueNoise2D(rayState))
        : 0.0;
    if (rainPuddleAmount > 0.0) {
        surfaceInfo.color *= lerp(1.0, 0.62, rainPuddleAmount * 0.55);
        surfaceInfo.roughness =
            lerp(surfaceInfo.roughness, 0.018, rainPuddleAmount);
        surfaceInfo.subsurface *= 1.0 - rainPuddleAmount;
    }

    float3 V = normalize(-rayState.rayDesc.Direction);
    float3 diffuseColor = surfaceInfo.color * (1.0 - surfaceInfo.metalness);
    float3 F0 = lerp((0.04).xxx, surfaceInfo.color, surfaceInfo.metalness);
    float originalRoughness = surfaceInfo.roughness;
    float roughness = max(originalRoughness, 0.035);
    if (rainPuddleAmount > 0.0) {
        F0 = lerp(F0, (0.02).xxx, rainPuddleAmount);
        diffuseColor *= 1.0 - 0.32 * rainPuddleAmount;
    }
    float NdotV = max(dot(surfaceInfo.normal, V), 0.0001);

    float3 sunDir = getOffsetTrueDirectionToSun();
    float3 moonDir = getOffsetTrueDirectionToMoon();
    float sunFade = GetSunAmount(sunDir);
    float moonFade = GetMoonAmount(sunDir, moonDir);
    float isSun = step(moonFade, sunFade);
    float3 mainLightDir = lerp(moonDir, sunDir, isSun);
    float mainLightFade = lerp(moonFade, sunFade, isSun);

    bool isWater = hitInfo.materialType == MATERIAL_TYPE_WATER;
    if (isWater
        || surfaceInfo.alpha < 1.0
        || isBlockBreakingOverlay)
    {
        bool isGlassMedium = (objectInstance.offsetPack5 >> 8) == MEDIA_TYPE_GLASS;
        bool isGlass = hitInfo.materialType != MATERIAL_TYPE_WATER
            && isGlassMedium
            && (surfaceInfo.alpha < 1.0 || hitInfo.materialType == MATERIAL_TYPE_ALPHA_TEST);

#if MCRTX_PRIMARY_GUIDE_ONLY
        if (isWater || isGlass) {
            if (!rayState.foundPrimarySurface) {
                uint materialClass = isWater
                    ? kPrimaryMaterialWater
                    : kPrimaryMaterialGlass;
                StorePrimarySurfaceMetadata(
                    rayState,
                    surfaceInfo,
                    surfaceInfo.color,
                    diffuseColor,
                    0.0,
                    isWater ? WATER_INTERFACE_ROUGHNESS : originalRoughness,
                    materialClass);
                StorePrimarySurfaceDistanceAndMotion(
                    rayState,
                    hitInfo.rayT,
                    surfaceInfo.position,
                    surfaceInfo.prevPosition);
                rayState.hitGlassPrimary = isGlass;
                rayState.primaryDielectricSurfaceSeen = true;

                if (surfaceInfo.emissive > 0.0) {
                    rayState.primaryEmission +=
                        surfaceInfo.color
                        * surfaceInfo.emissive
                        * PERF_TRANSLUCENT_EMISSIVE_SURFACE_INTENSITY
                        * rayState.globalExposure
                        * rayState.throughput;
                }
                rayState.foundPrimarySurface = true;
            }

            rayState.accumulatedDistance += hitInfo.rayT;
            rayState.terminate = true;
            return;
        }
#endif
        
        if (isBlockBreakingOverlay) {
            rayState.throughput *= surfaceInfo.color;
            rayState.rayDesc.TMin = hitInfo.rayT + 0.001;
        } else if (isWater || isGlass) {
            bool isPrimaryDielectricPath =
                !rayState.foundPrimarySurface
                && rayState.bounceCount == 0;
            bool isFirstVisibleGlass =
                isPrimaryDielectricPath
                && !rayState.primaryDielectricSurfaceSeen;
            uint dielectricPath = isPrimaryDielectricPath
                ? rayState.dielectricPath
                : kDielectricPathSample;
            float dielectricRoughness = isWater
                ? WATER_INTERFACE_ROUGHNESS
                : roughness;
            float3 dielectricF0Color = isWater
                ? (0.02).xxx
                : F0;
            {
                float3 sunlight = 0;
                float3 localSpecular = 0;
                float3 skyAmbient = 0;
                float NdotL_main = dot(surfaceInfo.normal, mainLightDir);
                
                if (dielectricPath != kDielectricPathRefract
                    && NdotL_main > 0.0)
                {
                    float3 L = mainLightDir;
                    float3 H = safeNormalize(V + L, surfaceInfo.normal);
                    float NdotL = max(dot(surfaceInfo.normal, L), 0.0001);
                    float NdotH = max(dot(surfaceInfo.normal, H), 0.0);
                    
                    float3 F = F_Schlick(
                        max(dot(H, V), 0.0),
                        dielectricF0Color);
                    float D = D_GGX(
                        NdotH, dielectricRoughness);
                    float G = G_Smith(
                        NdotV, NdotL, dielectricRoughness);
                    float3 specular = ((F * D * G)
                        / (4.0 * NdotV * NdotL))
                        + FdezAgueraMultipleScattering(
                            NdotV,
                            NdotL,
                            dielectricRoughness,
                            dielectricF0Color);
                    
                    float3 sunRadiance; float sunLux;
                    GetSunColorAndLux(surfaceInfo.position, sunDir, sunRadiance, sunLux);
                    float3 moonRadiance; float moonLux;
                    GetMoonColorAndLux(surfaceInfo.position, sunDir, moonDir, moonRadiance, moonLux);
                    float3 mainRadiance = lerp(moonRadiance, sunRadiance, isSun);
                    
                    sunlight = mainRadiance * 0.75 * mainLightFade * specular * NdotL * PI; 
                }

                if (dielectricPath != kDielectricPathRefract) {
                    if (isWater) {
                        skyAmbient = 0.0;
                    }

                    float3 unusedLocalDiffuse;
                    float3 tracedLocalSpecular;
                    AccumulateShadowedPointLights(
                        surfaceInfo.position,
                        surfaceInfo.normal,
                        V,
                        dielectricF0Color,
                        0.0.xxx,
                        dielectricRoughness,
                        0.0,
                        GetBlueNoise2D(rayState),
                        unusedLocalDiffuse,
                        tracedLocalSpecular);
                    localSpecular += tracedLocalSpecular;
                }
                
                float3 emission =
                    dielectricPath != kDielectricPathRefract
                    ? sunlight + localSpecular + skyAmbient
                    : (0.0).xxx;
                if (dielectricPath != kDielectricPathReflect
                    && surfaceInfo.emissive > 0.0)
                    emission += surfaceInfo.color
                        * surfaceInfo.emissive
                        * PERF_EMISSIVE_SURFACE_INTENSITY;
                emission *= rayState.globalExposure;
                rayState.color += emission * rayState.throughput;
                if (!rayState.foundPrimarySurface) {
                    rayState.primaryEmission += emission * rayState.throughput;
                } else if (
                    rayState.primaryLobe == kPrimaryLobeSpecular)
                {
                    rayState.primaryEmission += emission * rayState.throughput;
                } else {
                    rayState.diffuseIrradiance +=
                        emission * rayState.throughput
                        / max(rayState.primaryAlbedo, 0.001);
                }
            }

            uint surfaceMediumType = isWater
                ? MEDIA_TYPE_WATER
                : MEDIA_TYPE_GLASS;
            float etaIncident = GetCurrentMediumIor(rayState);
            float etaTransmitted = hitInfo.frontFacing
                ? GetMediumIor(surfaceMediumType)
                : GetExitMediumIor(rayState, surfaceMediumType);
            float eta = etaIncident / max(etaTransmitted, 0.001);

            float interfaceRoughness = max(
                dielectricRoughness, 0.001);
            bool stabilizePrimaryTransmission =
                isFirstVisibleGlass
                && dielectricPath == kDielectricPathRefract
                && !isWater;
            interfaceRoughness = stabilizePrimaryTransmission
                ? min(interfaceRoughness, 0.004)
                : interfaceRoughness;
            float3 interfaceNormal = interfaceRoughness > 0.015
                ? SampleGGXMicrofacetNormal(
                    V,
                    surfaceInfo.normal,
                    interfaceRoughness,
                    GetBlueNoise2D(rayState))
                : surfaceInfo.normal;

            float3 refrDir = refract(-V, interfaceNormal, eta);
            float3 reflDir = reflect(-V, interfaceNormal);

            float dielectricF0 = (
                (etaTransmitted - etaIncident)
                / max(etaTransmitted + etaIncident, 0.001));
            dielectricF0 *= dielectricF0;
            float F = F_Schlick(
                max(dot(interfaceNormal, V), 0.0),
                dielectricF0.xxx).x;
            if (isWater)
                F = saturate(F * WATER_FRESNEL_BOOST);
            bool totalInternalReflection =
                dot(refrDir, refrDir) < 0.000001
                || dot(refrDir, surfaceInfo.normal) >= 0.0;
            if (totalInternalReflection) {
                F = 1.0;
                refrDir = reflDir;
            } else if (isWater && dielectricPath == kDielectricPathRefract) {
                float t = g_view.time * 2.0;
                float3 noisePos = surfaceInfo.position * 0.5 + refrDir * 2.0;
                float3 wobble = sin(noisePos * float3(2.5, 2.0, 2.2) + float3(-t, t, t*1.1));
                refrDir = normalize(refrDir + wobble * 0.005);
            }

            float reflectionProbability = totalInternalReflection ? 1.0 : clamp(F, 0.1, 0.9);
            bool isReflection;
            if (dielectricPath == kDielectricPathReflect) {
                isReflection = true;
            } else if (dielectricPath == kDielectricPathRefract) {
                isReflection = totalInternalReflection;
            } else {
                isReflection = GetBlueNoise1D(rayState) < reflectionProbability;
            }

            if (isFirstVisibleGlass) {
                rayState.hitGlassPrimary = !totalInternalReflection;
                rayState.primaryDielectricSurfaceSeen = true;
            }

            if (isFirstVisibleGlass
                && dielectricPath == kDielectricPathRefract
                && !totalInternalReflection)
            {
                float skyReflectionWeight =
                    isWater
                        ? max(F, PERF_WATER_MIN_REFLECTION_WEIGHT)
                        : F;
                float3 surfaceReflection =
                    TraceDielectricReflectionProbe(
                        surfaceInfo.position,
                        surfaceInfo.normal,
                        reflDir,
                        isWater
                            ? PERF_WATER_REFLECTION_PROBE_DISTANCE
                            : PERF_DIELECTRIC_REFLECTION_PROBE_DISTANCE,
                        isWater)
                    * skyReflectionWeight
                    * rayState.throughput;
                rayState.primaryEmission += surfaceReflection;
                rayState.color += surfaceReflection;
            }

            if (dielectricPath == kDielectricPathSample) {
                float eventProbability = isReflection
                    ? reflectionProbability
                    : (1.0 - reflectionProbability);
                float transmissionScale =
                    isWater ? 1.0 : eta * eta;
                float eventResponse = isReflection
                    ? F
                    : (1.0 - F) * transmissionScale;
                rayState.throughput *= eventResponse / max(eventProbability, 0.0001);

                float missingF = isReflection ? (1.0 - F) : F;
                if (missingF > 0.01) {
                    float3 missingDir = isReflection ? refrDir : reflDir;
                    float3 missingSkyRadiance =
                        GetCloudyTransparentEnvironmentSky(
                            surfaceInfo.position,
                            missingDir,
                            GetBlueNoise1D(rayState));
                    float3 missingContrib = missingSkyRadiance * missingF;
                    rayState.color += missingContrib * rayState.throughput
                        * (eventProbability / max(eventResponse, 0.0001));
                }
            } else {
                float transmissionScale =
                    isWater ? 1.0 : eta * eta;
                rayState.throughput *= isReflection
                    ? F
                    : (1.0 - F) * transmissionScale;
            }

            if (!isReflection) {
                if (hitInfo.frontFacing) {
                    EnterMedium(
                        rayState,
                        surfaceMediumType,
                        GetSurfaceMediumExtinction(
                            surfaceMediumType,
                            surfaceInfo.color,
                            surfaceInfo.alpha));
                } else {
                    ExitMedium(rayState, surfaceMediumType);
                }
            }

            if (isFirstVisibleGlass && isReflection) {
                StorePrimarySurfaceMetadata(
                    rayState,
                    surfaceInfo,
                    surfaceInfo.color,
                    (1.0).xxx,
                    0.0,
                    isWater ? WATER_INTERFACE_ROUGHNESS : originalRoughness,
                    kPrimaryMaterialFullTraced);
                StorePrimarySurfaceDistanceAndMotion(
                    rayState,
                    hitInfo.rayT,
                    surfaceInfo.position,
                    surfaceInfo.prevPosition);
                rayState.foundPrimarySurface = true;
                rayState.primaryLobe = kPrimaryLobeSpecular;
                rayState.primaryAlbedo = (1.0).xxx;
                rayState.primaryNormal = surfaceInfo.normal;
                rayState.primaryRoughness = isWater
                    ? WATER_INTERFACE_ROUGHNESS
                    : max(originalRoughness, 0.02);
                rayState.primaryMetalness = 0.0;
                rayState.distance = rayState.accumulatedDistance + hitInfo.rayT;
                rayState.motion = surfaceInfo.position - surfaceInfo.prevPosition;
            }

            rayState.rayConeRadius = rayConeRadiusAtHit;
            float alpha = interfaceRoughness * interfaceRoughness;
            rayState.rayConeSpread = sqrt(
                rayState.rayConeSpread * rayState.rayConeSpread + alpha * alpha);
            rayState.hasRayCone = true;
            float3 outgoingDirection = isReflection ? reflDir : refrDir;
            float originSide = dot(outgoingDirection, surfaceInfo.normal) >= 0.0
                ? 1.0
                : -1.0;
            rayState.rayDesc.Origin =
                surfaceInfo.position + surfaceInfo.normal * originSide * 1.0e-4;
            rayState.rayDesc.Direction = outgoingDirection;
            rayState.rayDesc.TMin = 0.0;

            if (isReflection) {
                rayState.bounceCount++;
                if (rayState.bounceCount >= MAX_PATH_BOUNCES)
                    rayState.terminate = true;
            }
        } else {
            float3 ambient = 0.0;
            
            float3 sunlight = 0;
            float NdotL_main = dot(surfaceInfo.normal, mainLightDir);
            
            if (NdotL_main > 0.0) {
                float3 L = mainLightDir;
                float3 H = normalize(V + L);
                float NdotL = max(dot(surfaceInfo.normal, L), 0.0001);
                float NdotH = max(dot(surfaceInfo.normal, H), 0.0);
                float LdotH = max(dot(L, H), 0.0);
                
                float3 F = F_Schlick(max(dot(H, V), 0.0), F0);
                float D = D_GGX(NdotH, roughness);
                float G = G_Smith(NdotV, NdotL, roughness);
                float3 multipleScatter = FdezAgueraMultipleScattering(
                    NdotV, NdotL, roughness, F0);
                float3 specular = ((F * D * G) / (4.0 * NdotV * NdotL))
                    + multipleScatter;
                
                float3 kD = DiffuseEnergyWeight(F, multipleScatter);
                float3 diffuseBRDF = DisneyDiffuse(NdotL, NdotV, LdotH, roughness, diffuseColor);
                if (surfaceInfo.subsurface > 0.001) {
                    diffuseBRDF = lerp(diffuseBRDF, BurleyNormalizedSSS(NdotL, NdotV, LdotH, roughness, diffuseColor), surfaceInfo.subsurface);
                }
                diffuseBRDF *= kD;
                
                float3 sunRadiance; float sunLux;
                GetSunColorAndLux(surfaceInfo.position, sunDir, sunRadiance, sunLux);
                float3 moonRadiance; float moonLux;
                GetMoonColorAndLux(surfaceInfo.position, sunDir, moonDir, moonRadiance, moonLux);
                float3 mainRadiance = lerp(moonRadiance, sunRadiance, isSun);
                
                sunlight = mainRadiance * 0.75 * mainLightFade * (diffuseBRDF + specular) * NdotL * PI; 
            }
            
            float3 light = ambient + sunlight;
            float3 emission = surfaceInfo.alpha * light;
            
            if (surfaceInfo.emissive > 0.0)
                emission += surfaceInfo.color
                    * surfaceInfo.emissive
                    * PERF_TRANSLUCENT_EMISSIVE_SURFACE_INTENSITY;
                
            float exposure = rayState.globalExposure;
            emission *= exposure;
            
            rayState.color += emission * rayState.throughput;
            if (!rayState.foundPrimarySurface) {
                rayState.primaryEmission += emission * rayState.throughput;
                } else if (
                    rayState.primaryLobe == kPrimaryLobeSpecular)
                {
                    float3 reflectedEmission = ClampIndirectRadiance(
                        emission * rayState.throughput,
                        32.0);
                    if (ShouldDenoisePrimaryReflection(rayState))
                        rayState.specular += reflectedEmission;
                    else
                        rayState.primaryEmission += reflectedEmission;
                } else {
                    rayState.diffuseIrradiance +=
                        ClampIndirectRadiance(
                            emission * rayState.throughput,
                            24.0)
                        / max(rayState.primaryAlbedo, 0.001);
            }

            rayState.throughput *= GetThinSurfaceTransmittance(
                surfaceInfo.color, surfaceInfo.alpha);
            rayState.rayDesc.TMin = hitInfo.rayT + 0.001;
        }
        
        rayState.accumulatedDistance += hitInfo.rayT;
        return;
    }

    IrradianceCacheSample irradianceCacheSample =
        SampleIncomingIrradianceCache(hitInfo, objectInstance);
    float irradianceCacheBlend =
        irradianceCacheSample.confidence;

#if MCRTX_PRIMARY_GUIDE_ONLY
    if (!rayState.foundPrimarySurface) {
        StorePrimarySurfaceMetadata(
            rayState,
            surfaceInfo,
            surfaceInfo.color,
            diffuseColor,
            surfaceInfo.metalness,
            originalRoughness,
            kPrimaryMaterialOpaque);
        StorePrimarySurfaceDistanceAndMotion(
            rayState,
            hitInfo.rayT,
            surfaceInfo.position,
            surfaceInfo.prevPosition);

        float3 emission = 0.0;
        if (surfaceInfo.emissive > 0.0)
            emission = surfaceInfo.color
                * surfaceInfo.emissive
                * PERF_EMISSIVE_SURFACE_INTENSITY;
        if (objectInstance.flags & kObjectInstanceFlagGlint)
            emission += (sin(3.0 * g_view.time) * 0.5 + 0.5)
                * (float3(077, 23, 255) / 255.0);
        emission *= rayState.globalExposure;

        rayState.primaryEmission += emission * rayState.throughput;
        rayState.color += emission * rayState.throughput;
        rayState.primaryCachedIrradiance =
            irradianceCacheSample.irradiance * rayState.throughput;
        rayState.primaryIrradianceCacheConfidence = irradianceCacheBlend;
        rayState.diffuseIrradiance +=
            irradianceCacheSample.irradiance
            * rayState.throughput
            * (irradianceCacheBlend
                * PERF_IRRADIANCE_CACHE_PRIMARY_STRENGTH / PI);
        rayState.foundPrimarySurface = true;
    }

    rayState.accumulatedDistance += hitInfo.rayT;
    rayState.terminate = true;
    return;
#endif

    float3 directDiffuse = 0;
    float3 directSpecular = 0;
    float3 sunDiffuse = 0;
    float3 sunSpecular = 0;

    float NdotL_main = dot(surfaceInfo.normal, mainLightDir);
    if (NdotL_main > 0.0) {
        float3 shadowDirection = mainLightDir;
        float3 shadowTransmission = 0.0;
        if (dot(surfaceInfo.normal, shadowDirection) > 0.0) {
            RayDesc shadowRay;
            shadowRay.Origin =
                surfaceInfo.position + 1.0e-4 * surfaceInfo.normal;
            shadowRay.Direction = shadowDirection;
            shadowRay.TMin = 0.0;
            shadowRay.TMax = 10000.0;

            ShadowPayload payload;
            TraceShadowRay(shadowRay, payload);
            shadowTransmission = payload.transmission;
        }

        if (rayState.bounceCount == 0) {
            shadowTransmission = ResolveTemporalSunShadow(
                rayState.pixelCoord,
                surfaceInfo.position,
                surfaceInfo.prevPosition,
                surfaceInfo.normal,
                shadowTransmission);
        } else {
            shadowTransmission = ShapeSunShadowTransmission(
                shadowTransmission);
        }
        
        if (any(shadowTransmission > 0)) {
            float3 L = mainLightDir;
            float3 H = safeNormalize(V + L, surfaceInfo.normal);
            float NdotL = max(NdotL_main, 0.0001);
            float NdotH = max(dot(surfaceInfo.normal, H), 0.0);
            float LdotH = max(dot(L, H), 0.0);
            
            float3 F = F_Schlick(max(dot(H, V), 0.0), F0);
            float D = D_GGX(NdotH, roughness);
            float G = G_Smith(NdotV, NdotL, roughness);
            float3 multipleScatter = FdezAgueraMultipleScattering(
                NdotV, NdotL, roughness, F0);
            float3 specBRDF = ((F * D * G) / (4.0 * NdotV * NdotL))
                + multipleScatter;
            
            float3 kD = DiffuseEnergyWeight(F, multipleScatter);
            float3 diffuseBRDF = DisneyDiffuse(NdotL, NdotV, LdotH, roughness, diffuseColor);
            if (surfaceInfo.subsurface > 0.001) {
                diffuseBRDF = lerp(diffuseBRDF, BurleyNormalizedSSS(NdotL, NdotV, LdotH, roughness, diffuseColor), surfaceInfo.subsurface);
            }
            diffuseBRDF *= kD;
            
            float3 sunRadiance; float sunLux;
            GetSunColorAndLux(surfaceInfo.position, sunDir, sunRadiance, sunLux);
            float3 moonRadiance; float moonLux;
            GetMoonColorAndLux(surfaceInfo.position, sunDir, moonDir, moonRadiance, moonLux);
            float3 mainRadiance = lerp(moonRadiance, sunRadiance, isSun);
            
            float3 lightContrib =
                mainRadiance * 0.75 * mainLightFade
                * shadowTransmission * NdotL * PI;
            sunDiffuse += lightContrib * diffuseBRDF;
            sunSpecular += lightContrib * specBRDF;
        }
    } else if (rayState.bounceCount == 0) {
        outputBufferSunLightShadow[rayState.pixelCoord] = 0.0;
    }
    
    AccumulateShadowedPointLights(
        surfaceInfo.position,
        surfaceInfo.normal,
        V,
        F0,
        diffuseColor,
        roughness,
        surfaceInfo.subsurface,
        GetBlueNoise2D(rayState),
        directDiffuse,
        directSpecular);

    if (rainPuddleAmount > 0.001
        && rayState.bounceCount == 0
        && !rayState.foundPrimarySurface)
    {
        float3 puddleNormal =
            safeNormalize(
                lerp(
                    surfaceInfo.normal,
                    GetWaterNormal(
                        surfaceInfo.position,
                        g_view.time,
                        surfaceInfo.normal),
                    saturate(rainPuddleAmount * 0.65)),
                surfaceInfo.normal);
        float puddleNdotV = max(dot(puddleNormal, V), 0.0001);
        float puddleFresnel =
            F_Schlick(puddleNdotV, (0.02).xxx).x;
        float puddleReflectionWeight =
            rainPuddleAmount
            * max(
                puddleFresnel * WATER_FRESNEL_BOOST,
                PERF_WATER_MIN_REFLECTION_WEIGHT * 1.6)
            * WEATHER_RAIN_PUDDLE_REFLECTION_STRENGTH;
        float3 puddleReflection =
            TraceDielectricReflectionProbe(
                surfaceInfo.position,
                puddleNormal,
                reflect(-V, puddleNormal),
                PERF_WATER_REFLECTION_PROBE_DISTANCE,
                true)
            * puddleReflectionWeight;
        directSpecular += ClampIndirectRadiance(puddleReflection, 48.0);
    }

    float3 emission = 0;
    if (objectInstance.flags & (kObjectInstanceFlagSun | kObjectInstanceFlagMoon)) {
        emission = surfaceInfo.color * ((objectInstance.flags & kObjectInstanceFlagSun ? g_view.sunMeshIntensity : g_view.moonMeshIntensity) * surfaceInfo.alpha);
    } else {
        if (surfaceInfo.emissive > 0.0)
            emission = surfaceInfo.color
                * surfaceInfo.emissive
                * PERF_EMISSIVE_SURFACE_INTENSITY;
    }
    
    if (objectInstance.flags & kObjectInstanceFlagGlint)
        emission += (sin(3.0 * g_view.time) * 0.5 + 0.5) * (float3(077, 23, 255) / 255.0);

    float exposure = rayState.globalExposure;
    
    emission *= exposure;

    sunDiffuse *= exposure;
    sunSpecular *= exposure;
    
    if (!rayState.foundPrimarySurface) {
        StorePrimarySurfaceMetadata(
            rayState,
            surfaceInfo,
            surfaceInfo.color,
            diffuseColor,
            surfaceInfo.metalness,
            originalRoughness,
            kPrimaryMaterialFullTraced);
        StorePrimarySurfaceDistanceAndMotion(
            rayState,
            hitInfo.rayT,
            surfaceInfo.position,
            surfaceInfo.prevPosition);
        rayState.primaryAlbedo = diffuseColor;
        float3 primaryAlbedo = max(rayState.primaryAlbedo, 0.001);
        float3 primaryThroughput = rayState.throughput;

        rayState.primaryEmission += (
            emission
            + sunDiffuse
            + sunSpecular) * primaryThroughput;
        rayState.diffuseIrradiance +=
            directDiffuse * primaryThroughput / primaryAlbedo;
        rayState.specular +=
            directSpecular * primaryThroughput;

        rayState.primaryNormal = surfaceInfo.normal;
        
        rayState.primaryRoughness = max(originalRoughness, 0.02);
        rayState.primaryMetalness = surfaceInfo.metalness;
        rayState.primaryCachedIrradiance =
            irradianceCacheSample.irradiance
            * rayState.throughput;
        rayState.primaryIrradianceCacheConfidence =
            irradianceCacheBlend;
        rayState.diffuseIrradiance +=
            irradianceCacheSample.irradiance
            * rayState.throughput
            * (irradianceCacheBlend
                * PERF_IRRADIANCE_CACHE_PRIMARY_STRENGTH / PI);
        
        rayState.distance = rayState.accumulatedDistance + hitInfo.rayT;
        rayState.motion = surfaceInfo.position - surfaceInfo.prevPosition;
        rayState.foundPrimarySurface = true;
    } else {
        float3 primaryAlbedo = max(rayState.primaryAlbedo, 0.001);
        float3 cachedBounce = ClampIndirectRadiance(
            diffuseColor
                * irradianceCacheSample.irradiance
                * (irradianceCacheBlend
                    * PERF_IRRADIANCE_CACHE_BOUNCE_STRENGTH / PI)
                * rayState.throughput,
            rayState.primaryLobe == kPrimaryLobeSpecular
                ? 32.0
                : 24.0);
        float3 bounceRadiance =
            emission
            + sunDiffuse
            + sunSpecular
            + directDiffuse
            + directSpecular;

        float3 weightedBounce = ClampIndirectRadiance(
            bounceRadiance * rayState.throughput,
            rayState.primaryLobe == kPrimaryLobeSpecular
                ? 32.0
                : 24.0);

        if (rayState.primaryLobe == kPrimaryLobeSpecular) {
            if (ShouldDenoisePrimaryReflection(rayState))
                rayState.specular += weightedBounce + cachedBounce;
            else
                rayState.primaryEmission +=
                    weightedBounce + cachedBounce;
        } else {
            rayState.diffuseIrradiance +=
                (weightedBounce + cachedBounce) / primaryAlbedo;
        }

        rayState.color += cachedBounce;
    }
    
    rayState.color += (
        emission
        + sunDiffuse
        + sunSpecular
        + directDiffuse
        + directSpecular) * rayState.throughput;

    rayState.accumulatedDistance += hitInfo.rayT;

    float3 viewFresnel = F_Schlick(NdotV, F0);
    float specularImportance = max(
        getLuminance(viewFresnel), surfaceInfo.metalness);
    float diffuseImportance = getLuminance(diffuseColor)
        * (1.0 - saturate(specularImportance));
    float importanceSum = specularImportance + diffuseImportance;

    if (importanceSum <= 0.00001) {
        rayState.terminate = true;
        return;
    }

    bool hasDiffuseLobe = any(diffuseColor > 0.0001);
    float specularProbability = hasDiffuseLobe
        ? clamp(specularImportance / importanceSum, 0.1, 0.9)
        : 1.0;
    bool sampleSpecular = GetBlueNoise1D(rayState) < specularProbability;

    float3 nextDirection = surfaceInfo.normal;
    float3 pathWeight = (0.0).xxx;

    if (sampleSpecular) {
        nextDirection = SampleGGX(V, surfaceInfo.normal, roughness, GetBlueNoise2D(rayState));
        float NdotL = dot(surfaceInfo.normal, nextDirection);
        if (NdotL > 0.0) {
            float3 H = safeNormalize(V + nextDirection, surfaceInfo.normal);
            float NdotH = max(dot(surfaceInfo.normal, H), 0.0);
            float VdotH = max(dot(V, H), 0.0001);
            float3 F = F_Schlick(VdotH, F0);
            float D = D_GGX(NdotH, roughness);
            float G = G_Smith(NdotV, NdotL, roughness);
            float3 multipleScatter = FdezAgueraMultipleScattering(
                NdotV, NdotL, roughness, F0);
            float3 specularBRDF = (F * D * G)
                / max(4.0 * NdotV * NdotL, 0.0001);
            specularBRDF += multipleScatter;

            float pdf = PDF_GGX_Reflection(NdotV, NdotH, VdotH, roughness);
            if (pdf > 0.00001)
                pathWeight = specularBRDF * NdotL / (pdf * max(specularProbability, 0.0001));
        }
    } else {
        nextDirection = SampleCosineHemisphere(GetBlueNoise2D(rayState), surfaceInfo.normal);
        float NdotL = max(dot(surfaceInfo.normal, nextDirection), 0.0001);
        float3 H = safeNormalize(V + nextDirection, surfaceInfo.normal);
        float LdotH = max(dot(nextDirection, H), 0.0);
        float3 F = F_Schlick(max(dot(H, V), 0.0), F0);
        float3 multipleScatter = FdezAgueraMultipleScattering(
            NdotV, NdotL, roughness, F0);

        float3 diffuseBRDF = DisneyDiffuse(NdotL, NdotV, LdotH, roughness, diffuseColor);
        if (surfaceInfo.subsurface > 0.001) {
            diffuseBRDF = lerp(
                diffuseBRDF,
                BurleyNormalizedSSS(NdotL, NdotV, LdotH, roughness, diffuseColor),
                surfaceInfo.subsurface);
        }
        diffuseBRDF *= DiffuseEnergyWeight(F, multipleScatter);

        float diffuseProbability = 1.0 - specularProbability;
        float pdf = PDF_CosineHemisphere(NdotL);
        if (pdf > 0.00001)
            pathWeight = diffuseBRDF * NdotL / (pdf * max(diffuseProbability, 0.0001));

        pathWeight *=
            1.0 - irradianceCacheBlend
                * PERF_IRRADIANCE_CACHE_PATH_SUPPRESSION;
    }

    if (ContinueOpaquePath(
        rayState,
        surfaceInfo.position,
        surfaceInfo.normal,
        nextDirection,
        pathWeight,
        sampleSpecular,
        originalRoughness,
        rayConeRadiusAtHit))
    {
        return;
    }
}
