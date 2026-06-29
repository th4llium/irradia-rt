#ifndef __VOLUMETRIC_CLOUDS_HLSL__
#define __VOLUMETRIC_CLOUDS_HLSL__

#include "Sky.hlsl"

#ifndef ENABLE_VOLUMETRIC_CLOUDS
#define ENABLE_VOLUMETRIC_CLOUDS 1
#endif

#ifndef VOLUMETRIC_CLOUD_LIGHT_STEPS
#define VOLUMETRIC_CLOUD_LIGHT_STEPS 4
#endif

#ifndef VOLUMETRIC_CLOUD_STEPS
#define VOLUMETRIC_CLOUD_STEPS 32
#endif

#ifndef VOLUMETRIC_CLOUD_SHADOW_STEPS
#define VOLUMETRIC_CLOUD_SHADOW_STEPS 5
#endif

#ifndef VOLUMETRIC_CLOUD_BASE_HEIGHT
#define VOLUMETRIC_CLOUD_BASE_HEIGHT 200.0
#endif

#ifndef VOLUMETRIC_CLOUD_THICKNESS
#define VOLUMETRIC_CLOUD_THICKNESS 160.0
#endif

#ifndef VOLUMETRIC_CLOUD_COVERAGE
#define VOLUMETRIC_CLOUD_COVERAGE 0.48
#endif

#ifndef VOLUMETRIC_CLOUD_DENSITY
#define VOLUMETRIC_CLOUD_DENSITY 1.625
#endif

#ifndef VOLUMETRIC_CLOUD_EROSION
#define VOLUMETRIC_CLOUD_EROSION 0.3
#endif

#ifndef VOLUMETRIC_CLOUD_SPEED
#define VOLUMETRIC_CLOUD_SPEED 0.25
#endif

#ifndef VOLUMETRIC_CLOUD_EXTINCTION
#define VOLUMETRIC_CLOUD_EXTINCTION 1.0
#endif

#ifndef VOLUMETRIC_CLOUD_SCATTERING_ALBEDO
#define VOLUMETRIC_CLOUD_SCATTERING_ALBEDO 0.92
#endif

#ifndef VOLUMETRIC_CLOUD_SUN_INTENSITY
#define VOLUMETRIC_CLOUD_SUN_INTENSITY 10.0
#endif

#ifndef VOLUMETRIC_CLOUD_MOON_INTENSITY
#define VOLUMETRIC_CLOUD_MOON_INTENSITY 0.42
#endif

#ifndef VOLUMETRIC_CLOUD_MAX_RENDER_DISTANCE
#define VOLUMETRIC_CLOUD_MAX_RENDER_DISTANCE 7000.0
#endif

#ifndef VOLUMETRIC_CLOUD_FADE_DISTANCE
#define VOLUMETRIC_CLOUD_FADE_DISTANCE 5000.0
#endif

#ifndef VOLUMETRIC_CLOUD_TERRAIN_SHADOW_STRENGTH
#define VOLUMETRIC_CLOUD_TERRAIN_SHADOW_STRENGTH 0.85
#endif

#ifndef VOLUMETRIC_CLOUD_MAX_SHADOW_DISTANCE
#define VOLUMETRIC_CLOUD_MAX_SHADOW_DISTANCE 6000.0
#endif

#ifndef VOLUMETRIC_CLOUD_SHADOW_OD_CUTOFF
#define VOLUMETRIC_CLOUD_SHADOW_OD_CUTOFF 80.0
#endif

static const float VOLUMETRIC_CLOUD_EARTH_RADIUS = 6371000.0;
static const float3 VOLUMETRIC_CLOUD_MOON_LIGHT_COLOR =
    float3(0.060, 0.075, 0.110);
static const float VOLUMETRIC_CLOUD_TOP_HEIGHT =
    VOLUMETRIC_CLOUD_BASE_HEIGHT + VOLUMETRIC_CLOUD_THICKNESS;
static const float VOLUMETRIC_CLOUD_RPI = 1.0 / PI;

struct VolumetricCloudSample
{
    float3 scattering;
    float extinction;
};

float CloudRemap01(float x, float a, float b)
{
    return saturate((x - a) / max(b - a, 1.0e-5));
}

float3 CloudAbsEpsilon(float3 x)
{
    return abs(x) + 1.0e-3;
}

float CloudNoise2D(float2 x)
{
    float2 p = x * 0.128;
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = Hash21(i);
    float b = Hash21(i + float2(1.0, 0.0));
    float c = Hash21(i + float2(0.0, 1.0));
    float d = Hash21(i + float2(1.0, 1.0));

    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

float CloudShape(float coverageNoise, float height01)
{
    const float2 shapeParams = float2(0.4, 0.6);
    float anvil = 1.0 - sq(abs(height01 - 0.5) * 2.0);
    float verticalFalloff = pow(height01, 1.0 / (1.0 - shapeParams.y));
    return saturate(
        coverageNoise
        - anvil * (shapeParams.x * shapeParams.y)
        - verticalFalloff);
}

float GetVolumetricCloudHeight01(float y)
{
    return saturate(
        (y - VOLUMETRIC_CLOUD_BASE_HEIGHT)
        / VOLUMETRIC_CLOUD_THICKNESS);
}

float2 IntersectCloudSphere(
    float3 position,
    float3 direction,
    float radius)
{
    float originDotDirection = dot(position, direction);
    float radiusSquared = radius * radius;
    float discriminant =
        originDotDirection * originDotDirection
        + radiusSquared
        - dot(position, position);

    if (discriminant < 0.0)
        return float2(-1.0, -1.0);

    discriminant = sqrt(discriminant);
    return -originDotDirection + float2(-discriminant, discriminant);
}

float GetVolumetricCloudCurvedHeight(float3 position)
{
    return length(position + float3(0.0, VOLUMETRIC_CLOUD_EARTH_RADIUS, 0.0))
        - VOLUMETRIC_CLOUD_EARTH_RADIUS;
}

float GetCloudParticleThickness(float depth)
{
    return 100000.0 / max(depth * 2.0 - 0.01, 0.01);
}

float3 EvaluateCloudAtmosphericScattering(
    float3 viewDirection,
    float3 sunDirection,
    out float3 absorbLight,
    out float3 skyColorNoSun)
{
    float directAmount = GetSunAmount(sunDirection);
    float skyAmount = GetDaySkyAmount(sunDirection);

    if (skyAmount <= 0.00001) {
        absorbLight = 0.0;
        skyColorNoSun = 0.0;
        return 0.0;
    }

    float3 atmosphereLightDirection = AtmosphereSunDir(sunDirection);
    const float ln2 = 0.6931471805599453;

    float lDotW = dot(atmosphereLightDirection, viewDirection);
    float lDotU = dot(atmosphereLightDirection, float3(0.0, 1.0, 0.0));
    float uDotW = dot(float3(0.0, 1.0, 0.0), viewDirection);

    float opticalDepth = CalcParticleThickness(uDotW);
    float opticalDepthLight = CalcParticleThickness(lDotU);

    float3 scatterView = Scatter(totalCoeff, opticalDepth);
    float3 absorbView = Absorb(totalCoeff, opticalDepth);
    float3 scatterLight = Scatter(totalCoeff, opticalDepthLight);
    float3 rawAbsorbLight = Absorb(totalCoeff, opticalDepthLight);

    absorbLight = rawAbsorbLight * directAmount;

    float3 absorbSun =
        abs(rawAbsorbLight - absorbView)
        / D0((scatterLight - scatterView) * ln2);

    float3 mieScatter =
        Scatter(mieCoeff, opticalDepth)
        * MiePhaseSky(lDotW, opticalDepth);
    float3 rayleighScatter =
        Scatter(rayleighCoeff, opticalDepth)
        * RayleighPhase(lDotW);

    skyColorNoSun =
        (mieScatter + rayleighScatter)
        * absorbSun
        * sunBrightness
        * skyAmount;

    float3 sunSpot =
        smoothstep(0.9999, 0.99993, lDotW)
        * absorbView
        * sunBrightness;

    return skyColorNoSun + sunSpot * sunBrightness * directAmount;
}

float3 EvaluateCloudTopScattering(float3 sunDirection)
{
    float skyAmount = GetDaySkyAmount(sunDirection);
    if (skyAmount <= 0.00001)
        return 0.0;

    float3 atmosphereLightDirection = AtmosphereSunDir(sunDirection);
    const float ln2 = 0.6931471805599453;
    float lDotU = dot(atmosphereLightDirection, float3(0.0, 1.0, 0.0));

    float opticalDepth = GetCloudParticleThickness(1.0);
    float opticalDepthLight = CalcParticleThickness(lDotU);

    float3 scatterView = Scatter(totalCoeff, opticalDepth);
    float3 absorbView = Absorb(totalCoeff, opticalDepth);
    float3 scatterLight = Scatter(totalCoeff, opticalDepthLight);
    float3 absorbLight = Absorb(totalCoeff, opticalDepthLight);

    float3 absorbSun =
        CloudAbsEpsilon(absorbLight - absorbView)
        / CloudAbsEpsilon((scatterLight - scatterView) * ln2);
    float3 mieScatter = Scatter(mieCoeff, opticalDepth) * 0.25;
    float3 rayleighScatter = Scatter(rayleighCoeff, opticalDepth) * 0.375;

    return (mieScatter + rayleighScatter)
        * absorbSun
        * sunBrightness
        * skyAmount;
}

float GetVolumetricCloudDensity(float3 position)
{
#if ENABLE_VOLUMETRIC_CLOUDS
    float cloudHeight = GetVolumetricCloudCurvedHeight(position);
    if (cloudHeight < VOLUMETRIC_CLOUD_BASE_HEIGHT
        || cloudHeight > VOLUMETRIC_CLOUD_TOP_HEIGHT)
    {
        return 0.0;
    }

    float height01 = GetVolumetricCloudHeight01(cloudHeight);
    float time = g_view.time * VOLUMETRIC_CLOUD_SPEED * 15.0;
    const float scale = 0.1;

    float twist = cloudHeight * 0.0003;
    float2 spiralWarp = float2(sin(twist), cos(twist)) * 8.0;
    float2 baseOffset = float2(4.0, 8.0);

    float baseNoise = CloudNoise2D(
        (position.xz + spiralWarp) * scale
        + baseOffset
        + float2(-0.2, 0.3) * time);
    float density = CloudShape(
        baseNoise - 1.0 + VOLUMETRIC_CLOUD_COVERAGE * 2.0,
        height01);

    if (density <= 0.0)
        return 0.0;

    float2 detailWarp = float2(cos(twist * 2.5), sin(twist * 2.5)) * 4.0;
    float detailA = CloudNoise2D(
        (position.xz - detailWarp) * scale * 8.0
        - float2(0.2, 0.0) * time);
    float detailB = CloudNoise2D(
        (position.xz + detailWarp) * scale * 40.0
        + float2(1.0, 0.0) * time);

    density = CloudRemap01(
        density,
        (1.0 - detailA) * VOLUMETRIC_CLOUD_EROSION,
        1.0);
    density = CloudRemap01(
        density,
        (1.0 - detailB) * (VOLUMETRIC_CLOUD_EROSION * 0.33),
        1.0);
    density *= smoothstep(0.0, 0.75, height01);

    return sq(density) * VOLUMETRIC_CLOUD_DENSITY;
#else
    return 0.0;
#endif
}

bool GetVolumetricCloudLayerInterval(
    float3 origin,
    float3 direction,
    out float startDist,
    out float endDist)
{
    startDist = 0.0;
    endDist = 0.0;

    float3 relativeOrigin =
        origin + float3(0.0, VOLUMETRIC_CLOUD_EARTH_RADIUS, 0.0);
    float2 outerIntersection = IntersectCloudSphere(
        relativeOrigin,
        direction,
        VOLUMETRIC_CLOUD_EARTH_RADIUS + VOLUMETRIC_CLOUD_TOP_HEIGHT);
    float2 innerIntersection = IntersectCloudSphere(
        relativeOrigin,
        direction,
        VOLUMETRIC_CLOUD_EARTH_RADIUS + VOLUMETRIC_CLOUD_BASE_HEIGHT);

    if (outerIntersection.y < 0.0)
        return false;

    float cameraRadius = length(relativeOrigin);
    if (cameraRadius > VOLUMETRIC_CLOUD_EARTH_RADIUS + VOLUMETRIC_CLOUD_TOP_HEIGHT) {
        startDist = outerIntersection.x;
        endDist =
            innerIntersection.x > 0.0
                ? innerIntersection.x
                : outerIntersection.y;
    } else if (cameraRadius < VOLUMETRIC_CLOUD_EARTH_RADIUS + VOLUMETRIC_CLOUD_BASE_HEIGHT) {
        startDist = innerIntersection.y;
        endDist = outerIntersection.y;
    } else {
        startDist = 0.0;
        endDist =
            innerIntersection.x > 0.0
                ? innerIntersection.x
                : outerIntersection.y;
    }

    startDist = max(startDist, 0.0);
    return endDist > startDist;
}

float GetVolumetricCloudOpticalDepth(
    float3 origin,
    float3 direction,
    int stepCount,
    float dither)
{
#if ENABLE_VOLUMETRIC_CLOUDS
    float startDist;
    float endDist;
    if (!GetVolumetricCloudLayerInterval(
        origin,
        direction,
        startDist,
        endDist))
    {
        return 0.0;
    }

    float marchDistance = min(
        endDist - startDist,
        VOLUMETRIC_CLOUD_MAX_SHADOW_DISTANCE);
    if (marchDistance <= 0.0)
        return 0.0;

    int clampedStepCount = max(stepCount, 1);
    float stepLength = marchDistance / (float)clampedStepCount;
    float densitySum = 0.0;
    float densitySumCutoff =
        VOLUMETRIC_CLOUD_SHADOW_OD_CUTOFF
        / max(stepLength * VOLUMETRIC_CLOUD_EXTINCTION, 1.0e-4);

    [loop]
    for (int i = 0; i < clampedStepCount; ++i) {
        float rayT = startDist + ((float)i + dither) * stepLength;
        float3 samplePosition = origin + direction * rayT;
        densitySum += GetVolumetricCloudDensity(samplePosition);
        if (densitySum >= densitySumCutoff)
            return VOLUMETRIC_CLOUD_SHADOW_OD_CUTOFF;
    }

    return min(
        densitySum * stepLength * VOLUMETRIC_CLOUD_EXTINCTION,
        VOLUMETRIC_CLOUD_SHADOW_OD_CUTOFF);
#else
    return 0.0;
#endif
}

float GetVolumetricCloudShadowTransmission(
    float3 origin,
    float3 lightDirection,
    float dither)
{
#if ENABLE_VOLUMETRIC_CLOUDS
    if (GetLightAboveHorizonAmount(lightDirection) <= 0.0001)
        return 1.0;

    float opticalDepth = GetVolumetricCloudOpticalDepth(
        origin,
        lightDirection,
        VOLUMETRIC_CLOUD_SHADOW_STEPS,
        dither);
    return exp(
        -opticalDepth * VOLUMETRIC_CLOUD_TERRAIN_SHADOW_STRENGTH);
#else
    return 1.0;
#endif
}

float CloudPowderEffect(float density, float cosTheta)
{
    float powder =
        PI * density / (max(density, 0.0001) + 0.15);
    powder = lerp(powder, 1.0, 0.8 * sq(cosTheta * 0.5 + 0.5));
    return powder;
}

float CloudHgPhase(float cosTheta, float g)
{
    float g2 = g * g;
    return 0.25
        * ((1.0 - g2)
        * pow(max(1.0 + g2 - 2.0 * g * cosTheta, 0.001), -1.5));
}

float CloudPhaseSingle(float cosTheta)
{
    float forwardA = CloudHgPhase(cosTheta, 0.96);
    float forwardB = CloudHgPhase(cosTheta, 0.8);
    float back = CloudHgPhase(cosTheta, -0.2);
    return 0.8 * max(forwardA, forwardB) + 0.2 * back;
}

float CloudPhaseMulti(float cosTheta, float3 g)
{
    return 0.65 * CloudHgPhase(cosTheta, g.x)
        + 0.10 * CloudHgPhase(cosTheta, g.y)
        + 0.25 * CloudHgPhase(cosTheta, -g.z);
}

float3 GetDirectVolumetricCloudScattering(
    float density,
    float lightOpticalDepth,
    float skyOpticalDepth,
    float groundOpticalDepth,
    float stepTransmittance,
    float cosTheta,
    float3 lightDirection,
    float3 lightColor,
    float3 skyLight,
    float lightIntensity)
{
    float2 scatteringResult = 0.0;
    float scatterAmount = 0.8;
    float extinctAmount = 0.9;
    float shadowParam = 0.5;

    float scatteringIntegralTimesDensity =
        (1.0 - stepTransmittance) / extinctAmount;
    float normalizedDensity =
        density / max(VOLUMETRIC_CLOUD_DENSITY, 0.0001);
    float powderEffect =
        CloudPowderEffect(normalizedDensity, cosTheta);
    float scatteringFalloff =
        0.55
        * lerp(
            pow(saturate(scatterAmount / 0.1), 0.33),
            1.0,
            cosTheta * 0.5 + 0.5);

    float phase = CloudPhaseSingle(cosTheta);
    float phasePower = 1.0 + lightOpticalDepth;
    float3 phaseG =
        pow(float3(0.6, 0.9, 0.3), float3(phasePower, phasePower, phasePower));
    float isotropicPhase = 0.079577;
    float bouncedLight =
        0.4 * max(lightDirection.y, 0.0) * VOLUMETRIC_CLOUD_RPI;

    [unroll]
    for (int scatterIndex = 0; scatterIndex < 4; ++scatterIndex) {
        scatteringResult.x +=
            scatterAmount
            * exp(-extinctAmount * lightOpticalDepth)
            * phase
            * (1.0 - 0.5 * shadowParam);
        scatteringResult.x +=
            scatterAmount
            * exp(-extinctAmount * groundOpticalDepth)
            * isotropicPhase
            * bouncedLight;
        scatteringResult.x +=
            scatterAmount
            * exp(-extinctAmount * skyOpticalDepth)
            * isotropicPhase
            * shadowParam
            * 0.5;
        scatteringResult.y +=
            scatterAmount
            * exp(-extinctAmount * skyOpticalDepth)
            * isotropicPhase;

        scatterAmount *= scatteringFalloff * powderEffect;
        extinctAmount *= 0.4;
        phaseG *= 0.8;
        powderEffect = lerp(powderEffect, sqrt(powderEffect), 0.5);
        phase = CloudPhaseMulti(cosTheta, phaseG);
    }

    float2 totalScattering =
        scatteringResult * scatteringIntegralTimesDensity;
    return totalScattering.x
            * lightColor
            * sunBrightness
            * lightIntensity
        + totalScattering.y
            * skyLight
            * VOLUMETRIC_CLOUD_RPI;
}

float3 GetCloudSingleLightScattering(
    float3 position,
    float density,
    float3 viewDirection,
    float3 lightDirection,
    float3 lightRadiance,
    float lightAmount,
    float lightIntensity,
    float dither)
{
    if (lightAmount <= 0.0001
        || GetLightAboveHorizonAmount(lightDirection) <= 0.0001)
    {
        return 0.0;
    }

    float cosTheta = dot(viewDirection, lightDirection);
    float opticalDepth = GetVolumetricCloudOpticalDepth(
        position,
        lightDirection,
        VOLUMETRIC_CLOUD_LIGHT_STEPS,
        dither);
    float lightTransmittance = exp(-opticalDepth);
    float normalizedDensity =
        saturate(density / max(VOLUMETRIC_CLOUD_DENSITY, 0.0001));
    float powder = CloudPowderEffect(normalizedDensity, cosTheta);
    float phase = CloudPhaseSingle(cosTheta);

    return lightRadiance
        * lightAmount
        * lightIntensity
        * lightTransmittance
        * powder
        * phase;
}

void ComputeDirectVolumetricClouds(
    float3 origin,
    float3 viewDirection,
    float hitDistance,
    float dither,
    out float outTransmittance,
    out float3 outInscatter)
{
    outTransmittance = 1.0;
    outInscatter = 0.0;

#if ENABLE_VOLUMETRIC_CLOUDS
    float startDist;
    float endDist;
    if (!GetVolumetricCloudLayerInterval(
        origin,
        viewDirection,
        startDist,
        endDist))
    {
        return;
    }

    float clippedEndDist = min(
        min(endDist, hitDistance),
        VOLUMETRIC_CLOUD_MAX_RENDER_DISTANCE);
    if (startDist >= clippedEndDist
        || startDist >= VOLUMETRIC_CLOUD_MAX_RENDER_DISTANCE)
    {
        return;
    }

    float marchDistance = clippedEndDist - startDist;
    float stepLength = marchDistance / (float)VOLUMETRIC_CLOUD_STEPS;
    float3 stepVector = viewDirection * stepLength;
    float3 cloudPosition =
        origin + viewDirection * startDist + stepVector * dither;

    float3 sunDirection = getOffsetTrueDirectionToSun();
    float3 moonDirection = getOffsetTrueDirectionToMoon();
    float sunAmount = GetSunAmount(sunDirection);
    float moonAmount = GetMoonAmount(sunDirection, moonDirection);

    float3 sunAbsorbLight;
    float3 skyColorNoSun;
    EvaluateCloudAtmosphericScattering(
        viewDirection,
        sunDirection,
        sunAbsorbLight,
        skyColorNoSun);
    float3 skyLightTop =
        EvaluateCloudTopScattering(sunDirection);

    float sunCosTheta = dot(sunDirection, viewDirection);
    float moonCosTheta = dot(moonDirection, viewDirection);
    float transmittance = 1.0;
    float3 scatteringSum = 0.0;

    [loop]
    for (int stepIndex = 0;
        stepIndex < VOLUMETRIC_CLOUD_STEPS;
        ++stepIndex, cloudPosition += stepVector)
    {
        if (transmittance < 0.01)
            break;

        float currentDist = startDist
            + ((float)stepIndex + dither) * stepLength;
        float distanceFade = smoothstep(
            VOLUMETRIC_CLOUD_MAX_RENDER_DISTANCE,
            VOLUMETRIC_CLOUD_MAX_RENDER_DISTANCE
                - VOLUMETRIC_CLOUD_FADE_DISTANCE,
            currentDist);

        float density =
            GetVolumetricCloudDensity(cloudPosition) * distanceFade;
        float opticalDepth =
            density * stepLength * VOLUMETRIC_CLOUD_EXTINCTION;
        if (opticalDepth <= 1.0e-6)
            continue;

        float stepTransmittance = exp(-opticalDepth);
        float cloudHeight =
            GetVolumetricCloudCurvedHeight(cloudPosition);
        float skyOpticalDepth =
            density
            * max(VOLUMETRIC_CLOUD_TOP_HEIGHT - cloudHeight, 0.0)
            * 0.5;
        float groundOpticalDepth =
            density
            * max(cloudHeight - VOLUMETRIC_CLOUD_BASE_HEIGHT, 0.0)
            * 0.5;

        float3 stepScattering = 0.0;
        if (sunAmount > 0.001) {
            float lightOpticalDepth = GetVolumetricCloudOpticalDepth(
                cloudPosition,
                sunDirection,
                VOLUMETRIC_CLOUD_LIGHT_STEPS,
                dither);
            stepScattering += GetDirectVolumetricCloudScattering(
                density,
                lightOpticalDepth,
                skyOpticalDepth,
                groundOpticalDepth,
                stepTransmittance,
                sunCosTheta,
                sunDirection,
                sunAbsorbLight,
                skyLightTop,
                VOLUMETRIC_CLOUD_SUN_INTENSITY * sunAmount);
        }

        if (moonAmount > 0.001) {
            float lightOpticalDepth = GetVolumetricCloudOpticalDepth(
                cloudPosition,
                moonDirection,
                VOLUMETRIC_CLOUD_LIGHT_STEPS,
                dither);
            stepScattering += GetDirectVolumetricCloudScattering(
                density,
                lightOpticalDepth,
                skyOpticalDepth,
                groundOpticalDepth,
                stepTransmittance,
                moonCosTheta,
                moonDirection,
                VOLUMETRIC_CLOUD_MOON_LIGHT_COLOR,
                float3(0.0, 0.0, 0.0),
                VOLUMETRIC_CLOUD_MOON_INTENSITY * moonAmount);
        }

        scatteringSum += stepScattering * transmittance;
        transmittance *= stepTransmittance;
    }

    float farBlend =
        saturate(startDist * 0.00001);
    float3 skyFallback = skyColorNoSun * (1.0 - transmittance);

    outTransmittance = transmittance;
    outInscatter =
        lerp(scatteringSum, skyFallback, farBlend)
        * SKY_OUTPUT_SCALE;
#endif
}

VolumetricCloudSample EvaluateVolumetricCloudFroxel(
    float3 position,
    float3 viewDirection,
    float3 sunDirection,
    float3 moonDirection,
    float3 sunRadiance,
    float sunAmount,
    float3 moonRadiance,
    float moonAmount,
    float3 skyAmbientRadiance,
    float dither)
{
    VolumetricCloudSample result;
    result.scattering = 0.0;
    result.extinction = 0.0;

#if ENABLE_VOLUMETRIC_CLOUDS
    float density = GetVolumetricCloudDensity(position);
    if (density <= 0.00001)
        return result;

    float extinction = density * VOLUMETRIC_CLOUD_EXTINCTION;
    float scattering = extinction * VOLUMETRIC_CLOUD_SCATTERING_ALBEDO;

    float3 sourceRadiance = 0.0;
    sourceRadiance += GetCloudSingleLightScattering(
        position,
        density,
        viewDirection,
        sunDirection,
        sunRadiance,
        sunAmount,
        VOLUMETRIC_CLOUD_SUN_INTENSITY,
        dither);
    sourceRadiance += GetCloudSingleLightScattering(
        position,
        density,
        viewDirection,
        moonDirection,
        moonRadiance,
        moonAmount,
        VOLUMETRIC_CLOUD_MOON_INTENSITY,
        dither);

    float height01 = GetVolumetricCloudHeight01(position.y);
    float ambientWrap = lerp(0.20, 0.65, height01);
    sourceRadiance += skyAmbientRadiance
        * ambientWrap
        * (1.0 / PI);

    result.scattering = sourceRadiance * scattering;
    result.extinction = extinction;
#endif

    return result;
}

#endif
