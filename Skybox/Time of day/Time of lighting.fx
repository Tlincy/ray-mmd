#include "../../ray.conf"
#include "../../ray_advanced.conf"
#include "../../shader/math.fxsub"
#include "../../shader/common.fxsub"
#include "../../shader/gbuffer.fxsub"
#include "../../shader/gbuffer_sampler.fxsub"
#include "../../shader/ibl.fxsub"

#include "shader/stars.fxsub"
#include "shader/cloud.fxsub"
#include "shader/atmospheric.fxsub"

float3 LightSpecular : SPECULAR< string Object = "Light";>;
float3 LightDirection : DIRECTION< string Object = "Light";>;

float4 ScatteringPS(in float3 viewdir : TEXCOORD0, in float4 texcoord : TEXCOORD1)
{
	//float2 coord = texcoord.xy / texcoord.w;
	//coord = PosToCoord(coord);
	//coord += ViewportOffset;
	//float3 V = ComputeSphereNormal(coord);
	
	float scaling = 1000;
	
	ScatteringParams setting;
	setting.sunSize = 0.99;
	setting.sunRadiance = 10.0;
	setting.mieG = 0.76;
	setting.mieHeight = 1.2 * scaling;
	setting.mieCoefficient = 1.0;
	setting.rayleighHeight = 7.994 * scaling;
	setting.rayleighCoefficient = 1.0;
	setting.earthRadius = 6360 * scaling;
	setting.earthAtmTopRadius = 6380 * scaling;
	setting.earthCenter = float3(0, -6361, 0) * scaling;
	setting.waveLambdaMie = 2e-5;
	setting.waveLambdaRayleigh = float3(5.8e-6, 13.5e-6, 33.1e-6);
	setting.cloud = 0.6;
	setting.cloudBias = time / 20;
	setting.clouddir = float3(0, 0, -time * 3e+3);

	float3 V = normalize(viewdir);
	float4 insctrColor = ComputeUnshadowedInscattering(setting, CameraPosition, V, LightDirection);
	return insctrColor;
}

void ShadingMaterial(MaterialParam material, float3 worldView, out float3 diffuse, out float3 specular)
{
	float3 worldNormal = mul(material.normal, (float3x3)matViewInverse);
	float3 worldReflect = EnvironmentReflect(worldNormal, worldView);
	
	float3 L = mul(normalize(-LightDirection), (float3x3)matView);
	
	float zenithFactor = saturate(-LightDirection.y);
		
	float3 ambientColor;
	ambientColor.r = zenithFactor * 0.15f;
	ambientColor.g = zenithFactor * 0.10f;
	ambientColor.b = max(0.05f, zenithFactor * 0.25f);
	ambientColor = saturate(ambientColor * 10);
	
	float nl = saturate(dot(material.normal, L) * 0.5 + 0.5) * 0.5;
	diffuse = 0;

	float3 fresnel = EnvironmentSpecularUnreal4(worldNormal, worldView, material.smoothness, material.specular);
	specular = ScatteringPS(worldReflect, 0.0).xyz * fresnel;
}

void EnvLightingVS(
	in float4 Position : POSITION,
	in float2 Texcoord : TEXCOORD0,
	out float4 oTexcoord : TEXCOORD0,
	out float3 oViewdir  : TEXCOORD1,
	out float4 oPosition : POSITION)
{
	oViewdir = CameraPosition - Position.xyz;
	oTexcoord = oPosition = mul(Position, matWorldViewProject);
}

void EnvLightingPS(
	in float4 texcoord : TEXCOORD0,
	in float3 viewdir  : TEXCOORD1,
	in float4 screenPosition : SV_Position,
	out float4 oColor0 : COLOR0,
	out float4 oColor1 : COLOR1)
{
	float2 coord = texcoord.xy / texcoord.w;
	coord = PosToCoord(coord);
	coord += ViewportOffset;

	float4 MRT5 = tex2Dlod(Gbuffer5Map, float4(coord, 0, 0));
	float4 MRT6 = tex2Dlod(Gbuffer6Map, float4(coord, 0, 0));
	float4 MRT7 = tex2Dlod(Gbuffer7Map, float4(coord, 0, 0));
	float4 MRT8 = tex2Dlod(Gbuffer8Map, float4(coord, 0, 0));

	MaterialParam materialAlpha;
	DecodeGbuffer(MRT5, MRT6, MRT7, MRT8, materialAlpha);
	
	float3 sum1 = materialAlpha.albedo + materialAlpha.specular;
	clip(sum(sum1) - 1e-5);
	
	float4 MRT1 = tex2Dlod(Gbuffer1Map, float4(coord, 0, 0));
	float4 MRT2 = tex2Dlod(Gbuffer2Map, float4(coord, 0, 0));
	float4 MRT3 = tex2Dlod(Gbuffer3Map, float4(coord, 0, 0));
	float4 MRT4 = tex2Dlod(Gbuffer4Map, float4(coord, 0, 0));

	MaterialParam material;
	DecodeGbuffer(MRT1, MRT2, MRT3, MRT4, material);
	
	float3 V = normalize(viewdir);
	
	float3 diffuse, specular;
	ShadingMaterial(material, V, diffuse, specular);
	
	float3 diffuse2, specular2;
	ShadingMaterial(materialAlpha, V, diffuse2, specular2);
	
	oColor0 = EncodeYcbcr(screenPosition, diffuse , specular);
	oColor1 = EncodeYcbcr(screenPosition, diffuse2, specular2);
}

const float4 BackColor = float4(0,0,0,0);
const float4 IBLColor  = float4(0,0.5,0,0.5);

shared texture EnvLightAlphaMap : RENDERCOLORTARGET;

#define OBJECT_TEC(name, mmdpass) \
	technique name < string MMDPass = mmdpass;  string Subset="0";\
	string Script = \
		"ClearSetColor=BackColor;"\
		"RenderColorTarget0=LightAlphaMap;"\
		"Clear=Color;"\
		"RenderColorTarget0=LightSpecMap;"\
		"Clear=Color;"\
		"RenderColorTarget0=;" \
		"RenderColorTarget1=EnvLightAlphaMap;" \
		"ClearSetColor=IBLColor;"\
		"Clear=Color;"\
		"Pass=DrawObject;" \
	;> { \
		pass DrawObject { \
			AlphaBlendEnable = false; AlphaTestEnable = false;\
			CullMode = CCW;\
			VertexShader = compile vs_3_0 EnvLightingVS(); \
			PixelShader  = compile ps_3_0 EnvLightingPS(); \
		} \
	}

OBJECT_TEC(MainTec0, "object")
OBJECT_TEC(MainTecBS0, "object_ss")

technique EdgeTec < string MMDPass = "edge"; > {}
technique ShadowTech < string MMDPass = "shadow";  > {}
technique ZplotTec < string MMDPass = "zplot"; > {}
technique MainTec1<string MMDPass = "object";> {}
technique MainTecBS1<string MMDPass = "object_ss";> {}