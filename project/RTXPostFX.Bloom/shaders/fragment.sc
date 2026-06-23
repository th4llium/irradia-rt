$input v_texcoord0

#include "../../include/bgfx_shader.sh"

/*
Macros:
BLOOM_DOWNSCALE_GAUSSIAN_PASS
BLOOM_DOWNSCALE_UNIFORM_PASS
BLOOM_FINAL_PASS
BLOOM_UPSCALE_PASS
*/

uniform vec4 RenderMode;
uniform vec4 ScreenSize;
uniform vec4 gBloomMultiplier;
uniform vec4 gViewportScale;

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
SAMPLER2D_AUTOREG(s_gBloomOriginalInput);

// MCRTX bloom pipeline passes:

// - BloomDownscaleUniformPass

// - BloomDownscaleGaussianPass
// - BloomDownscaleGaussianPass
// - BloomDownscaleGaussianPass
// - BloomDownscaleGaussianPass

// - BloomUpscalePass
// - BloomUpscalePass
// - BloomUpscalePass
// - BloomUpscalePass

// TonemapPass does the final upscaling

// Note: BloomFinalPass is not used in the game
// Bloom code from gelami. Source: https://www.shadertoy.com/view/cty3R3

float gaussian(vec2 i, float sigma) {
    return exp(-dot(i, i) / (2.0 * sigma * sigma));
}

vec4 DownscaleGaussianFilter(sampler2D tex, vec2 uv, vec2 texelSize) {
    vec4 fragColor = vec4(0.0, 0.0, 0.0, 0.0);
    int rad = 5;
    float sigma = float(rad) * 0.4;
    float w = 0.0;
    
    for (int x = -5; x <= 5; x++) {
        for (int y = -5; y <= 5; y++) {
            vec2 o = vec2(float(x), float(y));
            float wg = gaussian(o, sigma);
            vec2 p = uv + o * texelSize;
            fragColor += wg * texture2D(tex, p);
            w += wg;
        }
    }
    return fragColor / w;
}

vec4 UpscaleOptimizedFilter(sampler2D tex, vec2 uv, vec2 texelSize) {
    vec4 result = vec4(0.0, 0.0, 0.0, 0.0);
    vec2 offsets[4];
    offsets[0] = vec2(-0.333333, -0.333333);
    offsets[1] = vec2( 0.333333, -0.333333);
    offsets[2] = vec2(-0.333333,  0.333333);
    offsets[3] = vec2( 0.333333,  0.333333);
    
    for (int i = 0; i < 4; i++) {
        vec2 p = uv + offsets[i] * texelSize;
        result += texture2D(tex, p);
    }
    return result * 0.25;
}

vec4 applyDownscaleGaussianPass(FragmentInput fragInput) {
    return DownscaleGaussianFilter(s_RasterColor, fragInput.texcoord0, ViewTexel.xy);
}
vec4 applyDownscaleUniformPass(FragmentInput fragInput) {
    return DownscaleGaussianFilter(s_RasterColor, fragInput.texcoord0, ViewTexel.xy);
}
vec4 applyUpscalePass(FragmentInput fragInput) {
    return UpscaleOptimizedFilter(s_RasterColor, fragInput.texcoord0, ViewTexel.xy);
}
vec4 applyBloomFinalPass(FragmentInput fragInput) {
    return UpscaleOptimizedFilter(s_RasterColor, fragInput.texcoord0, ViewTexel.xy);
}

void Frag(FragmentInput fragInput, inout FragmentOutput fragOutput) {
    #ifdef BLOOM_DOWNSCALE_GAUSSIAN_PASS
    fragOutput.Color0 = applyDownscaleGaussianPass(fragInput);
    #endif
    #ifdef BLOOM_DOWNSCALE_UNIFORM_PASS
    fragOutput.Color0 = applyDownscaleUniformPass(fragInput);
    #endif
    #ifdef BLOOM_UPSCALE_PASS
    fragOutput.Color0 = applyUpscalePass(fragInput);
    #endif
    #ifdef BLOOM_FINAL_PASS
    fragOutput.Color0 = applyBloomFinalPass(fragInput);
    #endif
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

