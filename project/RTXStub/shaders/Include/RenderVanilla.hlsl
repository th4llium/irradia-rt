#include "IrradianceCache.hlsl"

#ifndef WATER_INTERFACE_ROUGHNESS
#define WATER_INTERFACE_ROUGHNESS 0.035
#endif

#ifndef WATER_FRESNEL_BOOST
#define WATER_FRESNEL_BOOST 1.25
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
    float3 sunDir = getOffsetTrueDirectionToSun();
    float3 moonDir = getOffsetTrueDirectionToMoon();
    float3 skyAmbient;
    float skyLux;
    GetSkyAmbientAndLux(
        surfaceInfo.position,
        surfaceInfo.normal,
        sunDir,
        moonDir,
        skyAmbient,
        skyLux);

    float skyFacing =
        saturate(0.28 + 0.72 * max(surfaceInfo.normal.y, 0.0));
    float3 ambientRadiance =
        diffuseColor
        * skyAmbient
        * skyFacing
        * PERF_DIELECTRIC_REFLECTION_AMBIENT_STRENGTH;

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
    float3 direction)
{
    RayDesc reflectionRay;
    reflectionRay.Origin =
        position
        + normal * (dot(direction, normal) >= 0.0 ? 1.0e-3 : -1.0e-3);
    reflectionRay.Direction = safeNormalize(direction, normal);
    reflectionRay.TMin = 0.0;
    reflectionRay.TMax = PERF_DIELECTRIC_REFLECTION_PROBE_DISTANCE;

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

    return GetCloudyTransparentEnvironmentSky(
        reflectionRay.Origin,
        direction,
        GetEnvironmentCloudDither(position, direction));
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

    float3 V = normalize(-rayState.rayDesc.Direction);
    float3 diffuseColor = surfaceInfo.color * (1.0 - surfaceInfo.metalness);
    float3 F0 = lerp((0.04).xxx, surfaceInfo.color, surfaceInfo.metalness);
    float originalRoughness = surfaceInfo.roughness;
    float roughness = max(originalRoughness, 0.035);
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
                        float3 skyAmbientRadiance; float skyLux;
                        GetSkyAmbientAndLux(
                            surfaceInfo.position,
                            surfaceInfo.normal,
                            sunDir,
                            moonDir,
                            skyAmbientRadiance,
                            skyLux);
                        float waterFacing = saturate(0.35 + 0.65 * surfaceInfo.normal.y);
                        float viewFresnel = F_Schlick(
                            max(dot(surfaceInfo.normal, V), 0.0),
                            dielectricF0Color).x;
                        skyAmbient = skyAmbientRadiance
                            * waterFacing
                            * lerp(0.28, 0.55, viewFresnel);
                    }

                    int glassLightCount = min(
                        PERF_GLASS_LOCAL_LIGHT_COUNT,
                        (int)g_view.cpuLightsCount);
                    [loop]
                    for (int lightIndex = 0; lightIndex < glassLightCount; lightIndex++) {
                        LightInfo lightInfo = inputLightsBuffer[lightIndex];
                        LightData lightData = UnpackLight(lightInfo.packedData);
                        float3 toLight = lightInfo.position - surfaceInfo.position;
                        float lightDistance = length(toLight);
                        float3 lightDirection = toLight / max(lightDistance, 0.001);
                        float NdotL = max(dot(surfaceInfo.normal, lightDirection), 0.0);
                        if (NdotL <= 0.0)
                            continue;

                        float3 H = safeNormalize(V + lightDirection, surfaceInfo.normal);
                        float NdotH = max(dot(surfaceInfo.normal, H), 0.0);
                        float3 F = F_Schlick(
                            max(dot(H, V), 0.0),
                            dielectricF0Color);
                        float D = D_GGX(
                            NdotH, dielectricRoughness);
                        float G = G_Smith(
                            NdotV,
                            NdotL,
                            dielectricRoughness);
                        float3 multipleScatter = FdezAgueraMultipleScattering(
                            NdotV,
                            NdotL,
                            dielectricRoughness,
                            dielectricF0Color);
                        float3 specularBRDF = ((F * D * G)
                            / max(4.0 * NdotV * NdotL, 0.001))
                            + multipleScatter;

                        RayDesc shadowRay;
                        shadowRay.Origin = surfaceInfo.position
                            + 1.0e-3 * surfaceInfo.normal;
                        shadowRay.Direction = lightDirection;
                        shadowRay.TMin = 0.0;
                        shadowRay.TMax = 10000.0;

                        shadowRay.TMax =
                            GetEmissiveLightShadowTMax(lightDistance);
                        ShadowPayload payload;
                        TraceShadowRay(shadowRay, payload);

                        float attenuation =
                            GetEmissiveLightAttenuation(lightDistance);
                        float3 lightContrib = payload.transmission * attenuation
                            * lightData.intensity * lightData.color
                            * NdotL * PI * 700.0;
                        localSpecular += lightContrib * specularBRDF;
                    }
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
                        reflDir)
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
            float3 skyAmbient; float skyLux;
            GetSkyAmbientAndLux(surfaceInfo.position, float3(0, 1, 0), sunDir, moonDir, skyAmbient, skyLux);
            float3 ambient = diffuseColor * skyAmbient * lerp(0.3, 1.0, surfaceInfo.normal.y * 0.5 + 0.5);
            
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

    float3 directDiffuse = 0;
    float3 directSpecular = 0;
    float3 sunDiffuse = 0;
    float3 sunSpecular = 0;

    float NdotL_main = dot(surfaceInfo.normal, mainLightDir);
    if (NdotL_main > 0.0) {
        float3 shadowDirection = sampleCelestialLightDisk(
            mainLightDir,
            GetBlueNoise2D(rayState));
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
            shadowTransmission *= GetVolumetricCloudShadowTransmission(
                shadowRay.Origin,
                shadowDirection,
                GetBlueNoise1D(rayState));
        }

        if (rayState.bounceCount == 0) {
            shadowTransmission = ResolveTemporalSunShadow(
                rayState.pixelCoord,
                surfaceInfo.position,
                surfaceInfo.prevPosition,
                surfaceInfo.normal,
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
    
    int localLightCap = rayState.bounceCount == 0
        ? PERF_PRIMARY_LOCAL_LIGHT_COUNT
        : PERF_SECONDARY_LOCAL_LIGHT_COUNT;
    int lightCount = min(localLightCap, (int)g_view.cpuLightsCount);
    [loop]
    for (int lightIndex = 0; lightIndex < lightCount; lightIndex++) {
        LightInfo lightInfo = inputLightsBuffer[lightIndex];
        LightData lightData = UnpackLight(lightInfo.packedData);

        float3 toLight = lightInfo.position - surfaceInfo.position;
        float lightDistance = length(toLight);
        float3 lightDirection = toLight / max(lightDistance, 0.001);
        float NdotL = max(dot(surfaceInfo.normal, lightDirection), 0.0);
        if (NdotL <= 0.0)
            continue;

        float attenuation = GetEmissiveLightAttenuation(lightDistance);
        float3 H = safeNormalize(V + lightDirection, surfaceInfo.normal);
        float NdotH = max(dot(surfaceInfo.normal, H), 0.0);
        float LdotH = max(dot(lightDirection, H), 0.0);

        float3 F = F_Schlick(max(dot(H, V), 0.0), F0);
        float D = D_GGX(NdotH, roughness);
        float G = G_Smith(NdotV, NdotL, roughness);
        float3 multipleScatter = FdezAgueraMultipleScattering(
            NdotV, NdotL, roughness, F0);
        float3 specBRDF = ((F * D * G)
            / (4.0 * max(NdotV * NdotL, 0.001))) + multipleScatter;

        float3 diffuseBRDF = DisneyDiffuse(
            NdotL, NdotV, LdotH, roughness, diffuseColor);
        if (surfaceInfo.subsurface > 0.001) {
            diffuseBRDF = lerp(
                diffuseBRDF,
                BurleyNormalizedSSS(
                    NdotL, NdotV, LdotH, roughness, diffuseColor),
                surfaceInfo.subsurface);
        }
        diffuseBRDF *= DiffuseEnergyWeight(F, multipleScatter);

        RayDesc shadowRay;
        shadowRay.Origin = surfaceInfo.position + 1.0e-3 * surfaceInfo.normal;
        shadowRay.Direction = lightDirection;
        shadowRay.TMin = 0.0;
        shadowRay.TMax = GetEmissiveLightShadowTMax(lightDistance);

        ShadowPayload payload;
        TraceShadowRay(shadowRay, payload);

        float3 lightContrib = payload.transmission * attenuation
            * lightData.intensity * lightData.color * NdotL * PI * 700.0;

        directDiffuse += lightContrib * diffuseBRDF;
        directSpecular += lightContrib * specBRDF;
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
    
    if (objectInstance.flags & (kObjectInstanceFlagSun | kObjectInstanceFlagMoon)) {
        emission *= exposure;
    } else {
        emission *= 0.1;
    }

    sunDiffuse *= exposure;
    sunSpecular *= exposure;
    
    if (!rayState.foundPrimarySurface) {
        rayState.primaryAlbedo = diffuseColor;
        rayState.primaryEmission += (
            emission
            + sunDiffuse
            + sunSpecular
            + directDiffuse
            + directSpecular) * rayState.throughput;

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
