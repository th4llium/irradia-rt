#ifndef __SKY_HLSL__
#define __SKY_HLSL__

#include "Generated/Signature.hlsl"
#include "Util.hlsl"

#define CAM_HEIGHT 1800.0
#define INFINITY 3.402823466e38

#define SUN_DIRECT_START   -0.060
#define SUN_DIRECT_END      0.145
#define DAY_SKY_START      -0.145
#define DAY_SKY_END         0.130
#define NIGHT_START         0.070
#define NIGHT_END          -0.160

#define MOON_GLOW_INTENSITY 0.18
#define STAR_INTENSITY 1.35

static const float3 rayleighCoeff = float3(0.27, 0.5, 1.0) * 1.0e-5;
static const float3 mieCoeff = float3(0.5e-6, 0.5e-6, 0.5e-6);
static const float3 totalCoeff = rayleighCoeff + mieCoeff;
static const float sunBrightness = 3.0;
static const float3 moonDiskColor = float3(0.78, 0.82, 0.92);

static const float SKY_OUTPUT_SCALE = 1.0;
static const float SKY_AMBIENT_MIN_DAY_ILLUMINANCE_LUX = 12000.0;
static const float SKY_AMBIENT_MAX_DAY_ILLUMINANCE_LUX = 28000.0;
static const float3 SKY_AMBIENT_BLOCK_TINT = float3(0.55, 0.76, 1.55);
static const float SKY_AMBIENT_NIGHT_SCALE = 56.0;

static const float TERRAIN_SUN_ILLUMINANCE_LUX = 130000.0;
static const float TERRAIN_FULL_MOON_ILLUMINANCE_LUX = 0.25;
static const float TERRAIN_LUX_TO_ENGINE_RADIANCE = 1.0 / 30000.0;
static const float3 TERRAIN_SOLAR_RGB_5778K = float3(1.0, 0.935, 0.74);
static const float TERRAIN_DAY_CLEAR_LUMINANCE_SCALE = 0.90;
static const float SKY_AMBIENT_DAY_CLEAR_LUMINANCE_SCALE = 0.92;

static const float VL_FOG_MIN_DISTANCE = 96.0;
static const float VL_FOG_TARGET_TRANSMITTANCE = 0.22;
static const float VL_FOG_WATER_DENSITY = 0.025;
static const float VL_FOG_AIR_EXTINCTION_SCALE = 17.0;

float GetSunAmount(float3 sunDir)
{
    return smoothstep(SUN_DIRECT_START, SUN_DIRECT_END, sunDir.y);
}

float GetDaySkyAmount(float3 sunDir)
{
    return smoothstep(DAY_SKY_START, DAY_SKY_END, sunDir.y);
}

float GetNightAmount(float3 sunDir)
{
    return 1.0 - smoothstep(NIGHT_END, NIGHT_START, sunDir.y);
}

float GetLightAboveHorizonAmount(float3 lightDir)
{
    return smoothstep(-0.035, 0.075, lightDir.y);
}

float GetMoonAmount(float3 sunDir, float3 moonDir)
{
    return GetLightAboveHorizonAmount(moonDir) * GetNightAmount(sunDir);
}

float D0(float x)
{
    return abs(x) + 1.0e-8;
}

float3 D0(float3 x)
{
    return abs(x) + 1.0e-8;
}

float3 Scatter(float3 coeff, float depth)
{
    return coeff * depth;
}

float3 Absorb(float3 coeff, float depth)
{
    return exp2(Scatter(coeff, -depth));
}

float CalcParticleThickness(float depth)
{
    depth = depth * 2.0;
    depth = max(depth + 0.01, 0.01);
    depth = 1.0 / depth;
    return 100000.0 * depth;
}

float RayleighPhase(float x)
{
    return 0.375 * (1.0 + x * x);
}

float SkyHgPhase(float x, float g)
{
    float g2 = g * g;
    return 0.25
        * ((1.0 - g2)
        * pow(1.0 + g2 - 2.0 * g * x, -1.5));
}

float MiePhaseSky(float x, float depth)
{
    return SkyHgPhase(x, exp2(-0.000003 * depth));
}

float3 AtmosphereSunDir(float3 sunDir)
{
    float y = max(sunDir.y, 0.025);
    return normalize(float3(sunDir.x, y, sunDir.z));
}

float3 CalcAtmosphericScatter(float3 worldVector, float3 sunVector)
{
    float directAmount = GetSunAmount(sunVector);
    float skyAmount = GetDaySkyAmount(sunVector);

    if (skyAmount <= 0.00001) {
        return 0.0;
    }

    float3 sunDir = AtmosphereSunDir(sunVector);
    const float ln2 = 0.6931471805599453;

    float lDotW = dot(sunDir, worldVector);
    float lDotU = dot(sunDir, float3(0.0, 1.0, 0.0));
    float uDotW = dot(float3(0.0, 1.0, 0.0), worldVector);

    float opticalDepth = CalcParticleThickness(uDotW);
    float opticalDepthLight = CalcParticleThickness(lDotU);

    float3 scatterView = Scatter(totalCoeff, opticalDepth);
    float3 absorbView = Absorb(totalCoeff, opticalDepth);

    float3 scatterLight = Scatter(totalCoeff, opticalDepthLight);
    float3 rawAbsorbLight = Absorb(totalCoeff, opticalDepthLight);

    float3 absorbSun =
        abs(rawAbsorbLight - absorbView)
        / D0((scatterLight - scatterView) * ln2);

    float3 mieScatter =
        Scatter(mieCoeff, opticalDepth)
        * MiePhaseSky(lDotW, opticalDepth);
    float3 rayleighScatter =
        Scatter(rayleighCoeff, opticalDepth)
        * RayleighPhase(lDotW);
    float3 scatterSun = mieScatter + rayleighScatter;

    float3 sunSpot =
        smoothstep(0.9999, 0.99993, lDotW)
        * absorbView
        * sunBrightness;

    float3 skyColorNoSun =
        scatterSun
        * absorbSun
        * sunBrightness
        * skyAmount;

    return skyColorNoSun + sunSpot * sunBrightness * directAmount;
}

float Hash21(float2 p)
{
    p = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}

float2 SkyUV(float3 dir)
{
    float u = atan2(dir.z, dir.x) / (2.0 * PI) + 0.5;
    float v = asin(clamp(dir.y, -1.0, 1.0)) / PI + 0.5;
    return float2(u, v);
}

float GetSkyTimeSeconds()
{
    return (float)g_view.frameCount * (1.0 / 60.0);
}

float StarLayer(float2 uv, float scale, float threshold)
{
    float2 p = uv * scale;
    float2 id = floor(p);
    float2 gv = frac(p) - 0.5;

    float rnd = Hash21(id);
    float starMask = smoothstep(threshold, 1.0, rnd);

    float d = length(gv);
    float core = smoothstep(0.045, 0.0, d);

    float twinkle =
        0.75
        + 0.25
        * sin(GetSkyTimeSeconds() * (1.5 + rnd * 4.0)
        + rnd * 6.28318);

    return core * starMask * twinkle;
}

float3 RenderStars(float3 viewDir, float nightAmount)
{
    float2 uv = SkyUV(viewDir);
    float horizonFade = smoothstep(-0.02, 0.18, viewDir.y);
    float stars = 0.0;

    stars += StarLayer(uv, 260.0, 0.992);
    stars += StarLayer(uv + float2(0.37, 0.11), 420.0, 0.996) * 0.75;
    stars += StarLayer(uv + float2(0.13, 0.71), 720.0, 0.9985) * 0.65;

    return stars.xxx * STAR_INTENSITY * nightAmount * horizonFade;
}

float3 RenderMoonAndStars(float3 viewDir, float3 sunDir, float3 moonDir)
{
    float nightAmount = GetNightAmount(sunDir);
    float moonAmount = GetMoonAmount(sunDir, moonDir);

    float3 color = RenderStars(viewDir, nightAmount);

    float mDot = dot(viewDir, moonDir);

    float moonDisk = smoothstep(0.999965, 0.999990, mDot);

    float moonGlowWide = pow(max(mDot, 0.0), 96.0);
    float moonGlowTight = pow(max(mDot, 0.0), 768.0);
    float moonGlow = moonGlowWide * 0.10 + moonGlowTight * 0.45;

    color += moonDisk * moonDiskColor * 1.15 * moonAmount;
    color += moonGlow * moonDiskColor * MOON_GLOW_INTENSITY * moonAmount;

    return color;
}

float2 getRotationMatrixMult(float2 v, float angle) {
    float c = cos(angle), s = sin(angle);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

float2 applyNoiseRotation(float2 v) {
    return float2(v.x * 0.95534 - v.y * 0.29552, v.x * 0.29552 + v.y * 0.95534);
}

float getTriangleWave(float x) { 
    return clamp(abs(frac(x) - 0.5), 0.01, 0.49); 
}

float2 getTriangleWave2D(float2 p) { 
    return float2(getTriangleWave(p.x) + getTriangleWave(p.y), getTriangleWave(p.y) + getTriangleWave(p.x)); 
}

float calculateAuroraNoise(float2 position, float timeAngle) {
    float amplitude = 1.8;
    float shiftScale = 2.5;
    float noiseSum = 0.0;
    
    position = getRotationMatrixMult(position, position.x * 0.06);
    float2 basePosition = position;
    
    for (float i = 0.0; i < 3.0; i++) {
        float2 domainShift = getTriangleWave2D(basePosition * 1.85) * 0.75;
        domainShift = getRotationMatrixMult(domainShift, timeAngle);
        position -= domainShift / shiftScale;

        basePosition = applyNoiseRotation(basePosition * 1.618);
        shiftScale *= 0.45;
        amplitude *= 0.42;
        
        position *= 1.21 + (noiseSum - 1.0) * 0.02;
        
        noiseSum += getTriangleWave(position.x + getTriangleWave(position.y)) * amplitude;
        position = -applyNoiseRotation(position);
    }
    
    return clamp(1.0 / pow(max(noiseSum * 29.0, 0.0001), 1.3), 0.0, 0.55);
}

float getRayDistanceToLayer(float3 rayOrigin, float3 rayDir, float stepIndex) {
    float heightCurve = 0.8 + pow(stepIndex, 1.4) * 0.002;
    float perspectiveDenominator = rayDir.y * 2.0 + 0.4;
    return (heightCurve - rayOrigin.y) / max(perspectiveDenominator, 0.0001);
}

float3 getAuroraBaseColor(float stepIndex, float noiseValue) {
    float3 colorPhase = 1.0 - float3(2.15, -0.5, 1.2);
    return (sin(colorPhase + stepIndex * 0.043) * 0.5 + 0.5) * noiseValue;
}

float4 renderAuroraVolumetric(float3 rayOrigin, float3 rayDir, float dither, float time) {
    float4 accumulatedColor = 0.0;
    float4 blurredColor = 0.0;
    
    const float AURORA_SPEED = 0.28;
    const float AURORA_SCALE = 2.5;
    
    float timeAngle = time * AURORA_SPEED;
    
    const float MAX_STEPS = 20.0;
    const float STRIDE_MULTIPLIER = 2.5;
    
    for(float i = 0.0; i < MAX_STEPS; i++) {
        float jitteredStep = (i + dither) * STRIDE_MULTIPLIER; 
        
        float rayDist = getRayDistanceToLayer(rayOrigin, rayDir, jitteredStep);
        float3 worldPos = rayOrigin + rayDist * rayDir;
        float2 samplePos = worldPos.zx;
        
        samplePos += float2(sin(worldPos.z * 0.61803), cos(worldPos.x * 0.4321)) * 1.2;
        
        float noiseValue = calculateAuroraNoise(samplePos * AURORA_SCALE, timeAngle);
        float4 stepColor = float4(getAuroraBaseColor(jitteredStep, noiseValue), noiseValue);
        
        blurredColor = lerp(blurredColor, stepColor, 0.6); 
        
        float attenuation = exp2(-jitteredStep * 0.065 - 2.5) * STRIDE_MULTIPLIER;
        float fadeOutBottom = smoothstep(0.0, 5.0, jitteredStep);
        
        accumulatedColor += blurredColor * attenuation * fadeOutBottom;
    }
    
    accumulatedColor *= clamp(rayDir.y * 15.0 + 0.4, 0.0, 1.0);
    return accumulatedColor * 0.9;
}

float3 RenderEngineSky(float3 viewDir, float3 sunDir, float3 moonDir)
{
    if (IsEndSky())
        return 0.0;

    float3 color = CalcAtmosphericScatter(viewDir, sunDir);
    color += RenderMoonAndStars(viewDir, sunDir, moonDir);

    float nightAmount = GetNightAmount(sunDir);
    if (nightAmount > 0.0 && viewDir.y > 0.0) {
        float3 rayOrigin = float3(0.0, 0.0, -6.7);
        float2 screenPos = SkyUV(viewDir) * g_view.renderResolution;
        float dither = blueNoiseTexture.SampleLevel(linearWrapSampler, float3(screenPos / 256.0, g_view.frameCount % 128), 0).x;
        float4 auroraColor = renderAuroraVolumetric(rayOrigin, viewDir, dither, GetSkyTimeSeconds());
        
        float horizonFade = smoothstep(0.0, 0.1, viewDir.y);
        auroraColor *= horizonFade * nightAmount;
        
        color =
            color * (1.0 - auroraColor.a * 0.45)
            + auroraColor.rgb * 0.85;
    }

    float rainAmount = GetWeatherRainAmount();
    if (rainAmount > 0.0) {
        float dayAmount = GetDaySkyAmount(sunDir);
        float rainNightAmount = GetNightAmount(sunDir);
        float horizonAmount = 1.0 - smoothstep(0.05, 0.55, viewDir.y);
        float3 rainGreyTint = GetWeatherRainPalette(rainNightAmount);
        float rainyFloor =
            lerp(0.013, 0.0011, rainNightAmount)
            * (0.65 + 0.35 * horizonAmount)
            * max(dayAmount + rainNightAmount, 0.15);
        float3 rainySky =
            max(
                GetWeatherGreyRadiance(color, rainGreyTint),
                rainGreyTint * rainyFloor);
        color =
            lerp(
                color,
                rainySky,
                rainAmount * lerp(0.82, 0.96, rainNightAmount));
        color *= lerp(
            1.0,
            GetWeatherRainLuminanceScale(rainNightAmount),
            rainAmount);
    }

    if (any(isnan(color)) || any(isinf(color))) {
        color = 0.0;
    }

    return max(color * SKY_OUTPUT_SCALE, 0.0);
}

float GetVolumetricFogMaxDistance()
{
    return max(g_view.renderDistance, VL_FOG_MIN_DISTANCE);
}

float GetRenderDistanceFogExtinction()
{
    float baseExtinction =
        -log(VL_FOG_TARGET_TRANSMITTANCE)
        / max(GetVolumetricFogMaxDistance(), 1.0);
    float rainAmount = GetWeatherRainAmount();
    float nightAmount = GetNightAmount(getOffsetTrueDirectionToSun());
    float rainMultiplier =
        lerp(
            WEATHER_RAIN_FOG_DENSITY_MULTIPLIER,
            WEATHER_RAIN_NIGHT_FOG_DENSITY_MULTIPLIER,
            nightAmount);
    return baseExtinction * lerp(1.0, rainMultiplier, rainAmount);
}

float GetVolumetricFogDensity(bool inWater)
{
    return inWater ? VL_FOG_WATER_DENSITY : GetRenderDistanceFogExtinction();
}

float3 GetVolumetricFogMediaExtinction(bool inWater)
{
    if (inWater) {
        return (1.0).xxx;
    }

    float3 extinction = max(
        g_view.mediaExtinction[MEDIA_TYPE_AIR].rgb,
        0.0);
    return max(extinction * VL_FOG_AIR_EXTINCTION_SCALE, (1.0).xxx);
}

float3 CalcFogTransmittance(float distance, float3 extinction)
{
    return exp(-extinction * distance);
}

float GetTerrainAirMass(float lightY)
{
    float y = clamp(lightY, 0.005, 1.0);
    float zenithDegrees = acos(y) * (180.0 / PI);
    return min(
        1.0 / max(
            y + 0.15 * pow(max(93.885 - zenithDegrees, 0.01), -1.253),
            0.01),
        40.0);
}

float3 GetTerrainLightTransmittance(float3 lightDir, float ozoneAmount)
{
    float airMass = GetTerrainAirMass(lightDir.y);
    float extraAirMass = max(airMass - 1.0, 0.0);
    float3 rayleighExtinction = float3(0.055, 0.125, 0.320);
    float3 mieExtinction = (0.018).xxx;
    float3 ozoneExtinction = float3(0.010, 0.030, 0.004) * ozoneAmount;
    return exp(-(rayleighExtinction + mieExtinction + ozoneExtinction) * extraAirMass);
}

float3 GetLightTransmittance(
    float3 position,
    float3 lightDir,
    float multiplier,
    float ozoneMultiplier)
{
    return pow(
        GetTerrainLightTransmittance(lightDir, ozoneMultiplier),
        multiplier);
}

float3 GetLightTransmittance(float3 position, float3 lightDir)
{
    return GetLightTransmittance(position, lightDir, 1.0, 1.0);
}

float3 GetAtmosphere(
    float3 rayStart,
    float3 rayDir,
    float rayLength,
    float3 lightDir,
    float3 lightColor,
    out float4 transmittance)
{
    if (IsEndSky()) {
        transmittance = float4(1.0, 1.0, 1.0, 1.0);
        return 0.0;
    }

    rayDir = safeNormalize(rayDir, float3(0, 1, 0));

    float pathScale = rayLength > 1.0e20 ? 1.0 : saturate(rayLength * 0.004);
    float referenceSunRadiance =
        TERRAIN_SUN_ILLUMINANCE_LUX * TERRAIN_LUX_TO_ENGINE_RADIANCE;
    float sourceScale =
        saturate(getLuminance(lightColor) / max(referenceSunRadiance, 1.0e-4));

    float3 sky = CalcAtmosphericScatter(rayDir, lightDir)
        * SKY_OUTPUT_SCALE
        * pathScale
        * sourceScale;

    float opticalDepth = CalcParticleThickness(dot(float3(0.0, 1.0, 0.0), rayDir));
    transmittance.xyz = Absorb(totalCoeff, opticalDepth * pathScale);
    transmittance.w = smoothstep(-0.025, 0.010, rayDir.y);

    if (any(isnan(sky)) || any(isinf(sky))) {
        sky = 0.0;
    }

    return max(sky, 0.0);
}

float3 GetAtmosphere(
    float3 rayStart,
    float3 rayDir,
    float rayLength,
    float3 lightDir,
    float3 lightColor)
{
    float4 transmittance;
    return GetAtmosphere(
        rayStart,
        rayDir,
        rayLength,
        lightDir,
        lightColor,
        transmittance);
}

void GetSunColorAndLux(
    float3 pos,
    float3 sunDir,
    out float3 color,
    out float lux)
{
    if (IsEndSky()) {
        lux = TERRAIN_SUN_ILLUMINANCE_LUX;
        color =
            (1.0).xxx
            * (TERRAIN_SUN_ILLUMINANCE_LUX
                * TERRAIN_LUX_TO_ENGINE_RADIANCE);
        return;
    }

    float3 transmittance = GetTerrainLightTransmittance(sunDir, 1.0);
    float3 spectralColor = TERRAIN_SOLAR_RGB_5778K * transmittance;
    float noonBoost =
        lerp(1.0, 1.04, smoothstep(0.35, 0.90, sunDir.y));
    float clearDayScale = TERRAIN_DAY_CLEAR_LUMINANCE_SCALE;

    lux =
        getLuminance(spectralColor)
        * TERRAIN_SUN_ILLUMINANCE_LUX
        * noonBoost
        * clearDayScale;
    color =
        spectralColor
        * (TERRAIN_SUN_ILLUMINANCE_LUX * TERRAIN_LUX_TO_ENGINE_RADIANCE)
        * noonBoost
        * clearDayScale;

    float rainAmount = GetWeatherRainOnSurfaceAmount(pos);
    if (rainAmount > 0.0) {
        float dayAmount = GetDaySkyAmount(sunDir);
        float3 greySun =
            GetWeatherGreyRadiance(color, GetWeatherRainPalette(0.0));
        float occludedScale =
            lerp(1.0, lerp(0.055, 0.14, dayAmount), rainAmount);
        color = lerp(color, greySun, rainAmount * 0.88) * occludedScale;
        lux *= occludedScale;
    }
}

void GetMoonColorAndLux(
    float3 pos,
    float3 sunDir,
    float3 moonDir,
    out float3 color,
    out float lux)
{
    if (IsEndSky()) {
        color = 0.0;
        lux = 0.0;
        return;
    }

    float3 transmittance = GetTerrainLightTransmittance(moonDir, 0.35);
    float3 spectralColor = moonDiskColor * transmittance;

    lux = getLuminance(spectralColor) * TERRAIN_FULL_MOON_ILLUMINANCE_LUX;
    color =
        spectralColor
        * (TERRAIN_FULL_MOON_ILLUMINANCE_LUX * TERRAIN_LUX_TO_ENGINE_RADIANCE);

    float rainAmount = GetWeatherRainOnSurfaceAmount(pos);
    if (rainAmount > 0.0) {
        float3 greyMoon =
            GetWeatherGreyRadiance(color, float3(0.55, 0.58, 0.64));
        float occludedScale = lerp(1.0, 0.18, rainAmount);
        color = lerp(color, greyMoon, rainAmount * 0.92) * occludedScale;
        lux *= occludedScale;
    }
}

void GetSkyAmbientAndLux(
    float3 pos,
    float3 normal,
    float3 sunDir,
    float3 moonDir,
    out float3 color,
    out float lux)
{
    if (IsEndSky()) {
        color = 0.0;
        lux = 0.0;
        return;
    }

    float daySkyAmount = GetDaySkyAmount(sunDir);
    float sunAmount = GetSunAmount(sunDir);
    float3 ambientReferenceDir =
        safeNormalize(float3(0.33, 0.88, 0.34), float3(0.0, 1.0, 0.0));
    float3 dayChroma =
        CalcAtmosphericScatter(ambientReferenceDir, sunDir)
        * SKY_OUTPUT_SCALE
        * SKY_AMBIENT_BLOCK_TINT;
    dayChroma = max(dayChroma, 0.0);
    if (any(isnan(dayChroma)) || any(isinf(dayChroma))) {
        dayChroma = 0.0;
    }

    float dayChromaLuminance =
        getLuminance(dayChroma);
    float targetDayLux =
        lerp(
            SKY_AMBIENT_MIN_DAY_ILLUMINANCE_LUX,
            SKY_AMBIENT_MAX_DAY_ILLUMINANCE_LUX,
            sunAmount)
        * daySkyAmount;
    float validDayChroma = dayChromaLuminance > 1.0e-6 ? 1.0 : 0.0;
    float dayAmbientScale =
        (targetDayLux * TERRAIN_LUX_TO_ENGINE_RADIANCE)
        / max(dayChromaLuminance, 1.0e-6);
    float3 dayAmbient =
        dayChroma
        * dayAmbientScale
        * validDayChroma
        * SKY_AMBIENT_DAY_CLEAR_LUMINANCE_SCALE;

    float3 nightAmbient =
        moonDiskColor
        * (TERRAIN_FULL_MOON_ILLUMINANCE_LUX * TERRAIN_LUX_TO_ENGINE_RADIANCE)
        * GetMoonAmount(sunDir, moonDir)
        * SKY_AMBIENT_NIGHT_SCALE;

    color = max(dayAmbient + nightAmbient, 0.0);
    float rainAmount = GetWeatherRainOnSurfaceAmount(pos);
    if (rainAmount > 0.0) {
        float nightAmount = GetNightAmount(sunDir);
        float3 rainyAmbient =
            GetWeatherGreyRadiance(
                color,
                GetWeatherRainPalette(nightAmount));
        float rainyScale = lerp(0.36, 0.09, nightAmount);
        color =
            lerp(color, rainyAmbient, rainAmount * 0.88)
            * lerp(1.0, rainyScale, rainAmount);
    }
    if (any(isnan(color)) || any(isinf(color))) {
        color = 0.0;
    }

    lux = getLuminance(color) / max(TERRAIN_LUX_TO_ENGINE_RADIANCE, 1.0e-6);
}

float3 GetFogColor(
    float3 pos,
    float3 rayDir,
    float fogDistance,
    float3 sunDir,
    float3 moonDir)
{
    if (IsEndSky())
        return 0.0;

    float3 viewDir = safeNormalize(rayDir, float3(1, 0, 0));
    float3 horizonDir = safeNormalize(
        float3(viewDir.x, 0.0, viewDir.z),
        float3(1, 0, 0));
    float fogDepth = min(max(fogDistance, 0.0), GetVolumetricFogMaxDistance());
    float normalizedDepth =
        saturate(fogDepth / max(GetVolumetricFogMaxDistance(), 1.0));
    float pathScale =
        lerp(
            0.28,
            1.0,
            smoothstep(0.04, 0.70, normalizedDepth));
    float3 dayFog =
        CalcAtmosphericScatter(horizonDir, sunDir)
        * SKY_OUTPUT_SCALE
        * pathScale;
    float3 nightFog =
        moonDiskColor
        * GetMoonAmount(sunDir, moonDir)
        * (TERRAIN_FULL_MOON_ILLUMINANCE_LUX * TERRAIN_LUX_TO_ENGINE_RADIANCE)
        * 32.0
        * pathScale;
    float3 fogColor = max(dayFog + nightFog, 0.0);
    float rainAmount = GetWeatherRainAmount();
    if (rainAmount > 0.0) {
        float nightAmount = GetNightAmount(sunDir);
        float3 rainPalette = GetWeatherRainPalette(nightAmount);
        float3 rainFog =
            GetWeatherGreyRadiance(
                fogColor,
                rainPalette);
        float fogFloor =
            lerp(0.010, 0.0008, nightAmount)
            * smoothstep(0.0, GetVolumetricFogMaxDistance() * 0.34, fogDepth);
        rainFog = max(
            rainFog,
            rainPalette * fogFloor);
        fogColor = lerp(fogColor, rainFog, rainAmount * 0.92);
        fogColor *= lerp(
            1.0,
            GetWeatherRainLuminanceScale(nightAmount),
            rainAmount);
    }
    return fogColor;
}

float3 GetTransparentEnvironmentSky(float3 rayDir)
{
    if (IsEndSky())
        return 0.0;

    float3 sunDir = getOffsetTrueDirectionToSun();
    float3 moonDir = getOffsetTrueDirectionToMoon();
    float3 envDir = safeNormalize(rayDir, float3(0, 1, 0));
    float belowHorizon = 1.0 - smoothstep(-0.16, 0.06, envDir.y);

    float3 liftedDir = envDir;
    liftedDir.y = max(
        liftedDir.y,
        lerp(0.11, 0.035, saturate(envDir.y * 8.0 + 0.5)));
    liftedDir = safeNormalize(liftedDir, float3(0, 1, 0));

    float3 color = lerp(
        RenderEngineSky(envDir, sunDir, moonDir),
        RenderEngineSky(liftedDir, sunDir, moonDir),
        belowHorizon);
    if (getLuminance(color) < 1.0e-5) {
        float3 ambient;
        float ambientLux;
        GetSkyAmbientAndLux(
            g_view.viewOriginSteveSpace,
            float3(0, 1, 0),
            sunDir,
            moonDir,
            ambient,
            ambientLux);
        color = max(color, ambient * 0.35);
    }

    return max(color, 0.0);
}

float3 GetSunDisc(float3 rayDir, float3 lightDir)
{
    float lDotW = dot(AtmosphereSunDir(lightDir), safeNormalize(rayDir, float3(0, 1, 0)));
    return (smoothstep(0.9999, 0.99993, lDotW) * sunBrightness).xxx;
}

float GetAutoExposureMultiplier(float3 position, float3 sunDir, float3 moonDir)
{
    return 1.0;
}

#ifndef SKY_NO_RAY_STATE
void RenderSky(inout RayState rayState)
{
    if (all(rayState.throughput == 0)) return;

    float3 viewDir = safeNormalize(rayState.rayDesc.Direction, float3(0, 1, 0));

    float3 color = GetTransparentEnvironmentSky(viewDir);
    rayState.color += rayState.throughput * color;
}
#endif

#endif
