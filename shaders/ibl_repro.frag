precision highp float;

uniform samplerCube radiance_cube;
uniform sampler2D radiance_atlas;

uniform IblInfo {
  float roughness;
  float use_cubemap_mips;
} ibl_info;

in vec2 v_uv;
out vec4 frag_color;

const float kBandCount = 8.0;

vec2 sphericalToEquirectangular(vec3 direction) {
  vec2 uv = vec2(atan(direction.z, direction.x), asin(direction.y));
  return uv * vec2(0.15915494309, 0.31830988618) + 0.5;
}

vec3 sampleAtlas(vec3 direction, float roughness) {
  vec2 uv = sphericalToEquirectangular(direction);
  float band = clamp(roughness, 0.0, 1.0) * (kBandCount - 1.0);
  float lower = floor(band);
  float upper = min(lower + 1.0, kBandCount - 1.0);
  float mixAmount = band - lower;
  vec3 a = texture(radiance_atlas, vec2(uv.x, (lower + uv.y) / kBandCount)).rgb;
  vec3 b = texture(radiance_atlas, vec2(uv.x, (upper + uv.y) / kBandCount)).rgb;
  return mix(a, b, mixAmount);
}

void main() {
  vec2 p = v_uv * 2.0 - 1.0;
  float r2 = dot(p, p);
  if (r2 > 1.0) {
    frag_color = vec4(0.025, 0.035, 0.055, 1.0);
    return;
  }
  vec3 normal = normalize(vec3(p.x, -p.y, sqrt(1.0 - r2)));
  vec3 reflection = reflect(vec3(0.0, 0.0, -1.0), normal);
  float lod = clamp(ibl_info.roughness, 0.0, 1.0) * (kBandCount - 1.0);
  vec3 radiance = ibl_info.use_cubemap_mips > 0.5 ? textureLod(radiance_cube, reflection, lod).rgb : sampleAtlas(reflection, ibl_info.roughness);
  float fresnel = 0.04 + 0.96 * pow(1.0 - max(normal.z, 0.0), 5.0);
  vec3 reflected = radiance * (0.55 + 0.45 * fresnel);
  frag_color = vec4(reflected / (reflected + vec3(1.0)), 1.0);
}
