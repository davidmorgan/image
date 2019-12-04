import 'dart:typed_data';
import '../../color.dart';
import '../../exif_data.dart';
import '../../image.dart';
import '../../image_exception.dart';
import '../../internal/bit_operators.dart';
import '_component_data.dart';
import 'jpeg_data.dart';

Uint8List _dctClip;
int _clamp8(int i) => i < 0 ? 0 : i > 255 ? 255 : i;

// These functions contain bit-shift operations that fail with HTML builds.
// A conditional import is used to use a modified version for HTML builds
// to work around this javascript bug, while keeping the native version fast.

// Quantize the coefficients and apply IDCT.
//
// A port of poppler's IDCT method which in turn is taken from:
// Christoph Loeffler, Adriaan Ligtenberg, George S. Moschytz,
// "Practical Fast 1-D DCT Algorithms with 11 Multiplications",
// IEEE Intl. Conf. on Acoustics, Speech & Signal Processing, 1989, 988-991.
void quantizeAndInverse(Int16List quantizationTable, Int32List coefBlock,
    Uint8List dataOut, Int32List dataIn) {
  Int32List p = dataIn;

  const int dctClipOffset = 256;
  const int dctClipLength = 768;
  if (_dctClip == null) {
    _dctClip = Uint8List(dctClipLength);
    int i;
    for (i = -256; i < 0; ++i) {
      _dctClip[dctClipOffset + i] = 0;
    }
    for (i = 0; i < 256; ++i) {
      _dctClip[dctClipOffset + i] = i;
    }
    for (i = 256; i < 512; ++i) {
      _dctClip[dctClipOffset + i] = 255;
    }
  }

  // IDCT constants (20.12 fixed point format)
  const int COS_1 = 4017; // cos(pi/16)*4096
  const int SIN_1 = 799; // sin(pi/16)*4096
  const int COS_3 = 3406; // cos(3*pi/16)*4096
  const int SIN_3 = 2276; // sin(3*pi/16)*4096
  const int COS_6 = 1567; // cos(6*pi/16)*4096
  const int SIN_6 = 3784; // sin(6*pi/16)*4096
  const int SQRT_2 = 5793; // sqrt(2)*4096
  const int SQRT_1D2 = 2896; // sqrt(2) / 2

  // de-quantize
  for (int i = 0; i < 64; i++) {
    p[i] = (coefBlock[i] * quantizationTable[i]);
  }

  // inverse DCT on rows
  int row = 0;
  for (int i = 0; i < 8; ++i, row += 8) {
    // check for all-zero AC coefficients
    if (p[1 + row] == 0 &&
        p[2 + row] == 0 &&
        p[3 + row] == 0 &&
        p[4 + row] == 0 &&
        p[5 + row] == 0 &&
        p[6 + row] == 0 &&
        p[7 + row] == 0) {
      int t = shiftR((SQRT_2 * p[0 + row] + 512), 10);
      p[row + 0] = t;
      p[row + 1] = t;
      p[row + 2] = t;
      p[row + 3] = t;
      p[row + 4] = t;
      p[row + 5] = t;
      p[row + 6] = t;
      p[row + 7] = t;
      continue;
    }

    // stage 4
    int v0 = shiftR((SQRT_2 * p[0 + row] + 128), 8);
    int v1 = shiftR((SQRT_2 * p[4 + row] + 128), 8);
    int v2 = p[2 + row];
    int v3 = p[6 + row];
    int v4 = shiftR((SQRT_1D2 * (p[1 + row] - p[7 + row]) + 128), 8);
    int v7 = shiftR((SQRT_1D2 * (p[1 + row] + p[7 + row]) + 128), 8);
    int v5 = shiftL(p[3 + row], 4);
    int v6 = shiftL(p[5 + row], 4);

    // stage 3
    int t = shiftR((v0 - v1 + 1), 1);
    v0 = shiftR((v0 + v1 + 1), 1);
    v1 = t;
    t = shiftR((v2 * SIN_6 + v3 * COS_6 + 128), 8);
    v2 = shiftR((v2 * COS_6 - v3 * SIN_6 + 128), 8);
    v3 = t;
    t = shiftR((v4 - v6 + 1), 1);
    v4 = shiftR((v4 + v6 + 1), 1);
    v6 = t;
    t = shiftR((v7 + v5 + 1), 1);
    v5 = shiftR((v7 - v5 + 1), 1);
    v7 = t;

    // stage 2
    t = shiftR((v0 - v3 + 1), 1);
    v0 = shiftR((v0 + v3 + 1), 1);
    v3 = t;
    t = shiftR((v1 - v2 + 1), 1);
    v1 = shiftR((v1 + v2 + 1), 1);
    v2 = t;
    t = shiftR((v4 * SIN_3 + v7 * COS_3 + 2048), 12);
    v4 = shiftR((v4 * COS_3 - v7 * SIN_3 + 2048), 12);
    v7 = t;
    t = shiftR((v5 * SIN_1 + v6 * COS_1 + 2048), 12);
    v5 = shiftR((v5 * COS_1 - v6 * SIN_1 + 2048), 12);
    v6 = t;

    // stage 1
    p[0 + row] = (v0 + v7);
    p[7 + row] = (v0 - v7);
    p[1 + row] = (v1 + v6);
    p[6 + row] = (v1 - v6);
    p[2 + row] = (v2 + v5);
    p[5 + row] = (v2 - v5);
    p[3 + row] = (v3 + v4);
    p[4 + row] = (v3 - v4);
  }

  // inverse DCT on columns
  for (int i = 0; i < 8; ++i) {
    int col = i;

    // check for all-zero AC coefficients
    if (p[1 * 8 + col] == 0 &&
        p[2 * 8 + col] == 0 &&
        p[3 * 8 + col] == 0 &&
        p[4 * 8 + col] == 0 &&
        p[5 * 8 + col] == 0 &&
        p[6 * 8 + col] == 0 &&
        p[7 * 8 + col] == 0) {
      int t = shiftR((SQRT_2 * dataIn[i] + 8192), 14);
      p[0 * 8 + col] = t;
      p[1 * 8 + col] = t;
      p[2 * 8 + col] = t;
      p[3 * 8 + col] = t;
      p[4 * 8 + col] = t;
      p[5 * 8 + col] = t;
      p[6 * 8 + col] = t;
      p[7 * 8 + col] = t;
      continue;
    }

    // stage 4
    int v0 = shiftR((SQRT_2 * p[0 * 8 + col] + 2048), 12);
    int v1 = shiftR((SQRT_2 * p[4 * 8 + col] + 2048), 12);
    int v2 = p[2 * 8 + col];
    int v3 = p[6 * 8 + col];
    int v4 =
    shiftR((SQRT_1D2 * (p[1 * 8 + col] - p[7 * 8 + col]) + 2048), 12);
    int v7 =
    shiftR((SQRT_1D2 * (p[1 * 8 + col] + p[7 * 8 + col]) + 2048), 12);
    int v5 = p[3 * 8 + col];
    int v6 = p[5 * 8 + col];

    // stage 3
    int t = shiftR((v0 - v1 + 1), 1);
    v0 = shiftR((v0 + v1 + 1), 1);
    v1 = t;
    t = shiftR((v2 * SIN_6 + v3 * COS_6 + 2048), 12);
    v2 = shiftR((v2 * COS_6 - v3 * SIN_6 + 2048), 12);
    v3 = t;
    t = shiftR((v4 - v6 + 1), 1);
    v4 = shiftR((v4 + v6 + 1), 1);
    v6 = t;
    t = shiftR((v7 + v5 + 1), 1);
    v5 = shiftR((v7 - v5 + 1), 1);
    v7 = t;

    // stage 2
    t = shiftR((v0 - v3 + 1), 1);
    v0 = shiftR((v0 + v3 + 1), 1);
    v3 = t;
    t = shiftR((v1 - v2 + 1), 1);
    v1 = shiftR((v1 + v2 + 1), 1);
    v2 = t;
    t = shiftR((v4 * SIN_3 + v7 * COS_3 + 2048), 12);
    v4 = shiftR((v4 * COS_3 - v7 * SIN_3 + 2048), 12);
    v7 = t;
    t = shiftR((v5 * SIN_1 + v6 * COS_1 + 2048), 12);
    v5 = shiftR((v5 * COS_1 - v6 * SIN_1 + 2048), 12);
    v6 = t;

    // stage 1
    p[0 * 8 + col] = (v0 + v7);
    p[7 * 8 + col] = (v0 - v7);
    p[1 * 8 + col] = (v1 + v6);
    p[6 * 8 + col] = (v1 - v6);
    p[2 * 8 + col] = (v2 + v5);
    p[5 * 8 + col] = (v2 - v5);
    p[3 * 8 + col] = (v3 + v4);
    p[4 * 8 + col] = (v3 - v4);
  }

  // convert to 8-bit integers
  for (int i = 0; i < 64; ++i) {
    dataOut[i] = _dctClip[(dctClipOffset + 128 + shiftR((p[i] + 8), 4))];
  }
}

Image getImageFromJpeg(JpegData jpeg) {
  var image = Image(jpeg.width, jpeg.height, channels: Channels.rgb);
  image.exif = ExifData.from(jpeg.exif);

  ComponentData component1;
  ComponentData component2;
  ComponentData component3;
  ComponentData component4;
  Uint8List component1Line;
  Uint8List component2Line;
  Uint8List component3Line;
  Uint8List component4Line;
  int offset = 0;
  int Y, Cb, Cr, K, C, M, Ye, R, G, B;
  bool colorTransform = false;

  switch (jpeg.components.length) {
    case 1:
      component1 = jpeg.components[0];
      var lines = component1.lines;
      int hShift1 = component1.hScaleShift;
      int vShift1 = component1.vScaleShift;
      for (int y = 0; y < jpeg.height; y++) {
        int y1 = y >> vShift1;
        component1Line = lines[y1];
        for (int x = 0; x < jpeg.width; x++) {
          int x1 = x >> hShift1;
          Y = component1Line[x1];
          image[offset++] = getColor(Y, Y, Y);
        }
      }
      break;
  /*case 2:
        // PDF might compress two component data in custom color-space
        component1 = components[0];
        component2 = components[1];
        int hShift1 = component1.hScaleShift;
        int vShift1 = component1.vScaleShift;
        int hShift2 = component2.hScaleShift;
        int vShift2 = component2.vScaleShift;

        for (int y = 0; y < height; y++) {
          int y1 = y >> vShift1;
          int y2 = y >> vShift2;
          component1Line = component1.lines[y1];
          component2Line = component2.lines[y2];

          for (int x = 0; x < width; x++) {
            int x1 = x >> hShift1;
            int x2 = x >> hShift2;

            Y = component1Line[x1];
            //data[offset++] = Y;

            Y = component2Line[x2];
            //data[offset++] = Y;
          }
        }
        break;*/
    case 3:
    // The default transform for three components is true
      colorTransform = true;

      component1 = jpeg.components[0];
      component2 = jpeg.components[1];
      component3 = jpeg.components[2];

      var lines1 = component1.lines;
      var lines2 = component2.lines;
      var lines3 = component3.lines;

      int hShift1 = component1.hScaleShift;
      int vShift1 = component1.vScaleShift;
      int hShift2 = component2.hScaleShift;
      int vShift2 = component2.vScaleShift;
      int hShift3 = component3.hScaleShift;
      int vShift3 = component3.vScaleShift;

      for (int y = 0; y < jpeg.height; y++) {
        int y1 = y >> vShift1;
        int y2 = y >> vShift2;
        int y3 = y >> vShift3;

        component1Line = lines1[y1];
        component2Line = lines2[y2];
        component3Line = lines3[y3];

        for (int x = 0; x < jpeg.width; x++) {
          int x1 = x >> hShift1;
          int x2 = x >> hShift2;
          int x3 = x >> hShift3;

          if (!colorTransform) {
            R = component1Line[x1];
            G = component1Line[x2];
            B = component1Line[x3];
            image[offset++] = getColor(R, G, B);
          } else {
            Y = component1Line[x1] << 8;
            Cb = component2Line[x2] - 128;
            Cr = component3Line[x3] - 128;

            R = (Y + 359 * Cr + 128);
            G = (Y - 88 * Cb - 183 * Cr + 128);
            B = (Y + 454 * Cb + 128);

            R = _clamp8(shiftR(R, 8));
            G = _clamp8(shiftR(G, 8));
            B = _clamp8(shiftR(B, 8));
            image[offset++] = getColor(R, G, B);
          }
        }
      }
      break;
    case 4:
      if (jpeg.adobe == null) {
        throw ImageException('Unsupported color mode (4 components)');
      }
      // The default transform for four components is false
      colorTransform = false;
      // The adobe transform marker overrides any previous setting
      if (jpeg.adobe.transformCode != 0) {
        colorTransform = true;
      }

      component1 = jpeg.components[0];
      component2 = jpeg.components[1];
      component3 = jpeg.components[2];
      component4 = jpeg.components[3];

      var lines1 = component1.lines;
      var lines2 = component2.lines;
      var lines3 = component3.lines;
      var lines4 = component4.lines;

      int hShift1 = component1.hScaleShift;
      int vShift1 = component1.vScaleShift;
      int hShift2 = component2.hScaleShift;
      int vShift2 = component2.vScaleShift;
      int hShift3 = component3.hScaleShift;
      int vShift3 = component3.vScaleShift;
      int hShift4 = component4.hScaleShift;
      int vShift4 = component4.vScaleShift;

      for (int y = 0; y < jpeg.height; y++) {
        int y1 = y >> vShift1;
        int y2 = y >> vShift2;
        int y3 = y >> vShift3;
        int y4 = y >> vShift4;
        component1Line = lines1[y1];
        component2Line = lines2[y2];
        component3Line = lines3[y3];
        component4Line = lines4[y4];
        for (int x = 0; x < jpeg.width; x++) {
          int x1 = x >> hShift1;
          int x2 = x >> hShift2;
          int x3 = x >> hShift3;
          int x4 = x >> hShift4;
          if (!colorTransform) {
            C = component1Line[x1];
            M = component2Line[x2];
            Ye = component3Line[x3];
            K = component4Line[x4];
          } else {
            Y = component1Line[x1];
            Cb = component2Line[x2];
            Cr = component3Line[x3];
            K = component4Line[x4];

            C = 255 - _clamp8((Y + 1.402 * (Cr - 128)).toInt());
            M = 255 - _clamp8((Y - 0.3441363 * (Cb - 128) -
                0.71413636 * (Cr - 128)).toInt());
            Ye = 255 - _clamp8((Y + 1.772 * (Cb - 128)).toInt());
          }
          R = shiftR((C * K), 8);
          G = shiftR((M * K), 8);
          B = shiftR((Ye * K), 8);
          image[offset++] = getColor(R, G, B);
        }
      }
      break;
    default:
      throw ImageException('Unsupported color mode');
  }

  return image;
}