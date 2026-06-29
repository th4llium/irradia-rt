#include "Include/Generated/Signature.hlsl"

[numthreads(16, 16, 1)]
void ReprojectSpecularOnly(
    uint3 dispatchThreadID : SV_DispatchThreadID,
    uint3 groupThreadID : SV_GroupThreadID,
    uint groupIndex : SV_GroupIndex, 
    uint3 groupID : SV_GroupID
    )
{
    uint diffuseOutputIndex = (g_rootConstant0 >> 8) & 0xff;
    uint specularOutputIndex = (g_rootConstant0 >> 16) & 0xff;

    bool useVarianceWeightDiffuse = g_rootConstant0 & 1;
    bool useVarianceWeightSpecular = g_rootConstant0 & 2;
}
