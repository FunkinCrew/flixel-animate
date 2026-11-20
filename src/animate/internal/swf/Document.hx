package animate.internal.swf;

import animate.FlxAnimateJson.FilterJson;
import animate.internal.swf.ShapeTypes.Shape;
import flixel.math.FlxMatrix;
import flixel.math.FlxRect;
import flixel.util.FlxColor;
import flixel.util.FlxSort;
import format.swf.Data;
import format.swf.Reader;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import openfl.display.BitmapData;
import openfl.utils.ByteArray;

typedef RawColorTransform =
{
  mult:Array<Float>,
  add:Array<Float>
}

typedef RawFrame =
{
  depth:Int,
  charId:Int,
  matrix:FlxMatrix,
  colorMult:Array<Float>,
  colorAdd:Array<Float>,
  name:Null<String>,
  ratio:Null<Int>,
  blendMode:Int,
  filters:Null<Array<FilterJson>>
}

class RawSymbol
{
  public var characterId:Int;
  public var frameCount:Int;
  public var frames:Array<Array<RawFrame>> = [];
  public var frameLabels:Map<Int, String> = new Map<Int, String>();

  public function new(characterId:Int)
  {
    this.characterId = characterId;
  }
}

class Document
{
  public var shapes:Map<Int, Shape> = new Map<Int, Shape>();
  public var bitmaps:Map<Int, BitmapData> = new Map<Int, BitmapData>();
  public var sprites:Map<Int, RawSymbol> = new Map<Int, RawSymbol>();
  public var root:RawSymbol;
  public var frameRate:Float;
  public var stageBounds:FlxRect;

  var jpegTables:Null<Bytes> = null;

  /**
   * Builds a new `Document` instance from raw SWF bytes
   * @param input The bytes to parse
   * @return The new instance
   */
  public static function build(input:ByteArray):Document
  {
    var reader:Reader = new Reader(new BytesInput(decompressBytes(input)));
    var header:SWFHeader = reader.readHeader();
    var tags:Array<SWFTag> = reader.readTagList();
    var doc:Document = new Document();

    doc.frameRate = header.fps / 256.0;
    doc.stageBounds = FlxRect.get(0, 0, header.width, header.height);

    doc.root = new RawSymbol(0);
    doc.root.frameCount = header.nframes;

    processTags(tags, doc, doc.root);

		doc.jpegTables = null;

    return doc;
  }

  function new()
  {
  }

  // format.swf.Reader.readHeader() already handles this but it doesn't
  // fucking work so we have to do it manually :(
  // TODO: Remove this

  static function decompressBytes(input:ByteArray):ByteArray
  {
    input.position = 0;
    if (input.readUTFBytes(3) == 'FWS')
    {
      input.position = 0;
      return input;
    }

    var version = input.readUnsignedByte();
    input.endian = LITTLE_ENDIAN;
    var fileLength = input.readUnsignedInt();
    var compressedBody = new ByteArray();
    input.readBytes(compressedBody, 0, input.bytesAvailable);
    compressedBody.uncompress();

    var out = new ByteArray();
    out.endian = LITTLE_ENDIAN;
    out.writeUTFBytes('FWS');
    out.writeByte(version);
    out.writeUnsignedInt(fileLength);
    out.writeBytes(compressedBody);
    return out;
  }

  static function processTags(tags:Array<SWFTag>, doc:Document, timelineOut:RawSymbol):Void
  {
    var displayList:Map<Int, RawFrame> = new Map<Int, RawFrame>();
    var frameIndex:Int = 0;

    for (tag in tags)
    {
      switch (tag)
      {
        case TShowFrame:
					var list:Array<RawFrame> = [for (p in displayList) p];
					list.sort((a, b) -> FlxSort.byValues(FlxSort.ASCENDING, a.depth, b.depth));

          timelineOut.frames.push(list);
          frameIndex++;

        case TShape(id, data):
          doc.shapes.set(id, ShapeParser.parse(id, data));

        case TBitsLossless(data):
          doc.bitmaps.set(data.cid, decodeLossless(data, false));

        case TBitsLossless2(data):
          doc.bitmaps.set(data.cid, decodeLossless(data, true));

        case TJPEGTables(data):
          doc.jpegTables = data;

        case TBitsJPEG(id, data):
          doc.bitmaps.set(id, decodeJPEG(data, doc.jpegTables));

        case TClip(id, frameCount, innerTags):
          var symbol:RawSymbol = new RawSymbol(id);
          symbol.frameCount = frameCount;
          doc.sprites.set(id, symbol);
          processTags(innerTags, doc, symbol);

        case TPlaceObject2(po), TPlaceObject3(po):
          var placement = resolvePlaceObject(po, displayList);
          displayList.set(placement.depth, placement);

        case TRemoveObject2(depth):
          displayList.remove(depth);

        case TFrameLabel(label, _):
          timelineOut.frameLabels.set(frameIndex, label);

        default:
      }
    }
  }

  static function resolvePlaceObject(po:PlaceObject, displayList:Map<Int, RawFrame>):RawFrame
  {
    var existing = po.move ? displayList.get(po.depth) : null;
    var matrix = po.matrix != null ? convertMatrix(po.matrix) : (existing != null ? existing.matrix : new FlxMatrix());
    var ct = po.color != null ? convertColorTransform(po.color) : null;
    var colorMult = ct != null ? ct.mult : (existing != null ? existing.colorMult : [1.0, 1.0, 1.0, 1.0]);
    var colorAdd = ct != null ? ct.add : (existing != null ? existing.colorAdd : [0.0, 0.0, 0.0, 0.0]);
    var charId = po.cid != null ? po.cid : (existing != null ? existing.charId : -1);
    var name = po.instanceName != null ? po.instanceName : (existing != null ? existing.name : null);
    var ratio = po.ratio != null ? po.ratio : (existing != null ? existing.ratio : null);
    var blendMode = po.blendMode != null ? convertBlendMode(po.blendMode) : (existing != null ? existing.blendMode : 10);
    var filters = po.filters != null ? convertFilters(po.filters) : (existing != null ? existing.filters : null);

    return {
      depth: po.depth,
      charId: charId,
      matrix: matrix,
      colorMult: colorMult,
      colorAdd: colorAdd,
      name: name,
      ratio: ratio,
      blendMode: blendMode,
      filters: filters
    };
  }

  public static function convertMatrix(m:Matrix):FlxMatrix
  {
    var a:Float = 1.0;
    var b:Float = 0.0;
    var c:Float = 0.0;
    var d:Float = 1.0;

    if (m.scale != null)
    {
      a = m.scale.x;
      d = m.scale.y;
    }

    if (m.rotate != null)
    {
      b = m.rotate.rs0;
      c = m.rotate.rs1;
    }

    return new FlxMatrix(a, b, c, d, m.translate.x, m.translate.y);
  }

  static function convertColorTransform(cxa:CXA):RawColorTransform
  {
    return {
      mult: cxa.mult == null ? [1.0, 1.0, 1.0, 1.0] : [cxa.mult.r / 256.0, cxa.mult.g / 256.0, cxa.mult.b / 256.0, cxa.mult.a / 256.0],
      add: cxa.add == null ? [0.0, 0.0, 0.0, 0.0] : [cxa.add.r, cxa.add.g, cxa.add.b, cxa.add.a]
    };
  }

  static function convertBlendMode(bm:BlendMode):Int
  {
    return switch (bm)
    {
      case BAdd:
        0;
      case BAlpha:
        1;
      case BDarken:
        2;
      case BDifference:
        3;
      case BErase:
        4;
      case BHardLight:
        5;
      case BInvert:
        6;
      case BLayer:
        7;
      case BLighten:
        8;
      case BMultiply:
        9;
      case BNormal:
        10;
      case BOverlay:
        11;
      case BScreen:
        12;
      // 13 is SHADER but that's not here for obvious reasons
      case BSubtract:
        14;
    }
  }

  static function decodeLossless(l:Lossless, hasAlpha:Bool):BitmapData
  {
    var compressed = ByteArray.fromBytes(l.data);
    compressed.uncompress();

    var bitmap:BitmapData = new BitmapData(l.width, l.height, true, 0);

    inline function fill(getColor:(x:Int, y:Int) -> Int):Void
    {
      for (y in 0...l.height) for (x in 0...l.width) bitmap.setPixel32(x, y, getColor(x, y));
    }

    switch (l.color)
    {
      case CM8Bits(ncolors):
        var paletteSize = ncolors + 1;
        var entrySize = hasAlpha ? 4 : 3;
        var stride = (l.width + 3) & ~3;

        fill((x, y) ->
        {
          var index = compressed[paletteSize * entrySize + y * stride + x];
          var o = index * entrySize;
          var a = hasAlpha ? compressed[o + 3] : 0xFF;
          return FlxColor.fromRGB(compressed[o], compressed[o + 1], compressed[o + 2], a);
        });

      case CM24Bits:
        fill((x, y) ->
        {
          var o = (y * l.width + x) * 4;
          return FlxColor.fromRGB(compressed[o + 1], compressed[o + 2], compressed[o + 3], 0xFF);
        });

      case CM32Bits:
        fill((x, y) ->
        {
          var o = (y * l.width + x) * 4;
          var a = compressed[o];
          if (a <= 0) return 0;
          return FlxColor.fromRGB(Std.int(compressed[o + 1] * 255 / a), Std.int(compressed[o + 2] * 255 / a), Std.int(compressed[o + 3] * 255 / a), a);
        });

      case CM15Bits:
        throw 'Not implemented!';
    }

    return bitmap;
  }

  static function decodeJPEG(data:JPEGData, jpegTables:Null<Bytes>):BitmapData
  {
    var imageBytes:Bytes;
    var maskBytes:Null<Bytes> = null;

    switch (data)
    {
      case JDJPEG1(d):
        imageBytes = (jpegTables != null) ? concat(jpegTables, d) : d;

      case JDJPEG2(d):
        imageBytes = d;

      case JDJPEG3(d, mask):
        imageBytes = d;
        maskBytes = mask;
    }

    var bitmap:BitmapData = BitmapData.fromBytes(ByteArray.fromBytes(imageBytes));

    if (maskBytes != null)
    {
      var alpha = ByteArray.fromBytes(maskBytes);
      alpha.uncompress();

      for (y in 0...bitmap.height)
      {
        for (x in 0...bitmap.width)
        {
          var a:Int = alpha[y * bitmap.width + x];
          var color:Int = bitmap.getPixel(x, y);
          bitmap.setPixel32(x, y, FlxColor.fromRGB((color >> 16) & 0xFF, (color >> 8) & 0xFF, color & 0xFF, a));
        }
      }
    }

    return bitmap;
  }

  static function concat(a:Bytes, b:Bytes):Bytes
  {
    var out = Bytes.alloc(a.length + b.length);
    out.blit(0, a, 0, a.length);
    out.blit(a.length, b, 0, b.length);
    return out;
  }

  static function convertFilters(filters:Array<Filter>):Array<FilterJson>
  {
    var result:Array<FilterJson> = [];

    for (f in filters)
    {
      switch (f)
      {
        case FDropShadow(d):
          result.push(cast {
            N: 'DSF',
            C: FlxColor.fromRGB(d.color.r, d.color.g, d.color.b, d.color.a).toHexString(),
            A: d.color.a / 255.0,
            BLX: d.blurX / 65536.0,
            BLY: d.blurY / 65536.0,
            AL: (d.angle / 65536.0) * 180 / Math.PI,
            D: d.distance / 65536.0,
            STR: d.strength / 256.0,
            Q: d.flags.passes,
            IN: d.flags.inner,
            KK: d.flags.knockout,
            HO: !d.flags.ontop
          });

        case FBlur(d):
          result.push(cast {
            N: 'BLF',
            BLX: d.blurX / 65536.0,
            BLY: d.blurY / 65536.0,
            Q: d.passes
          });

        case FGlow(d):
          result.push(cast {
            N: 'GF',
            C: FlxColor.fromRGB(d.color.r, d.color.g, d.color.b, d.color.a).toHexString(),
            A: d.color.a / 255.0,
            BLX: d.blurX / 65536.0,
            BLY: d.blurY / 65536.0,
            STR: (d.strength / 256.0) * 100,
            Q: d.flags.passes,
            IN: d.flags.inner,
            KK: d.flags.knockout
          });

        case FBevel(d):
          result.push(cast {
            N: 'BF',
            SC: FlxColor.fromRGB(d.color.r, d.color.g, d.color.b, d.color.a).toHexString(),
            SA: d.color.a / 255.0,
            HC: FlxColor.fromRGB(d.color2.r, d.color2.g, d.color2.b, d.color2.a).toHexString(),
            HA: d.color2.a / 255.0,
            BLX: d.blurX / 65536.0,
            BLY: d.blurY / 65536.0,
            AL: (d.angle / 65536.0) * 180 / Math.PI,
            D: d.distance / 65536.0,
            STR: d.strength / 256.0,
            Q: d.flags.passes,
            T: d.flags.ontop ? 'full' : 'inner',
            IN: d.flags.inner,
            KK: d.flags.knockout
          });

        case FColorMatrix(matrix):
          result.push(cast {
            N: 'ACF',
            MX: matrix
          });

        case FGradientGlow(_), FGradientBevel(_):
      }
    }

    return result;
  }
}
