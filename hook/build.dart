import 'package:flutter_gpu_shaders/build.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (config, output) async {
    await buildShaderBundleJson(buildInput: config, buildOutput: output, manifestFileName: 'ibl_repro.shaderbundle.json');
  });
}
