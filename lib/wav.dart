// Copyright 2022 The wav authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:typed_data';
import 'wav_no_io.dart' if (dart.library.io) 'wav_io.dart';

/// The supported WAV formats.
enum WavFormat {
  /// 8-bit PCM.
  pcm8bit,

  /// 16-bit PCM.
  pcm16bit,

  /// 24-bit PCM.
  pcm24bit,

  /// 32-bit PCM.
  pcm32bit,

  /// 32-bit float.
  float32,

  /// 64-bit float.
  float64,
}

/// A WAV file, containing audio, and metadata.
class Wav {
  /// Audio data, as a list of channels.
  ///
  /// In the typical stereo case the channels will be `[left, right]`.
  ///
  /// The audio samples are in the range `[-1, 1]`.
  final List<Float64List> channels;

  /// The sampling frequency of the audio data, in Hz.
  final int samplesPerSecond;

  /// The format of the WAV file.
  final WavFormat format;

  /// Constructs a Wav directly from audio data.
  Wav(
    this.channels,
    this.samplesPerSecond, [
    this.format = WavFormat.pcm16bit,
  ]);

  /// Read a Wav from a file.
  ///
  /// Convenience wrapper around [read]. See that method for details.
  static Future<Wav> readFile(String filename) async {
    return read(await internalReadFile(filename));
  }

  /// Returns the duration of the Wav in seconds.
  double get duration =>
      channels.isEmpty ? 0 : channels[0].length / samplesPerSecond;

  static const _kFormatSize = 16;
  static const _kFactSize = 4;
  static const _kFileSizeWithoutData = 36;
  static const _kFloatFmtExtraSize = 12;
  static const _kPCM = 1;
  static const _kFloat = 3;
  static const _kStrRiff = 'RIFF';
  static const _kStrWave = 'WAVE';
  static const _kStrFmt = 'fmt ';
  static const _kStrData = 'data';
  static const _kStrFact = 'fact';

  static WavFormat _getFormat(int formatCode, int bitsPerSample) {
    if (formatCode == _kPCM) {
      if (bitsPerSample == 8) return WavFormat.pcm8bit;
      if (bitsPerSample == 16) return WavFormat.pcm16bit;
      if (bitsPerSample == 24) return WavFormat.pcm24bit;
      if (bitsPerSample == 32) return WavFormat.pcm32bit;
    } else if (formatCode == _kFloat) {
      if (bitsPerSample == 32) return WavFormat.float32;
      if (bitsPerSample == 64) return WavFormat.float64;
    }
    throw FormatException('Unsupported format: $formatCode, $bitsPerSample');
  }

  // [0, 2] => [0, 2 ^ bits - 1]
  static double _wScale(int bits) => (1 << (bits - 1)) * 1.0;
  static double _rScale(int bits) => _wScale(bits) - 0.5;
  static int _fold(int x, int bits) => (x + (1 << (bits - 1))) % (1 << bits);

  // Chunk is always padded to an even number of bytes.
  static int _roundUp(int x) => x + (x % 2);

  /// Read a Wav from a byte buffer.
  ///
  /// Not all formats are supported. See [WavFormat] for a canonical list.
  /// Unrecognized metadata will be ignored.
  static Wav read(Uint8List bytes) {
    // Utils for reading.
    int p = 0;
    void skip(int n) {
      p += n;
      if (p > bytes.length) {
        throw FormatException('WAV is corrupted, or not a WAV file.');
      }
    }

    ByteData read(int n) {
      final p0 = p;
      skip(n);
      return ByteData.sublistView(bytes, p0, p);
    }

    int readU8() => read(1).getUint8(0);
    int readU16() => read(2).getUint16(0, Endian.little);
    int readU24() => readU8() + 0x100 * readU16();
    int readU32() => read(4).getUint32(0, Endian.little);
    double u2f(int x, int b) => (x / _rScale(b)) - 1;
    double readS8() => u2f(readU8(), 8);
    double readS16() => u2f(_fold(readU16(), 16), 16);
    double readS24() => u2f(_fold(readU24(), 24), 24);
    double readS32() => u2f(_fold(readU32(), 32), 32);
    double readF32() => read(4).getFloat32(0, Endian.little);
    double readF64() => read(8).getFloat64(0, Endian.little);
    bool checkString(String s) {
      return s == String.fromCharCodes(Uint8List.sublistView(read(s.length)));
    }

    void assertString(String s) {
      if (!checkString(s)) {
        throw FormatException('WAV is corrupted, or not a WAV file.');
      }
    }

    void findChunk(String s) {
      while (!checkString(s)) {
        final size = readU32();
        skip(_roundUp(size));
      }
    }

    // Read metadata.
    assertString(_kStrRiff);
    readU32(); // File size.
    assertString(_kStrWave);

    findChunk(_kStrFmt);
    final fmtSize = _roundUp(readU32());
    final formatCode = readU16();
    final numChannels = readU16();
    final samplesPerSecond = readU32();
    readU32(); // Bytes per second.
    final bytesPerSampleAllChannels = readU16();
    final bitsPerSample = readU16();
    if (fmtSize > _kFormatSize) skip(fmtSize - _kFormatSize);

    findChunk(_kStrData);
    final dataSize = readU32();
    final numSamples = dataSize ~/ bytesPerSampleAllChannels;
    final channels = <Float64List>[];
    for (int i = 0; i < numChannels; ++i) {
      channels.add(Float64List(numSamples));
    }
    final format = _getFormat(formatCode, bitsPerSample);

    // Read samples.
    final readSample =
        [readS8, readS16, readS24, readS32, readF32, readF64][format.index];
    for (int i = 0; i < numSamples; ++i) {
      for (int j = 0; j < numChannels; ++j) {
        channels[j][i] = readSample();
      }
    }
    return Wav(channels, samplesPerSecond, format);
  }

  /// Mix the audio channels down to mono.
  Float64List toMono() {
    if (channels.isEmpty) return Float64List(0);
    final mono = Float64List(channels[0].length);
    for (int i = 0; i < mono.length; ++i) {
      for (int j = 0; j < channels.length; ++j) {
        mono[i] += channels[j][i];
      }
      mono[i] /= channels.length;
    }
    return mono;
  }

  /// Write the Wav to a file.
  ///
  /// Convenience wrapper around [write]. See that method for details.
  Future<void> writeFile(String filename) async {
    await internalWriteFile(filename, write());
  }

  /// Write the Wav to a byte buffer.
  ///
  /// If your audio samples exceed `[-1, 1]`, they will be clamped (unless
  /// you're using float32 or float64 format). If your channels are different
  /// lengths, they will be padded with zeros.
  Uint8List write() {
    // Calculate sizes etc.
    final bitsPerSample = [8, 16, 24, 32, 32, 64][format.index];
    final isFloat = format == WavFormat.float32 || format == WavFormat.float64;
    final bytesPerSample = bitsPerSample ~/ 8;
    final numChannels = channels.length;
    int numSamples = 0;
    for (final channel in channels) {
      if (channel.length > numSamples) numSamples = channel.length;
    }
    final bytesPerSampleAllChannels = bytesPerSample * numChannels;
    final dataSize = numSamples * bytesPerSampleAllChannels;
    final bytesPerSecond = bytesPerSampleAllChannels * samplesPerSecond;
    var fileSize = _kFileSizeWithoutData + _roundUp(dataSize);
    if (isFloat) {
      fileSize += _kFloatFmtExtraSize;
    }

    // Utils for writing. The write methods rely on ByteBuilder's truncation.
    final bytes = BytesBuilder();
    writeU8(int x) => bytes..addByte(x);
    writeU16(int x) => writeU8(x)..addByte(x >> 8);
    writeU24(int x) => writeU16(x)..addByte(x >> 16);
    writeU32(int x) => writeU24(x)..addByte(x >> 24);
    clamp(int x, int y) => x < 0
        ? 0
        : x > y
            ? y
            : x;
    f2u(double x, int b) => clamp(((x + 1) * _wScale(b)).floor(), (1 << b) - 1);
    writeS8(double x) => writeU8(f2u(x, 8));
    writeS16(double x) => writeU16(_fold(f2u(x, 16), 16));
    writeS24(double x) => writeU24(_fold(f2u(x, 24), 24));
    writeS32(double x) => writeU32(_fold(f2u(x, 32), 32));
    final fbuf = ByteData(8);
    writeBytes(ByteData b, int n) => bytes.add(b.buffer.asUint8List(0, n));
    writeF32(double x) => writeBytes(fbuf..setFloat32(0, x, Endian.little), 4);
    writeF64(double x) => writeBytes(fbuf..setFloat64(0, x, Endian.little), 8);
    writeString(String str) {
      for (int c in str.codeUnits) {
        bytes.addByte(c);
      }
    }

    // Write metadata.
    writeString(_kStrRiff);
    writeU32(fileSize);
    writeString(_kStrWave);
    writeString(_kStrFmt);
    writeU32(_kFormatSize);
    writeU16(isFloat ? _kFloat : _kPCM);
    writeU16(numChannels);
    writeU32(samplesPerSecond);
    writeU32(bytesPerSecond);
    writeU16(bytesPerSampleAllChannels);
    writeU16(bitsPerSample);
    if (isFloat) {
      writeString(_kStrFact);
      writeU32(_kFactSize);
      writeU32(numSamples);
    }
    writeString(_kStrData);
    writeU32(dataSize);

    // Write samples.
    final writeSample = [
      writeS8,
      writeS16,
      writeS24,
      writeS32,
      writeF32,
      writeF64,
    ][format.index];
    for (int i = 0; i < numSamples; ++i) {
      for (int j = 0; j < numChannels; ++j) {
        writeSample(i < channels[j].length ? channels[j][i] : 0);
      }
    }
    if (dataSize % 2 != 0) {
      writeU8(0);
    }
    return bytes.takeBytes();
  }
}
