Shader "ZED/ZED Forward Lighting"
{
    Properties{
        _MaxDepth("Max Depth Range", Range(1,40)) = 40
        _DepthXYZTex("Depth texture", 2D) = "" {}
        _MainTex("Main texture", 2D) = "" {}

        // ── Перцептивные настройки ──────────────────────────────────────────────
        _ScaleX("Perceived Scale X", Range(0.8,1.2)) = 1.0
        _ScaleY("Perceived Scale Y", Range(0.8,1.2)) = 1.0
        [Toggle] _TopOnly("Squeeze From Top Only", Float) = 0
        _YOffsetUV("Vertical Offset (fraction, +down)", Range(-0.3,0.3)) = 0.10
        _YOffsetPx("Vertical Offset (pixels, +down)", Float) = 0

        // ── Края: переход и заливка ─────────────────────────────────────────────
        _EdgeFade("Edge Fade Width", Range(0,0.3)) = 0.12
        [Toggle] _SolidFill("Use Solid Color Fill", Float) = 0
        _FillColor("Fill Color", Color) = (0,0,0,1)

        // ── Альтернатива: мягкий туман (если SolidFill выключен) ────────────────
        _FogStrength("Fog Strength", Range(0,1)) = 1.0
        _FogLod("Fog Blur (Mip)", Range(0,8)) = 6.0
        _FogDesaturate("Fog Desaturate", Range(0,1)) = 0.6
        _FogUniformity("Fog Uniformity", Range(0,1)) = 0.8

        _Vignette("Vignette", Range(0,0.5)) = 0.10
    }

    SubShader
    {
        ZWrite On
        Pass
        {
            Name "FORWARD"
            Tags{ "LightMode" = "Always" }
            Cull Off

            CGPROGRAM
            #define ZEDStandard
            #pragma target 4.0
            #pragma vertex   vert_surf
            #pragma fragment frag_surf
            #pragma multi_compile_fwdbase
            #pragma multi_compile_fwdadd_fullshadows
            #pragma multi_compile __ NO_DEPTH

            #include "HLSLSupport.cginc"
            #include "UnityShaderVariables.cginc"
            #define UNITY_PASS_FORWARDBASE
            #include "UnityCG.cginc"

            #include "AutoLight.cginc"
            #include "../ZED_Utils.cginc"
            #define ZED_SPOT_LIGHT_DECLARATION
            #define ZED_POINT_LIGHT_DECLARATION
            #include "ZED_Lighting.cginc"

            sampler2D _MainTex;
            float4    _MainTex_ST;
            float4    _MainTex_TexelSize;

            sampler2D _DepthXYZTex;
            float4    _DepthXYZTex_ST;

            int    _HasShadows;
            float4 ZED_directionalLight[2];
            float  _ZEDFactorAffectReal;
            float  _MaxDepth;
            sampler2D _DirectionalShadowMap;

            // эффекты
            float _ScaleX, _ScaleY, _TopOnly;
            float _YOffsetUV, _YOffsetPx;
            float _EdgeFade, _Vignette;

            float _SolidFill;
            float4 _FillColor;

            float _FogStrength, _FogLod, _FogDesaturate, _FogUniformity;

            struct v2f_surf {
                float4 pos   : SV_POSITION;
                float4 pack0 : TEXCOORD0;
                SHADOW_COORDS(4)
                ZED_WORLD_DIR(1)
            };

            bool Unity_IsNan_float3(float3 In)
            {
                bool Out = (In < 0.0 || In > 0.0 || In == 0.0) ? 0 : 1;
                return Out;
            }

            float EdgeAmount(float2 uv)
            {
                float overX = max(0, max(uv.x-1, -uv.x));
                float overY = max(0, max(uv.y-1, -uv.y));
                return max(overX, overY);
            }

            v2f_surf vert_surf(appdata_full v)
            {
                v2f_surf o;
                UNITY_INITIALIZE_OUTPUT(v2f_surf,o);
                o.pos = UnityObjectToClipPos(v.vertex);
                ZED_TRANSFER_WORLD_DIR(o)
                o.pack0.xy = TRANSFORM_TEX(v.texcoord, _MainTex);
                o.pack0.zw = TRANSFORM_TEX(v.texcoord, _DepthXYZTex);
                o.pack0.y = 1 - o.pack0.y;
                o.pack0.w = 1 - o.pack0.w;
                TRANSFER_SHADOW(o);
                return o;
            }

            float3 Desaturate(float3 c, float k)
            {
                float g = dot(c, float3(0.299, 0.587, 0.114));
                return lerp(c, float3(g,g,g), k);
            }

            float MaxMipLevel()
            {
                float maxDim = max(_MainTex_TexelSize.z, _MainTex_TexelSize.w);
                return floor(log2(maxDim));
            }

            float4 SuperFogColor(sampler2D tex, float2 uv, float desat, float uniformity)
            {
                float maxL = MaxMipLevel();
                float2 safeUV = saturate(uv);
                float localLod = max(maxL - 1.0, 0.0);
                float4 localCol = tex2Dlod(tex, float4(safeUV, 0, localLod));
                float4 globalCol = tex2Dlod(tex, float4(0.5, 0.5, 0, maxL));
                float4 fog = lerp(localCol, globalCol, saturate(uniformity));
                fog.rgb = Desaturate(fog.rgb, desat);
                return fog;
            }

            void frag_surf(v2f_surf IN, out fixed4 outColor : SV_Target, out float outDepth : SV_Depth)
            {
                UNITY_INITIALIZE_OUTPUT(fixed4,outColor);
                float4 uv = IN.pack0;

                // depth
                float3 zed_xyz = tex2D(_DepthXYZTex, uv.zw).xxx;
                if (_MaxDepth < 40.0)
                    if (zed_xyz.z > _MaxDepth || Unity_IsNan_float3(zed_xyz.z)) discard;
                outDepth = computeDepthXYZ(zed_xyz.z);

                float2 uvColor = uv.xy;
                float totalDown = _YOffsetUV + (_YOffsetPx * _MainTex_TexelSize.y);
                uvColor.y -= totalDown;
                uvColor.x = (uvColor.x - 0.5) / _ScaleX + 0.5;
                float yTopOnly = (uvColor.y / _ScaleY);
                float yCentered = (uvColor.y - 0.5) / _ScaleY + 0.5;
                uvColor.y = lerp(yCentered, yTopOnly, saturate(_TopOnly));
                float2 uvScaled = uvColor;

                float4 colMain = tex2D(_MainTex, saturate(uvScaled)).bgra;
                float edgeAmt = EdgeAmount(uvScaled);
                float dxy = fwidth(uvScaled.x) + fwidth(uvScaled.y);
                float mixInside = smoothstep(0.0, _EdgeFade + dxy, edgeAmt);
                float outside = step(0.00001, edgeAmt);
                float mixf = max(mixInside, outside);

                // если SolidFill включён — используем просто цвет заливки
                float4 fillCol = _FillColor;

                if (_SolidFill < 0.5)
                {
                    // иначе — мягкий туман (как раньше)
                    float4 fogCol = SuperFogColor(_MainTex, uvScaled, _FogDesaturate, _FogUniformity).bgra;
                    fillCol = lerp(colMain, fogCol, _FogStrength);
                }

                // итоговое смешивание
                float4 color = lerp(colMain, fillCol, mixf);

                // виньетка
                float vign = 1.0 - smoothstep(0.45, 0.5, length(uv.xy - 0.5));
                color.rgb *= lerp(1.0, vign, _Vignette);

                // освещение
                float3 normals = tex2D(_NormalsTex, uv.zw).rgb;
                color *= _ZEDFactorAffectReal;
                float3 worldspace;
                GET_XYZ(IN, zed_xyz.x, worldspace)
                if (_HasShadows == 1)
                {
                    float atten = saturate(tex2D(_DirectionalShadowMap, float2(uv.z, 1 - uv.w))
                                           + log(1 + 1.72 * length(UNITY_LIGHTMODEL_AMBIENT.rgb) / 4.0));
                    color *= atten;
                }
                color.rgb += saturate(computeLighting(color.rgb, normals, worldspace, 1));
                color.a = 0;
                outColor.rgb = color;
            }
            ENDCG
        }
    }
    Fallback Off
}
