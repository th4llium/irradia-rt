#ifndef __BRDF_HLSL__
#define __BRDF_HLSL__

#include "Constants.hlsl"
#include "Util.hlsl"

float3 F_Schlick(float cosTheta, float3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

float D_GGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH2 = NdotH * NdotH;
    float num = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    return num / max(denom, 0.0000001);
}

float G1_SmithGGX(float NdotV, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotV2 = NdotV * NdotV;
    return (2.0 * NdotV) /
        max(NdotV + sqrt(a2 + (1.0 - a2) * NdotV2), 0.00001);
}

float G_Smith(float NdotV, float NdotL, float roughness) {
    float ggx2 = G1_SmithGGX(NdotV, roughness);
    float ggx1 = G1_SmithGGX(NdotL, roughness);
    return ggx1 * ggx2;
}

// Disney Principled Diffuse
float3 DisneyDiffuse(float NdotL, float NdotV, float LdotH, float roughness, float3 diffuseColor) {
    float energyBias = lerp(0.0, 0.5, roughness);
    float energyFactor = lerp(1.0, 1.0 / 1.51, roughness);
    float fd90 = energyBias + 2.0 * LdotH * LdotH * roughness;
    float lightScatter = 1.0 + (fd90 - 1.0) * pow(clamp(1.0 - NdotL, 0.0, 1.0), 5.0);
    float viewScatter = 1.0 + (fd90 - 1.0) * pow(clamp(1.0 - NdotV, 0.0, 1.0), 5.0);
    return diffuseColor * (lightScatter * viewScatter * energyFactor / PI);
}

// Burley Normalized Subsurface Scattering
float3 BurleyNormalizedSSS(float NdotL, float NdotV, float LdotH, float roughness, float3 diffuseColor) {
    float Fss90 = LdotH * LdotH * roughness;
    float lightScatter = 1.0 + (Fss90 - 1.0) * pow(clamp(1.0 - NdotL, 0.0, 1.0), 5.0);
    float viewScatter = 1.0 + (Fss90 - 1.0) * pow(clamp(1.0 - NdotV, 0.0, 1.0), 5.0);
    float Fss = lightScatter * viewScatter;

    // Normalized to conserve energy
    return diffuseColor * (1.25 * (Fss * (1.0 / (NdotL + NdotV + 0.0001) - 0.5) + 0.5) / PI);
}

// Fdez-Aguera Multiple-Scattering Approximation
// Preserves energy at high roughness by injecting the missing multiscatter microfacet reflections.
float3 FdezAgueraMultipleScattering(float NdotV, float NdotL, float roughness, float3 F0) {
    float a = roughness * roughness;

    // Analytical directional albedo E(x) approximations
    float E_v = saturate(1.0 - a * (1.0 - NdotV));
    float E_l = saturate(1.0 - a * (1.0 - NdotL));
    float E_avg = saturate(1.0 - a * 0.5);

    // Directional average of Fresnel
    float3 F_avg = F0 + (1.0 - F0) / 21.0;

    // Evaluate multiple scattering term
    float3 Fms = (F_avg * (1.0 - E_v) * (1.0 - E_l)) / (PI * (1.0 - F_avg * (1.0 - E_avg)) + 1e-5);

    return Fms;
}

float3 DiffuseEnergyWeight(float3 singleScatterFresnel, float3 multipleScatterBRDF) {
    return (1.0).xxx - saturate(singleScatterFresnel + PI * multipleScatterBRDF);
}

// Importance Sampling Functions

// Cosine-weighted hemisphere sampling
float3 SampleCosineHemisphere(float2 u, float3 n) {
    float r = sqrt(u.x);
    float theta = 2.0 * PI * u.y;

    float3 p = float3(r * cos(theta), r * sin(theta), sqrt(max(0.0, 1.0 - u.x)));
    n = safeNormalize(n, float3(0, 1, 0));

    // Create tangent space
    float3 up = abs(n.z) < 0.999 ? float3(0,0,1) : float3(1,0,0);
    float3 t = safeNormalize(cross(up, n), float3(1, 0, 0));
    float3 b = cross(n, t);

    return safeNormalize(p.x * t + p.y * b + p.z * n, n);
}

float PDF_CosineHemisphere(float NdotL) {
    return max(0.0, NdotL) / PI;
}

// GGX VNDF (Visible Normal Distribution Function) Sampling
// Based on Eric Heitz's "Sampling the GGX Distribution of Visible Normals"
float3 SampleGGXVNDF(float3 V, float alpha, float2 u) {
    // Transform V to hemisphere configuration
    float3 Vh = safeNormalize(float3(alpha * V.x, alpha * V.y, V.z), float3(0, 0, 1));

    // Orthonormal basis
    float lengthSq = Vh.x * Vh.x + Vh.y * Vh.y;
    float3 T1 = lengthSq > 0 ? float3(-Vh.y, Vh.x, 0) / sqrt(lengthSq) : float3(1, 0, 0);
    float3 T2 = cross(Vh, T1);

    // Parameterization of the projected area
    float r = sqrt(u.x);
    float phi = 2.0 * PI * u.y;
    float t1 = r * cos(phi);
    float t2 = r * sin(phi);
    float s = 0.5 * (1.0 + Vh.z);
    t2 = (1.0 - s) * sqrt(max(0.0, 1.0 - t1 * t1)) + s * t2;

    // Reproject onto hemisphere
    float3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2)) * Vh;

    // Transform back to ellipsoid configuration
    return safeNormalize(float3(alpha * Nh.x, alpha * Nh.y, max(0.0, Nh.z)), float3(0, 0, 1));
}

// Helper to generate Tangent Space basis
void GenerateBasis(float3 N, out float3 T, out float3 B) {
    N = safeNormalize(N, float3(0, 1, 0));
    float3 up = abs(N.z) < 0.999 ? float3(0,0,1) : float3(1,0,0);
    T = safeNormalize(cross(up, N), float3(1, 0, 0));
    B = cross(N, T);
}

// Sample GGX VNDF in world space
float3 SampleGGX(float3 V, float3 N, float roughness, float2 u) {
    float alpha = max(roughness * roughness, 0.001);

    float3 T, B;
    GenerateBasis(N, T, B);

    // Transform V to local space
    float3 Vlocal = float3(dot(V, T), dot(V, B), dot(V, N));

    // Sample local normal
    float3 Hlocal = SampleGGXVNDF(Vlocal, alpha, u);

    // Transform H back to world space
    float3 H = safeNormalize(Hlocal.x * T + Hlocal.y * B + Hlocal.z * N, N);

    // Reflect V about H
    return safeNormalize(reflect(-V, H), N);
}

// Visible GGX normal for coupled reflection and transmission sampling.
float3 SampleGGXMicrofacetNormal(float3 V, float3 N, float roughness, float2 u) {
    float alpha = max(roughness * roughness, 0.001);

    float3 T, B;
    GenerateBasis(N, T, B);

    float3 Vlocal = float3(dot(V, T), dot(V, B), dot(V, N));
    float3 Hlocal = SampleGGXVNDF(Vlocal, alpha, u);
    float3 H = safeNormalize(Hlocal.x * T + Hlocal.y * B + Hlocal.z * N, N);
    return dot(H, V) >= 0.0 ? H : -H;
}

// PDF for GGX VNDF sampling of the half vector
float PDF_GGXVNDF(float NdotV, float NdotH, float VdotH, float roughness) {
    float D = D_GGX(NdotH, roughness);
    float G1 = G1_SmithGGX(NdotV, roughness);

    return (D * G1 * max(0.0, VdotH)) / max(NdotV, 0.00001);
}

// PDF for standard GGX reflection
float PDF_GGX_Reflection(float NdotV, float NdotH, float VdotH, float roughness) {
    // The PDF of the visible half vector is: D * G1 * max(0, VdotH) / NdotV
    // To convert this to the PDF of the reflected direction, we divide by (4 * VdotH)
    return PDF_GGXVNDF(NdotV, NdotH, VdotH, roughness) / (4.0 * max(VdotH, 0.0001));
}

#endif
