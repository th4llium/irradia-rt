$input v_texcoord0

#include "../../include/bgfx_shader.sh"

/*
Macros:
TONE_MAPPING_PASS
*/

uniform vec4 RenderMode;
uniform vec4 ScreenSize;
uniform vec4 gBloomMultiplier;
uniform vec4 gColorGradingEnabled;
uniform vec4 gPerformSRGBConversion;
uniform vec4 gToneMappingColorBalance;
uniform vec4 gToneMappingContrast;
uniform vec4 gToneMappingDebugMode;
uniform vec4 gToneMappingFilmicSaturationCorrection;
uniform vec4 gToneMappingGamma;
uniform vec4 gToneMappingIntensity;
uniform vec4 gToneMappingSaturation;
uniform vec4 gToneMappingShadowContrast;
uniform vec4 gToneMappingShadowContrastEnd;

vec4 ViewRect;
mat4 Proj;
mat4 View;
vec4 ViewTexel;
mat4 InvView;
mat4 InvProj;
mat4 ViewProj;
mat4 InvViewProj;
mat4 PrevViewProj;
mat4 WorldArray[4];
mat4 World;
mat4 WorldView;
mat4 WorldViewProj;
vec4 PrevWorldPosOffset;
vec4 AlphaRef4;
float AlphaRef;

struct FragmentInput {
    vec2 texcoord0;
};

struct FragmentOutput {
    vec4 Color0;
};

SAMPLER2D_AUTOREG(s_RasterColor);
SAMPLER2D_AUTOREG(s_gBloomBuffer);
SAMPLER2D_AUTOREG(s_gRasterizedInput);
SAMPLER2D_AUTOREG(s_gToneCurve);

// FXAA from XorDev, source: https://github.com/XorDev/GM_FXAA
// AgX Minimal from bwsrench, source: https://www.shadertoy.com/view/cd3XWr

vec4 fromLinear(vec4 linearRGB) {
    bvec4 cutoff = lessThan(linearRGB, vec4(0.0031308, 0.0031308, 0.0031308, 0.0031308));
    vec4 higher = vec4(1.055, 1.055, 1.055, 1.055)*pow(linearRGB, vec4(1.0/2.4, 1.0/2.4, 1.0/2.4, 1.0/2.4)) - vec4(0.055, 0.055, 0.055, 0.055);
    vec4 lower = linearRGB * vec4(12.92, 12.92, 12.92, 12.92);
    return mix(higher, lower, cutoff);
}

vec3 agxDefaultContrastApprox(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;
    return + 15.5     * x4 * x2
           - 40.14    * x4 * x
           + 31.96    * x4
           - 6.868    * x2 * x
           + 0.4298   * x2
           + 0.1191   * x
           - 0.00232;
}

vec3 agx(vec3 val) {
    const mat3 agx_mat = mat3(
        0.842479062253094, 0.0423282422610123, 0.0423756549057051,
        0.0784335999999992,  0.878468636469772,  0.0784336,
        0.0792237451477643, 0.0791661274605434, 0.879142973793104);
    
    const float min_ev = -12.47393;
    const float max_ev = 4.026069;

    val = mul(agx_mat, val);
    val = clamp(log2(max(val, 1e-10)), min_ev, max_ev);
    val = (val - min_ev) / (max_ev - min_ev);
    val = agxDefaultContrastApprox(val);
    return val;
}

vec3 agxEotf(vec3 val) {
    const mat3 agx_mat_inv = mat3(
        1.19687900512017, -0.0528968517574562, -0.0529716355144438,
        -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
        -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
    val = mul(agx_mat_inv, val);
    return val;
}

vec3 agxLook(vec3 val) {  
    vec3 offset = vec3(0.0, 0.0, 0.0);
    vec3 slope = vec3(1.0, 1.0, 1.0);
    vec3 power = vec3(1.35, 1.35, 1.35);
    float sat = 1.4;
    
    val = pow(max(val * slope + offset, 0.0), power);
    const vec3 lw = vec3(0.2126, 0.7152, 0.0722);
    float luma = dot(val, lw);
    return luma + sat * (val - luma);
}

vec3 tex(vec2 uv) {
    vec4 rasterColor = texture2D(s_RasterColor, uv);
    vec4 bloomColor = texture2D(s_gBloomBuffer, uv);

    vec3 color = bloomColor.rgb * gBloomMultiplier.rgb + rasterColor.rgb;
    color = max(color, 0.0);
    
    color = agx(color);
    color = agxLook(color);
    color = agxEotf(color);
    
    return fromLinear(vec4(color, 1.0)).rgb;
}

vec3 fxaa(vec2 uv) {
    const float span_max    = 8.0;
    const float reduce_min  = 0.0078125;
    const float reduce_mul  = 0.03125;
    const vec3  luma        = vec3(0.299, 0.587, 0.114);

    vec2 texelSz = vec2(1.0 / ScreenSize.x, 1.0 / ScreenSize.y);

    vec3 rgbCC = tex(uv);
    vec3 rgb00 = tex(uv + vec2(-0.5, -0.5) * texelSz);
    vec3 rgb10 = tex(uv + vec2( 0.5, -0.5) * texelSz);
    vec3 rgb01 = tex(uv + vec2(-0.5,  0.5) * texelSz);
    vec3 rgb11 = tex(uv + vec2( 0.5,  0.5) * texelSz);

    float lumaCC = dot(rgbCC, luma);
    float luma00 = dot(rgb00, luma);
    float luma10 = dot(rgb10, luma);
    float luma01 = dot(rgb01, luma);
    float luma11 = dot(rgb11, luma);

    vec2 dir = vec2((luma01 + luma11) - (luma00 + luma10), (luma00 + luma01) - (luma10 + luma11));
    float dirReduce = max((luma00 + luma10 + luma01 + luma11) * reduce_mul, reduce_min);
    float rcpDir = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);

    dir = min(vec2(span_max, span_max), max(vec2(-span_max, -span_max), dir * rcpDir)) * texelSz.xy;

    vec3 A = 0.5 * (
        tex(uv - dir * 0.166667)
      + tex(uv + dir * 0.166667)
      );

    vec3 B = A * 0.5 + 0.25 * (
        tex(uv - dir * 0.5)
      + tex(uv + dir * 0.5)
      );

    float lumaMin = min(lumaCC, min(min(luma00, luma10), min(luma01, luma11)));
    float lumaMax = max(lumaCC, max(max(luma00, luma10), max(luma01, luma11)));
    float lumaB = dot(B, luma);

    return ((lumaB < lumaMin) || (lumaB > lumaMax)) ? A : B;
}

void Frag(FragmentInput fragInput, inout FragmentOutput fragOutput) {
    vec3 color = fxaa(fragInput.texcoord0);
    
    uint var6 = (uint(abs(ScreenSize.x * fragInput.texcoord0.x)) << 16u) + uint(abs(ScreenSize.y * fragInput.texcoord0.y));
    uint var7 = ((var6 ^ 61u) ^ (var6 >> 16u)) * 9u;
    uint var8 = ((var7 >> 4u) ^ var7) * 668265261u;
    float var9 = (1.0 / 510.0) - (float((var8 >> 15u) ^ var8) * 1.826122803319507603703186759958e-12);
    
    vec4 rasterizedInput = texture2D(s_gRasterizedInput, fragInput.texcoord0);
    float alpha = 1.0 - rasterizedInput.w;

    fragOutput.Color0 = vec4(rasterizedInput.rgb + ((var9 + color) * alpha), 1.0);
}

void main() {
    FragmentInput fragmentInput;
    FragmentOutput fragmentOutput;
    fragmentInput.texcoord0 = v_texcoord0;
    fragmentOutput.Color0 = vec4(0, 0, 0, 0);
    ViewRect = u_viewRect;
    Proj = u_proj;
    View = u_view;
    ViewTexel = u_viewTexel;
    InvView = u_invView;
    InvProj = u_invProj;
    ViewProj = u_viewProj;
    InvViewProj = u_invViewProj;
    PrevViewProj = u_prevViewProj;
    {
        WorldArray[0] = u_model[0];
        WorldArray[1] = u_model[1];
        WorldArray[2] = u_model[2];
        WorldArray[3] = u_model[3];
    }
    World = u_model[0];
    WorldView = u_modelView;
    WorldViewProj = u_modelViewProj;
    PrevWorldPosOffset = u_prevWorldPosOffset;
    AlphaRef4 = u_alphaRef4;
    AlphaRef = u_alphaRef4.x;
    Frag(fragmentInput, fragmentOutput);
    gl_FragColor = fragmentOutput.Color0;
}

