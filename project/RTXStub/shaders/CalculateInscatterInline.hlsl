#include "Include/Renderer.hlsl"
#include "Include/Util.hlsl"

float3 EvaluateVolumetricLocalLights(
    float3 position,
    float3 viewDirection,
    float3 mediaScattering)
{
    float3 localScattering = 0.0;
    int lightCount = min(
        VOLUMETRIC_LOCAL_LIGHT_COUNT,
        (int)g_view.cpuLightsCount);
    float maxDistance = VOLUMETRIC_LOCAL_LIGHT_MAX_DISTANCE;
    float maxDistanceSq = maxDistance * maxDistance;
    float radiusSq =
        VOLUMETRIC_LOCAL_LIGHT_RADIUS
        * VOLUMETRIC_LOCAL_LIGHT_RADIUS;

    [loop]
    for (int lightIndex = 0; lightIndex < lightCount; ++lightIndex)
    {
        LightInfo lightInfo = inputLightsBuffer[lightIndex];
        LightData lightData = UnpackLight(lightInfo.packedData);
        float3 toLight = lightInfo.position - position;
        float distanceSq = dot(toLight, toLight);
        if (distanceSq >= maxDistanceSq)
            continue;

        float lightDistance = sqrt(max(distanceSq, 1.0e-4));
        float3 lightDirection = toLight / lightDistance;
        float rangeFade = saturate(1.0 - distanceSq / maxDistanceSq);
        rangeFade *= rangeFade;

        float visibility = 1.0;
#if VOLUMETRIC_LOCAL_LIGHT_SHADOW_COUNT > 0
        if (lightIndex < VOLUMETRIC_LOCAL_LIGHT_SHADOW_COUNT)
        {
            RayDesc shadowRay;
            shadowRay.Origin = position;
            shadowRay.Direction = lightDirection;
            shadowRay.TMin = 0.0;
            shadowRay.TMax = GetEmissiveLightShadowTMax(lightDistance);

            ShadowPayload payload;
            TraceShadowRay(shadowRay, payload);
            visibility = getLuminance(payload.transmission);
        }
#endif

        if (visibility <= 0.001)
            continue;

        float attenuation =
            rangeFade
            * (1.0 + radiusSq)
            / max(distanceSq + radiusSq, 0.001);
        float cosTheta = dot(viewDirection, lightDirection);
        float localPhase = lerp(
            1.0 / (4.0 * PI),
            HenyeyGreensteinPhase(cosTheta, 0.35),
            0.45);
        float3 lightRadiance =
            lightData.color
            * GetLocalLightIntensityWeight(lightData.intensity)
            * PERF_EMISSIVE_LIGHT_INTENSITY_SCALE
            * PERF_LOCAL_LIGHT_RADIANCE_SCALE
            * VOLUMETRIC_LOCAL_LIGHT_INTENSITY
            * attenuation
            * visibility;

        localScattering +=
            lightRadiance
            * localPhase
            * mediaScattering;
    }

    return localScattering;
}

float GetAirFogSampleWeight(
    float3 position,
    float sampleDepth,
    float maxDistance)
{
    float nearDistance = max(maxDistance * 0.04, 8.0);
    float fullDistance = max(maxDistance * 0.14, nearDistance + 1.0);
    float distanceProfile =
        lerp(
            0.38,
            1.0,
            smoothstep(nearDistance, fullDistance, sampleDepth));
    float heightProfile =
        lerp(
            1.08,
            0.72,
            smoothstep(96.0, 320.0, position.y));
    float farBoost =
        lerp(
            1.0,
            1.10,
            smoothstep(maxDistance * 0.65, maxDistance, sampleDepth));
    return distanceProfile * heightProfile * farBoost;
}

float GetAverageAirFogSampleWeight(
    float3 rayDirection,
    float zSliceMin,
    float zSliceMax,
    float maxDistance,
    float dither)
{
    float sampleCount = max((float)VOLUMETRIC_STEPS, 1.0);
    float weightSum = 0.0;

    [loop]
    for (int sampleIndex = 0; sampleIndex < VOLUMETRIC_STEPS; ++sampleIndex)
    {
        float sample01 = ((float)sampleIndex + dither) / sampleCount;
        float sampleZ = lerp(zSliceMin, zSliceMax, sample01);
        float sampleDepth = sampleZ * sampleZ * maxDistance;
        float3 samplePosition =
            g_view.viewOriginSteveSpace + rayDirection * sampleDepth;
        weightSum += GetAirFogSampleWeight(
            samplePosition,
            sampleDepth,
            maxDistance);
    }

    return weightSum / sampleCount;
}

[numthreads(4, 4, 2)]
void CalculateInscatterInline(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    if (any(dispatchThreadID >= uint3(256, 128, 64))) return;

    float2 ndc = ((float2)dispatchThreadID.xy + 0.5) / float2(256.0, 128.0);
    ndc = ndc * 2.0 - 1.0;
    ndc.y = -ndc.y;

    float zSliceMin = (float)dispatchThreadID.z / 64.0;
    float zSliceMax = ((float)dispatchThreadID.z + 1.0) / 64.0;
    float zSlice = (zSliceMin + zSliceMax) * 0.5;
    float maxDist = GetVolumetricFogMaxDistance();
    float depth = zSlice * zSlice * maxDist;

    float3 rayDir = rayDirFromNDC(ndc);
    float3 pos = g_view.viewOriginSteveSpace + rayDir * depth;

    bool isUnderwater = g_view.cameraIsUnderWater;
    float fogDensity = isUnderwater
        ? GetWaterScalarExtinction()
        : GetVolumetricFogDensity(false);

    float3 sunDir = getOffsetTrueDirectionToSun();
    float3 moonDir = getOffsetTrueDirectionToMoon();
    float sunFade = GetSunAmount(sunDir);
    float moonFade = GetMoonAmount(sunDir, moonDir);
    float isSun = step(moonFade, sunFade);
    float3 mainLightDir = lerp(moonDir, sunDir, isSun);
    float mainLightFade = lerp(moonFade, sunFade, isSun);

    uint3 noiseCoord = uint3(
        dispatchThreadID.xy % uint2(256, 256),
        dispatchThreadID.z % 128);
    float4 noise = blueNoiseTexture.Load(uint4(noiseCoord, 0));
    float dither = noise.x;
    float airFogSampleWeight = isUnderwater
        ? 1.0
        : GetAverageAirFogSampleWeight(
            rayDir,
            zSliceMin,
            zSliceMax,
            maxDist,
            dither);

    float shadow = 1.0;
    float3 shadowLightDir = mainLightDir;
#if VOLUMETRIC_SHADOW_RAYS >= 1
    float3 jitteredDir = mainLightDir;
    shadowLightDir = jitteredDir;

    RayDesc shadowRay;
    shadowRay.Origin = pos;
    shadowRay.Direction = jitteredDir;
    shadowRay.TMin = 0.0;
    shadowRay.TMax = 10000.0;
    ShadowPayload payload;
    TraceShadowRay(shadowRay, payload);
    shadow = payload.transmission.x;
#endif
    shadow *= GetVolumetricCloudShadowTransmission(
        pos,
        shadowLightDir,
        0.5);

    float3 sunRadiance; float sunLux;
    GetSunColorAndLux(pos, sunDir, sunRadiance, sunLux);
    float3 moonRadiance; float moonLux;
    GetMoonColorAndLux(pos, sunDir, moonDir, moonRadiance, moonLux);
    float3 mainRadiance = lerp(moonRadiance, sunRadiance, isSun);

    float cosTheta = dot(rayDir, mainLightDir);
    float uniformPhase = 1.0 / (4.0 * PI);
    float g = isUnderwater ? 0.6 : 0.52;
    float hgPhase = (1.0 - g*g) / (4.0 * PI * pow(max(1.0 + g*g - 2.0*g*cosTheta, 0.001), 1.5));
    float phase = isUnderwater
        ? hgPhase
        : lerp(uniformPhase, hgPhase, 0.58);

    float3 scattering = 0.0;
    float extinction = 0.0;
    float3 localMediaScattering = 0.0;
    if (isUnderwater) {
        float3 waterScatteringColor = GetWaterScatteringCoefficient();
        float waterExtinction = fogDensity;
        scattering =
            mainRadiance
            * mainLightFade
            * shadow
            * phase
            * waterScatteringColor
            * waterExtinction;
        scattering +=
            float3(0.01, 0.05, 0.08)
            * waterScatteringColor
            * 0.5
            * waterExtinction;
        extinction += waterExtinction;
        localMediaScattering =
            waterScatteringColor * waterExtinction;
    } else {
        float3 mediaExtinction = GetVolumetricFogMediaExtinction(false);
        float3 fogColor = GetFogColor(pos, rayDir, depth, sunDir, moonDir);
        float fogExtinction =
            fogDensity
            * getLuminance(mediaExtinction)
            * airFogSampleWeight;
        float3 directLight =
            mainRadiance
            * mainLightFade
            * shadow
            * phase
            * 0.62;
        float3 ambientLight = fogColor * uniformPhase * 1.55;
        scattering = (directLight + ambientLight) * fogExtinction;
        extinction += fogExtinction;
        localMediaScattering = fogExtinction.xxx;
    }

    scattering += EvaluateVolumetricLocalLights(
        pos,
        rayDir,
        localMediaScattering);

    float exposure = GetAutoExposureMultiplier(g_view.viewOriginSteveSpace, sunDir, moonDir);
    scattering *= exposure;

    volumetricInscatterRW[dispatchThreadID] = float4(scattering, extinction);
}
