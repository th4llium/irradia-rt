#ifndef __SKY_HLSL__
#define __SKY_HLSL__

#include "Generated/Signature.hlsl"
#include "Util.hlsl"

// Atmosphere Constants
#define PREVENT_CAMERA_GROUND_CLIP 
#define AERIAL_SCALE               3.0 
#define NIGHT_LIGHT                2e-3 
#define SUN_DISC_SIZE              2.5 
#define MOON_DISC_SIZE             2.4

#define CITY_LIGHT_POLLUTION       float3(1.0, 0.55, 0.2)
#define CITY_LIGHT_INTENSITY       0.025
#define CITY_GLOW_HEIGHT           12.0

#define CAM_HEIGHT                 1800.0
#define CAM_Z                      1.4
#define CAM_EXPOSURE               10.0
#define CAM_AUTO_EXPOSURE_EV_LIMIT 4.0
#define CAM_GAMMA                  2.0

#define INFINITY 3.402823466e38

#define ATMOSPHERE_HEIGHT  100000.0
#define ATMOSPHERE_DENSITY 1.0
#define PLANET_RADIUS      6371000.0
#define PLANET_CENTER      float3(0, -PLANET_RADIUS, 0)
#define C_RAYLEIGH         (float3(5.802, 13.558, 33.100) * 1e-6)
#define C_MIE              (float3(3.996, 3.996, 3.996) * 1e-6)
#define C_OZONE            (float3(0.650, 1.881, 0.085) * 1e-6)

#define RAYLEIGH_MAX_LUM   2.5
#define MIE_MAX_LUM        0.5

#define M_EXPOSURE_MUL        0.23
#define M_FAKE_MS             0.3
#define M_AERIAL              2.5
#define M_TRANSMITTANCE       0.25
#define M_LIGHT_TRANSMITTANCE 1e6
#define M_DENSITY_HEIGHT_MOD  1e-12
#define M_DENSITY_CAM_MOD     10.0
#define M_OZONE               1.5
#define M_OZONE2              5.0
#define M_MIE                 float3(0.95, 0.85, 0.75)

float2 SphereIntersection(float3 rayStart, float3 rayDir, float3 sphereCenter, float sphereRadius) {
    float3 oc = rayStart - sphereCenter;
    float b = dot(oc, rayDir);
    float c = dot(oc, oc) - sq(sphereRadius);
    float h = sq(b) - c;
    if (h < 0.0) return float2(-1.0, -1.0);
    h = sqrt(h);
    return float2(-b-h, -b+h);
}
float2 PlanetIntersection(float3 rayStart, float3 rayDir) {
    return SphereIntersection(rayStart, rayDir, PLANET_CENTER, PLANET_RADIUS);
}
float2 AtmosphereIntersection(float3 rayStart, float3 rayDir) {
    return SphereIntersection(rayStart, rayDir, PLANET_CENTER, PLANET_RADIUS + ATMOSPHERE_HEIGHT);
}

float PhaseR(float costh) { return (1.0+sq(costh))*0.06; }
float PhaseM(float costh, float g) {
    g = min(g, 0.9381);
    float k = 1.55*g-0.55*sq(g)*g;
    float a = 1.0-sq(k);
    float b = 12.57*sq(1.0-k*costh);
    return a/b;
}

float3 GetLightTransmittance(float3 position, float3 lightDir, float multiplier, float ozoneMultiplier) {
    float lightExtinctionAmount = exp(-(saturate(lightDir.y + 0.05) * 40.0)) +
        exp(-(saturate(lightDir.y + 0.5) * 5.0)) * 0.4 +
        sq(saturate(1.0-lightDir.y)) * 0.02 + 0.002;
    return exp(-(C_RAYLEIGH + C_MIE + C_OZONE * ozoneMultiplier) * lightExtinctionAmount * ATMOSPHERE_DENSITY * multiplier * M_LIGHT_TRANSMITTANCE);
}
float3 GetLightTransmittance(float3 position, float3 lightDir) {
    return GetLightTransmittance(position, lightDir, 1.0, 1.0);
}

void GetRayleighMie(float opticalDepth, float densityR, float densityM, out float3 R, out float3 M) {
    R = (1.0 - exp(-opticalDepth * densityR * C_RAYLEIGH / RAYLEIGH_MAX_LUM)) * RAYLEIGH_MAX_LUM;
    M = (1.0 - exp(-opticalDepth * densityM * C_MIE / MIE_MAX_LUM)) * MIE_MAX_LUM;
}

float3 GetAtmosphere(float3 rayStart, float3 rayDir, float rayLength, float3 lightDir, float3 lightColor, out float4 transmittance) {
#ifdef PREVENT_CAMERA_GROUND_CLIP
    rayStart.y = max(rayStart.y, 1.0);
#endif

    float2 t1 = PlanetIntersection(rayStart, rayDir);
    float2 t2 = AtmosphereIntersection(rayStart, rayDir);
    float normAltitude = rayStart.y / ATMOSPHERE_HEIGHT;

    if (t2.y < 0.0) {
        transmittance = (1.0).xxxx;
        return (0.0).xxx;
    } else {
        t2.y -= max(0.0, t2.x);
        float opticalDepth = t1.x > 0.0 ? min(t1.x, t2.y) : t2.y;

        opticalDepth = min(rayLength, opticalDepth);
        opticalDepth = min(opticalDepth * M_AERIAL * AERIAL_SCALE, t2.y);

        float hbias = 1.0-1.0/(2.0+sq(t2.y)*M_DENSITY_HEIGHT_MOD);
        hbias = pow(hbias, 1.0+normAltitude*M_DENSITY_CAM_MOD); 
        float sqhbias = sq(hbias);
        float densityR = sqhbias * ATMOSPHERE_DENSITY;
        float densityM = sq(sqhbias)*hbias * ATMOSPHERE_DENSITY;

        float ly = clamp(lightDir.y + saturate(-lightDir.y + 0.02) * saturate(lightDir.y + 0.7), -1.0, 1.0);
        lightColor *= GetLightTransmittance(rayStart, float3(lightDir.x, ly, lightDir.z), hbias, M_OZONE2) * PI;

        float3 R, M;
        GetRayleighMie(opticalDepth, densityR, densityM, R, M);
        
        float3 E = (C_RAYLEIGH * densityR + C_MIE * densityM + C_OZONE * densityR * M_OZONE) * pow4(1.0 - normAltitude) * M_TRANSMITTANCE;

        float costh = dot(rayDir, lightDir);
        float phaseR = PhaseR(costh);
        float phaseM = PhaseM(costh, 0.88);
        
        float sunDownMask = smoothstep(0.1, -0.2, lightDir.y); 
        float horizonMask = exp(-max(0.0, rayDir.y) * CITY_GLOW_HEIGHT); 
        
        float3 ambientNight = (NIGHT_LIGHT).xxx;
        float3 cityGlow = CITY_LIGHT_POLLUTION * CITY_LIGHT_INTENSITY * horizonMask * sunDownMask;
        float3 totalNightLighting = ambientNight + cityGlow;
        
        float3 rayleigh = (phaseR + phaseR * M_FAKE_MS) * lightColor + totalNightLighting * phaseR;
        float3 mie = ((phaseM + phaseR * M_FAKE_MS) * lightColor + ambientNight * phaseR) * M_MIE;
        float3 scattering = mie * M + rayleigh * R;

        transmittance.xyz = exp(-(opticalDepth + pow8(opticalDepth * 4.5e-6)) * E);
        transmittance.w = step(t1.x, 0.0);

        return scattering * M_EXPOSURE_MUL;
    }
}

float3 GetAtmosphere(float3 rayStart, float3 rayDir, float rayLength, float3 lightDir, float3 lightColor) {
    float4 transmittance;
    return GetAtmosphere(rayStart, rayDir, rayLength, lightDir, lightColor, transmittance);
}

void GetSunColorAndLux(float3 pos, float3 sunDir, out float3 color, out float lux) {
    float3 sunBaseRadiance = (4.0).xxx; 
    float3 transmittance = GetLightTransmittance(pos, sunDir);
    color = sunBaseRadiance * transmittance; 
    lux = getLuminance(color); 
}

void GetMoonColorAndLux(float3 pos, float3 sunDir, float3 moonDir, out float3 color, out float lux) {
    float3 moonBaseRadiance = (0.005).xxx * (dot(sunDir, -moonDir) * 0.5 + 0.5);
    float3 transmittance = GetLightTransmittance(pos, moonDir);
    color = moonBaseRadiance * transmittance;
    lux = getLuminance(color);
}

void GetSkyAmbientAndLux(float3 pos, float3 normal, float3 sunDir, float3 moonDir, out float3 color, out float lux) {
    float4 t;
    float3 sunAmbient = GetAtmosphere(pos, normal, INFINITY, sunDir, (1.0).xxx, t);
    float3 moonBaseRadiance = (0.005).xxx * (dot(sunDir, -moonDir) * 0.5 + 0.5);
    float3 moonAmbient = GetAtmosphere(pos, normal, INFINITY, moonDir, moonBaseRadiance, t);
    color = (sunAmbient + moonAmbient) * 5.0;
    lux = getLuminance(color);
}

float3 GetFogColor(float3 pos, float3 rayDir, float fogDistance, float3 sunDir, float3 moonDir) {
    float4 t;
    float3 sunFog = GetAtmosphere(pos, rayDir, fogDistance, sunDir, (1.0).xxx, t);
    float3 moonBaseRadiance = (0.05).xxx * (dot(sunDir, -moonDir) * 0.5 + 0.5);
    float3 moonFog = GetAtmosphere(pos, rayDir, fogDistance, moonDir, moonBaseRadiance, t);
    return sunFog + moonFog;
}

float3 GetSunDisc(float3 rayDir, float3 lightDir) {
    const float A = cos(0.00436 * SUN_DISC_SIZE);
    float costh = dot(rayDir, lightDir);
    float disc = sqrt(smoothstep(A, 1.0, costh));
    return (disc).xxx;
}

float GetAutoExposureMultiplier(float3 position, float3 sunDir, float3 moonDir) {
    float3 skyAmbient;
    float skyLux;
    GetSkyAmbientAndLux(position, float3(0, 1, 0), sunDir, moonDir, skyAmbient, skyLux);
    float lum = dot(skyAmbient, float3(0.3, 0.59, 0.11));
    
    return min(CAM_AUTO_EXPOSURE_EV_LIMIT, 0.003 / clamp(lum, 0.0002, 1.0)) * CAM_EXPOSURE;
}

#ifndef SKY_NO_RAY_STATE
void RenderSky(inout RayState rayState)
{
    if (all(rayState.throughput == 0)) return;
    
    float3 sunDir = getOffsetPrimaryCelestialDirection();
    float3 moonDir = -sunDir;
    float3 rd = rayState.rayDesc.Direction;
    float3 ro = rayState.rayDesc.Origin;
    ro.y = max(ro.y, CAM_HEIGHT);

    float3 sunRadiance, moonRadiance;
    float sunLux, moonLux;
    GetSunColorAndLux(ro, sunDir, sunRadiance, sunLux);
    GetMoonColorAndLux(ro, sunDir, moonDir, moonRadiance, moonLux);

    float eclipse = 1.0 - smoothstep(0.9999, 1.0, dot(sunDir, moonDir));
    sunRadiance *= lerp(1.0, sqrt(eclipse), 0.999);
    
    float4 transmittance;
    float3 scattering = GetAtmosphere(ro, rd, INFINITY, sunDir, sunRadiance, transmittance);
    
    float3 color = 0;
    if (rayState.bounceCount == 0) {
        color = GetSunDisc(rd, sunDir) * 1e1 * sunRadiance;
    }
    
    const float moonRadius = 1737e3 * MOON_DISC_SIZE;
    float3 moonCenter = moonDir * 384400e3;
    float2 moonT = SphereIntersection(ro, rd, moonCenter, moonRadius);
    if (moonT.x > 0.0) {
        float3 moonNormal = normalize(ro + rd * moonT.x - moonCenter);
        color = clamp(dot(moonNormal, sunDir), 0.0, 1.0) * 0.14 * sunRadiance / PI;
    }
    
    color *= transmittance.w;
    color = color * transmittance.xyz + scattering;
    color += GetAtmosphere(ro, rd, INFINITY, moonDir, moonRadiance);
    
    float exposure = rayState.globalExposure;
    color *= exposure;
    
    rayState.color += rayState.throughput * color;
}
#endif

#endif
