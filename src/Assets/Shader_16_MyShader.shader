Shader "Custom/Shader_16_MyShader"
{
    Properties
    {
        [MainColor] _BaseColor("Base Color", Color) = (0.86, 0.39, 0.39, 1)
        [MainTexture] _BaseMap("Base Map", 2D) = "white" {}
        _SpecularColor("Specular Color", Color) = (1, 1, 1, 1)
        _Emission("Emission", Color) = (0, 0, 0, 0)
        _Fresnel0("Fresnel0", Range(0, 1)) = 0.8
        _RoughnessX("Roughness X", Range(0.01, 1)) = 0.2
        _RoughnessY("Roughness Y", Range(0.01, 1)) = 0.8
        _Metallic("Metallic", Range(0, 1)) = 0.6
        // 布用のパラメータ
        _SheenColor("Sheen Color", Color) = (1, 1, 1, 1)
        _SheenRoughness("Sheen Roughness", Range(0.01, 1)) = 0.5
        _Cloth("Cloth", Range(0, 1)) = 0
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" }

        Pass
        {
            HLSLPROGRAM

            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normal : NORMAL;
                float4 tangent : TANGENT;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float3 normal : NORMAL;
                float4 tangent : TANGENT;
                float3 position : TEXCOORD0;
                float2 uv : TEXCOORD1;
            };

            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);

            CBUFFER_START(UnityPerMaterial)
                half4 _BaseColor;
                float4 _BaseMap_ST;
                half4 _SpecularColor;
                half4 _Emission;
                half _Fresnel0;
                half _RoughnessX;
                half _RoughnessY;
                half _Metallic;
                half4 _SheenColor;
                half _SheenRoughness;
                half _Cloth;
            CBUFFER_END

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionHCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.normal = TransformObjectToWorldNormal(IN.normal);
                // 接ベクトルは向きだけ変換すればいいのでDirを使う
                OUT.tangent = float4(TransformObjectToWorldDir(IN.tangent.xyz), IN.tangent.w);
                OUT.position = TransformObjectToWorld(IN.positionOS.xyz);
                OUT.uv = TRANSFORM_TEX(IN.uv, _BaseMap);
                return OUT;
            }

            half Fresnel(half f0, half f90, float co)
            {
                return f0 + (f90 - f0) * pow(1 - co, 5);// Schlick近似
            }

            // "Moving Frostbite to Physically Based Rendering 3.0"
            half3 Fr_DisneyDiffuse(half3 albedo, half LdotN, half VdotN, half LdotH, half linearRoughness)
            {
                half energyBias = lerp(0.0, 0.5, linearRoughness);
                half energyFactor = lerp(1.0, 1.0 / 1.51, linearRoughness);
                half Fd90 = energyBias + 2.0 * LdotH * LdotH * linearRoughness;
                half FL = Fresnel(1, Fd90, LdotN);
                half FV = Fresnel(1, Fd90, VdotN);
                return (albedo * FL * FV * energyFactor);
            }

            // 異方性GGXの分布関数（接方向ごとにαを変える）
            float D_GGXAnisotropic(float XdotH, float YdotH, float HdotN, float alphaX, float alphaY)
            {
                float x = XdotH / alphaX;
                float y = YdotH / alphaY;
                float d = x * x + y * y + HdotN * HdotN;
                return 1 / (PI * alphaX * alphaY * d * d);
            }

            // 異方性版のSmith GGX Correlated（4(N・L)(N・V)で割った後の値を返す）
            float V_SmithGGXCorrelatedAnisotropic(float XdotV, float YdotV, float VdotN,
                float XdotL, float YdotL, float LdotN, float alphaX, float alphaY)
            {
                float lambdaV = LdotN * length(float3(alphaX * XdotV, alphaY * YdotV, VdotN));
                float lambdaL = VdotN * length(float3(alphaX * XdotL, alphaY * YdotL, LdotN));
                return 0.5 / (lambdaV + lambdaL);
            }

            // 布用：Charlieシーン分布（Estevez & Kulla 2017）
            // 法線から離れた向きのマイクロファセット（繊維）ほど多いモデル
            float D_CharlieSheen(float roughness, float HdotN)
            {
                float invAlpha = 1 / roughness;
                float cos2h = HdotN * HdotN;
                float sin2h = max(1 - cos2h, 0.0078125);// 0になるのを防ぐ
                return (2 + invAlpha) * pow(sin2h, invAlpha * 0.5) / (2 * PI);
            }

            // 布用：Neubeltの可視関数（こちらも4(N・L)(N・V)で割った後の値）
            float V_Neubelt(float LdotN, float VdotN)
            {
                return 1 / (4 * (LdotN + VdotN - LdotN * VdotN));
            }

            half4 frag(Varyings IN) : SV_Target
            {
                half3 normal = normalize(IN.normal);// 滑らかにするために正規化し直す
                half3 binormal = normalize(cross(normal, IN.tangent.xyz) * IN.tangent.w);
                half3 tangent = cross(binormal, normal) * IN.tangent.w;

                Light light = GetMainLight();
                half3 view_direction = normalize(TransformViewToWorld(float3(0, 0, 0)) - IN.position);
                half3 half_vector = normalize(light.direction + view_direction);
                half VdotN = max(0.00001, dot(view_direction, normal));
                half LdotN = max(0.0, dot(light.direction, normal));
                half HdotN = max(0.0, dot(half_vector, normal));
                half LdotH = max(0.0, dot(half_vector, light.direction));
                half VdotH = max(0.0, dot(half_vector, view_direction));

                // テクスチャの色
                half3 albedo = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv).rgb * _BaseColor.rgb;

                // 拡散反射（Frostbite）：粗さは2方向の平均を使う
                half alphaX = _RoughnessX * _RoughnessX;
                half alphaY = _RoughnessY * _RoughnessY;
                half3 diffuse = Fr_DisneyDiffuse(albedo, LdotN, VdotN, LdotH, (alphaX + alphaY) * 0.5) / PI;

                // 鏡面反射（異方性GGX）
                float D = D_GGXAnisotropic(dot(tangent, half_vector), dot(binormal, half_vector), HdotN, alphaX, alphaY);
                float V = V_SmithGGXCorrelatedAnisotropic(
                    dot(tangent, view_direction), dot(binormal, view_direction), VdotN,
                    dot(tangent, light.direction), dot(binormal, light.direction), LdotN,
                    alphaX, alphaY);
                half F = Fresnel(_Fresnel0, 1, VdotH);
                half3 specular = _SpecularColor.rgb * D * V * F;// Vに4(N・L)(N・V)の割り算が入っている

                // 布（シーン）：拡散反射＋縁が光る反射
                half3 sheen = _SheenColor.rgb * D_CharlieSheen(_SheenRoughness, HdotN) * V_Neubelt(LdotN, VdotN);
                half3 cloth = diffuse + sheen;

                half3 pbr = lerp(diffuse, specular, _Metallic);
                half3 color = light.color * LdotN * lerp(pbr, cloth, _Cloth);
                color += _Emission.rgb;// 発光
                return half4(color, 1);
            }
            ENDHLSL
        }
    }
}
