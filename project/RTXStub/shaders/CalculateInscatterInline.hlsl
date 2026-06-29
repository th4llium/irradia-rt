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
            / max(distanceSq + radiusSq, 1.0);
        float cosTheta = dot(viewDirection, lightDirection);
        float localPhase = lerp(
            1.0 / (4.0 * PI),
            HenyeyGreensteinPhase(cosTheta, 0.35),
            0.45);
        float3 lightRadiance =
            lightData.color
            * lightData.intensity
            * 700.0
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

    float zSlice = ((float)dispatchThreadID.z + 0.5) / 64.0;
    float maxDist = GetVolumetricFogMaxDistance();
    float depth = zSlice * zSlice * maxDist;

    float3 rayDir = rayDirFromNDC(ndc);
    float3 pos = g_view.viewOriginSteveSpace + rayDir * depth;

    bool isUnderwater = g_view.cameraIsUnderWater;
    float fogDensity = isUnderwater ? 0.025 : GetVolumetricFogDensity(false);

    float3 sunDir = getOffsetTrueDirectionToSun();
    float3 moonDir = getOffsetTrueDirectionToMoon();
    float sunFade = GetSunAmount(sunDir);
    float moonFade = GetMoonAmount(sunDir, moonDir);
    float isSun = step(moonFade, sunFade);
    float3 mainLightDir = lerp(moonDir, sunDir, isSun);
    float mainLightFade = lerp(moonFade, sunFade, isSun);

    uint3 noiseCoord = uint3(
        dispatchThreadID.xy % uint2(256, 256),
        g_view.frameCount % 128);
    float4 noise = blueNoiseTexture.Load(uint4(noiseCoord, 0));
    float dither = noise.x;

    float shadow = 1.0;
    float3 shadowLightDir = mainLightDir;
#if VOLUMETRIC_SHADOW_RAYS >= 1
    float3 jitteredDir = sampleCelestialLightDisk(mainLightDir, noise.xy);
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
        dither);

    float3 sunRadiance; float sunLux;
    GetSunColorAndLux(pos, sunDir, sunRadiance, sunLux);
    float3 moonRadiance; float moonLux;
    GetMoonColorAndLux(pos, sunDir, moonDir, moonRadiance, moonLux);
    float3 mainRadiance = lerp(moonRadiance, sunRadiance, isSun);

    float cosTheta = dot(rayDir, mainLightDir);
    float g = isUnderwater ? 0.6 : 0.75;
    float phase = (1.0 - g*g) / (4.0 * PI * pow(max(1.0 + g*g - 2.0*g*cosTheta, 0.001), 1.5));

    float3 scattering = 0.0;
    float extinction = 0.0;
    float3 localMediaScattering = 0.0;
    if (isUnderwater) {
        float3 waterScatteringColor = float3(0.1, 0.8, 0.9) * 0.025;
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
        float uniformPhase = 1.0 / (4.0 * PI);
        float fogExtinction =
            fogDensity
            * max(getLuminance(mediaExtinction), 1.0e-4);
        float3 directLight =
            mainRadiance
            * mainLightFade
            * shadow
            * phase;
        float3 ambientLight = fogColor * uniformPhase;
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
