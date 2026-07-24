enum IblLayout {
  cubemapMip,
  radianceAtlas;

  bool get isMipMapped => this == IblLayout.cubemapMip;

  String get label => switch (this) {
    IblLayout.cubemapMip => 'Cubemap mip chain',
    IblLayout.radianceAtlas => 'Radiance atlas',
  };
}

class IblSamplingPlan {
  const IblSamplingPlan({required this.bandCount}) : assert(bandCount > 1);

  final int bandCount;

  double bandForRoughness(double roughness) {
    return roughness.clamp(0.0, 1.0) * (bandCount - 1);
  }

  int lowerBandForRoughness(double roughness) {
    return bandForRoughness(roughness).floor();
  }
}
