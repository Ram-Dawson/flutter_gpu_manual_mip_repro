import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:ibl_gpu_repro/ibl_layout.dart';
import 'package:vector_math/vector_math.dart' as vm;

const _shaderBundle = 'build/shaderbundles/ibl_repro.shaderbundle';

void main() {
  runApp(const IblGpuReproApp());
}

class IblGpuReproApp extends StatelessWidget {
  const IblGpuReproApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter GPU IBL repro',
      theme: ThemeData(colorSchemeSeed: const Color(0xff006d77), useMaterial3: true),
      home: const IblGpuReproPage(),
    );
  }
}

class IblGpuReproPage extends StatefulWidget {
  const IblGpuReproPage({super.key});

  @override
  State<IblGpuReproPage> createState() => _IblGpuReproPageState();
}

class _IblGpuReproPageState extends State<IblGpuReproPage> {
  final _renderer = _IblGpuRenderer();
  IblLayout _layout = IblLayout.cubemapMip;
  double _roughness = 0.45;
  bool _lodColorProbe = false;
  ui.Image? _image;
  String? _error;
  bool _rendering = false;

  @override
  void initState() {
    super.initState();
    _render();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _render() async {
    if (_rendering) return;
    setState(() {
      _rendering = true;
      _error = null;
    });
    try {
      final image = await _renderer.render(layout: _layout, roughness: _roughness, lodColorProbe: _lodColorProbe);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
        _rendering = false;
      });
    } catch (error, stackTrace) {
      if (mounted) {
        setState(() {
          _error = '$error\n$stackTrace';
          _rendering = false;
        });
      }
    }
  }

  void _selectLayout(IblLayout layout) {
    setState(() => _layout = layout);
    _render();
  }

  void _selectRoughness(double roughness) {
    setState(() => _roughness = roughness);
    _render();
  }

  void _setLodColorProbe(bool enabled) {
    setState(() => _lodColorProbe = enabled);
    _render();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      appBar: AppBar(title: const Text('Flutter GPU IBL repro')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: image != null
                      ? RawImage(image: image, fit: BoxFit.contain)
                      : _error != null
                      ? Padding(padding: const EdgeInsets.all(16), child: SingleChildScrollView(child: Text(_error!, style: const TextStyle(color: Colors.red))))
                      : const CircularProgressIndicator(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<IblLayout>(
                    segments: IblLayout.values.map((layout) => ButtonSegment(value: layout, label: SizedBox(height: 48, child: Center(child: Text(layout.label, maxLines: 2, textAlign: TextAlign.center))))).toList(),
                    selected: {_layout},
                    onSelectionChanged: _rendering ? null : (selection) => _selectLayout(selection.first),
                  ),
                  const SizedBox(height: 12),
                  Text('Roughness ${_roughness.toStringAsFixed(2)}'),
                  Slider(value: _roughness, onChanged: _rendering ? null : _selectRoughness),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('LOD color probe'),
                    subtitle: Text('Requested lower band: ${_renderer.lowerBandForRoughness(_roughness)}'),
                    value: _lodColorProbe,
                    onChanged: _rendering ? null : _setLodColorProbe,
                  ),
                  Text('Manual mip chains: ${gpu.gpuContext.doesSupportManuallyMippedTextures} | Mip render targets: ${gpu.gpuContext.doesSupportFramebufferRenderMipmap}', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IblGpuRenderer {
  static const _size = 256;
  static const _bandCount = 8;
  static const _outputSize = 512;
  final _plan = const IblSamplingPlan(bandCount: _bandCount);
  gpu.Texture? _cube;
  gpu.Texture? _atlas;
  gpu.Texture? _probeCube;
  gpu.Texture? _probeAtlas;
  gpu.RenderPipeline? _pipeline;
  gpu.Shader? _fragment;
  gpu.DeviceBuffer? _vertexBuffer;

  int lowerBandForRoughness(double roughness) => _plan.lowerBandForRoughness(roughness);

  Future<ui.Image> render({required IblLayout layout, required double roughness, required bool lodColorProbe}) async {
    await _initialize();
    final fragment = _fragment!;
    final output = gpu.gpuContext.createTexture(gpu.StorageMode.devicePrivate, _outputSize, _outputSize);
    final uniformSlot = fragment.getUniformSlot('IblInfo');
    final sampledRoughness = _plan.bandForRoughness(roughness) / (_bandCount - 1);
    final uniform = ByteData(uniformSlot.sizeInBytes!);
    uniform.setFloat32(uniformSlot.getMemberOffsetInBytes('roughness')!, sampledRoughness, Endian.host);
    uniform.setFloat32(uniformSlot.getMemberOffsetInBytes('use_cubemap_mips')!, layout.isMipMapped ? 1 : 0, Endian.host);
    final hostBuffer = gpu.gpuContext.createHostBuffer();
    final commandBuffer = gpu.gpuContext.createCommandBuffer();
    final pass = commandBuffer.createRenderPass(gpu.RenderTarget.singleColor(gpu.ColorAttachment(texture: output, loadAction: gpu.LoadAction.clear, clearValue: vm.Vector4(0.025, 0.035, 0.055, 1))));
    pass.bindPipeline(_pipeline!);
    pass.bindVertexBuffer(gpu.BufferView(_vertexBuffer!, offsetInBytes: 0, lengthInBytes: 6 * 4 * 4));
    pass.bindUniform(uniformSlot, hostBuffer.emplace(uniform));
    final sampler = gpu.SamplerOptions(mipFilter: gpu.MipFilter.linear);
    pass.bindTexture(fragment.getUniformSlot('radiance_cube'), lodColorProbe ? _probeCube! : _cube!, sampler: sampler);
    pass.bindTexture(fragment.getUniformSlot('radiance_atlas'), lodColorProbe ? _probeAtlas! : _atlas!, sampler: sampler);
    pass.setViewport(gpu.Viewport(x: 0, y: 0, width: _outputSize, height: _outputSize));
    pass.draw(6);
    pass.clearBindings();
    commandBuffer.submit();
    return output.asImage();
  }

  Future<void> _initialize() async {
    if (_pipeline != null) return;
    final library = await gpu.ShaderLibrary.fromAsset(_shaderBundle);
    final vertex = library?['ReproVertex'];
    final fragment = library?['ReproFragment'];
    if (vertex == null || fragment == null) throw StateError('Missing repro shaders in $_shaderBundle');
    _fragment = fragment;
    _pipeline = gpu.gpuContext.createRenderPipeline(vertex, fragment, vertexLayout: const gpu.VertexLayout(buffers: [gpu.VertexBuffer(strideInBytes: 16, attributes: [gpu.VertexAttribute(name: 'position', format: gpu.VertexFormat.float32x2), gpu.VertexAttribute(name: 'uv', format: gpu.VertexFormat.float32x2, offsetInBytes: 8)])]));
    final vertices = Float32List.fromList([-1, -1, 0, 0, 1, -1, 1, 0, 1, 1, 1, 1, -1, -1, 0, 0, 1, 1, 1, 1, -1, 1, 0, 1]);
    _vertexBuffer = gpu.gpuContext.createDeviceBufferWithCopy(ByteData.sublistView(vertices));
    _cube = _createCube(diagnostic: false);
    _atlas = _createAtlas(diagnostic: false);
    _probeCube = _createCube(diagnostic: true);
    _probeAtlas = _createAtlas(diagnostic: true);
  }

  gpu.Texture _createCube({required bool diagnostic}) {
    final texture = gpu.gpuContext.createTexture(gpu.StorageMode.hostVisible, _size, _size, textureType: gpu.TextureType.textureCube, enableRenderTargetUsage: false, mipLevelCount: _bandCount);
    for (var level = 0; level < _bandCount; level++) {
      for (var face = 0; face < 6; face++) {
        texture.overwrite(ByteData.sublistView(_cubePixels(face, level, texture.getMipLevelWidth(level), diagnostic: diagnostic)), mipLevel: level, slice: face);
      }
    }
    return texture;
  }

  gpu.Texture _createAtlas({required bool diagnostic}) {
    const atlasWidth = 256;
    final texture = gpu.gpuContext.createTexture(gpu.StorageMode.hostVisible, atlasWidth, atlasWidth * _bandCount, enableRenderTargetUsage: false);
    final bytes = Uint8List(atlasWidth * atlasWidth * _bandCount * 4);
    for (var band = 0; band < _bandCount; band++) {
      for (var y = 0; y < atlasWidth; y++) {
        for (var x = 0; x < atlasWidth; x++) {
          final direction = _equirectDirection(x / (atlasWidth - 1), y / (atlasWidth - 1));
          final offset = ((band * atlasWidth + y) * atlasWidth + x) * 4;
          if (diagnostic) {
            _writeProbeColor(bytes, offset, band);
          } else {
            _writeColor(bytes, offset, direction, band / (_bandCount - 1));
          }
        }
      }
    }
    texture.overwrite(ByteData.sublistView(bytes));
    return texture;
  }

  Uint8List _cubePixels(int face, int level, int size, {required bool diagnostic}) {
    final bytes = Uint8List(size * size * 4);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final offset = (y * size + x) * 4;
        if (diagnostic) {
          _writeProbeColor(bytes, offset, level);
        } else {
          _writeColor(bytes, offset, _cubeDirection(face, x / (size - 1), y / (size - 1)), level / (_bandCount - 1));
        }
      }
    }
    return bytes;
  }

  void _writeColor(Uint8List bytes, int offset, vm.Vector3 direction, double roughness) {
    final highlight = direction.z <= 0 ? 0.0 : math.pow(direction.z, 48 - roughness * 43).toDouble();
    final horizon = 0.08 + 0.12 * (direction.y * 0.5 + 0.5);
    final blur = 0.3 + roughness * 0.7;
    bytes[offset] = ((horizon + highlight * 3.5 * blur).clamp(0, 1) * 255).round();
    bytes[offset + 1] = ((horizon * 1.1 + highlight * 1.3 * blur).clamp(0, 1) * 255).round();
    bytes[offset + 2] = ((horizon * 1.5 + highlight * 0.35 * blur).clamp(0, 1) * 255).round();
    bytes[offset + 3] = 255;
  }

  void _writeProbeColor(Uint8List bytes, int offset, int band) {
    const colors = <List<int>>[[255, 28, 28], [255, 125, 0], [255, 228, 0], [0, 210, 65], [0, 205, 215], [30, 100, 255], [175, 60, 255], [245, 245, 245]];
    final color = colors[band];
    bytes[offset] = color[0];
    bytes[offset + 1] = color[1];
    bytes[offset + 2] = color[2];
    bytes[offset + 3] = 255;
  }

  vm.Vector3 _cubeDirection(int face, double u, double v) {
    final x = u * 2 - 1;
    final y = v * 2 - 1;
    final direction = switch (face) { 0 => vm.Vector3(1, -y, -x), 1 => vm.Vector3(-1, -y, x), 2 => vm.Vector3(x, 1, y), 3 => vm.Vector3(x, -1, -y), 4 => vm.Vector3(x, -y, 1), _ => vm.Vector3(-x, -y, -1) };
    return direction.normalized();
  }

  vm.Vector3 _equirectDirection(double u, double v) {
    final longitude = (u - 0.5) * 2 * 3.14159265359;
    final latitude = (v - 0.5) * 3.14159265359;
    final cosLatitude = math.cos(latitude);
    return vm.Vector3(cosLatitude * math.cos(longitude), math.sin(latitude), cosLatitude * math.sin(longitude));
  }
}
