import 'package:flutter_test/flutter_test.dart';
import 'package:ibl_gpu_repro/ibl_layout.dart';

void main() {
  test('keeps cubemap-mip and atlas repro modes distinguishable', () {
    expect(IblLayout.cubemapMip.isMipMapped, isTrue);
    expect(IblLayout.radianceAtlas.isMipMapped, isFalse);
  });

  test('maps endpoint roughness to the first and last radiance band', () {
    const plan = IblSamplingPlan(bandCount: 8);

    expect(plan.bandForRoughness(0), 0);
    expect(plan.bandForRoughness(1), 7);
    expect(plan.bandForRoughness(0.5), 3.5);
  });

  test('uses the lower adjacent band as a stable LOD probe label', () {
    const plan = IblSamplingPlan(bandCount: 8);

    expect(plan.lowerBandForRoughness(0.45), 3);
    expect(plan.lowerBandForRoughness(1), 7);
  });
}
