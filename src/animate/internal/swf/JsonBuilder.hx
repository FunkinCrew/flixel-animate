package animate.internal.swf;

import animate.internal.swf.Document.RawSymbol;
import animate.internal.swf.Document.RawFrame;
import animate.internal.swf.ShapeTypes.Shape;
import animate.internal.filters.Blend;
import animate.FlxAnimateJson;
import flixel.math.FlxMatrix;
import flixel.util.FlxSort;

using Lambda;

class JsonBuilder
{
  /**
   * Constructs a lot of `TimelineJson`s from a parsed SWF file
   * @param doc The parsed SWF file
   * @return A map of symbol names to `TimelineJson`s
   *
   * We're kind of LARPING as a texture atlas :)
   */
  public static function build(doc:Document):Map<String, TimelineJson>
  {
    var result:Map<String, TimelineJson> = new Map<String, TimelineJson>();
    for (sprite in doc.sprites)
    {
      result.set(makeSymbolName(sprite.characterId), buildTimelineJson(makeSymbolName(sprite.characterId), sprite, doc));
    }

    result.set('__root__', buildTimelineJson('__root__', doc.root, doc));

    return result;
  }

  static inline function makeSymbolName(characterId:Int):String return 'swf_sprite_$characterId';

  static function buildTimelineJson(name:String, sym:RawSymbol, doc:Document):TimelineJson
  {
    var depths:Map<Int, Bool> = new Map<Int, Bool>();
    for (frame in sym.frames)
    {
      for (p in frame)
      {
        depths.set(p.depth, true);
      }
    }

    var sortedDepths:Array<Int> = [for (d in depths.keys()) d];
    sortedDepths.sort((a, b) -> FlxSort.byValues(FlxSort.DESCENDING, a, b));

    var layers:Array<LayerJson> = [];
    layers.push(buildLabelLayerJson(sym));

    for (depth in sortedDepths) layers.push(buildLayerJson(depth, sym, doc));

    return cast {
      N: name,
      FR: sym.frameCount,
      L: layers
    };
  }

  static function buildLabelLayerJson(sym:RawSymbol):LayerJson
  {
    var frames:Array<FrameJson> = [];

    var labelFrames:Array<Int> = [for (frameIdx in sym.frameLabels.keys()) frameIdx];
    labelFrames.sort((a, b) -> FlxSort.byValues(FlxSort.ASCENDING, a, b));

    var start = 0;
    for (idx in 0...labelFrames.length)
    {
      var frame = labelFrames[idx];
      var end = idx + 1 < labelFrames.length ? labelFrames[idx + 1] : sym.frames.length;
      if (frame > start) frames.push(buildFrameJson(start, frame - start, null, null, null));
      frames.push(buildFrameJson(frame, end - frame, null, null, sym.frameLabels.get(frame)));
      start = end;
    }

    if (start < sym.frames.length || frames.length == 0)
      frames.push(buildFrameJson(start, sym.frames.length - start, null, null, null));

    return cast {
      LN: 'labels',
      FR: frames
    };
  }

  static function buildLayerJson(depth:Int, sym:RawSymbol, doc:Document):LayerJson
  {
    var frames:Array<FrameJson> = [];
    var lastFrame:Null<RawFrame> = null;
    var runStart:Int = 0;

    inline function flushRun(endFrame:Int):Void
    {
      frames.push(buildFrameJson(runStart, endFrame - runStart, lastFrame, doc, sym.frameLabels.get(runStart)));
    }

    for (frameIdx in 0...sym.frames.length)
    {
      var currentFrame:RawFrame = sym.frames[frameIdx].find((item) -> item.depth == depth);
      var changed:Bool = !equalsFrame(currentFrame, lastFrame);
      var labeled:Bool = frameIdx > runStart && sym.frameLabels.exists(frameIdx);

      if (changed || labeled)
      {
        flushRun(frameIdx);
        lastFrame = currentFrame;
        runStart = frameIdx;
      }
    }

    flushRun(sym.frames.length);

    return cast {
      LN: 'Depth $depth',
      FR: frames
    };
  }

  static function buildColorJson(colorMult:Array<Float>, colorAdd:Array<Float>):ColorJson
  {
    return cast {
      M: 'AD',
      RM: colorMult[0],
      GM: colorMult[1],
      BM: colorMult[2],
      AM: colorMult[3],
      RO: colorAdd[0],
      GO: colorAdd[1],
      BO: colorAdd[2],
      AO: colorAdd[3]
    };
  }

  static function equalsFrame(a:Null<RawFrame>, b:Null<RawFrame>):Bool
  {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;

    return
      a.charId == b.charId
      && a.matrix.a == b.matrix.a
      && a.matrix.b == b.matrix.b
      && a.matrix.c == b.matrix.c
      && a.matrix.d == b.matrix.d
      && a.matrix.tx == b.matrix.tx
      && a.matrix.ty == b.matrix.ty
      && a.colorMult[3] == b.colorMult[3]
      && a.colorAdd[0] == b.colorAdd[0]
      && a.blendMode == b.blendMode
      && a.filters == b.filters;
  }

  static function buildFrameJson(startFrame:Int, duration:Int, frame:Null<RawFrame>, doc:Document, ?label:String):FrameJson
  {
    var elements:Array<ElementJson> = [];

    if (frame != null)
    {
      var mx:Array<Float> = [
        frame.matrix.a,
        frame.matrix.b,
        frame.matrix.c,
        frame.matrix.d,
        frame.matrix.tx / 20.0,
        frame.matrix.ty / 20.0
      ];

      var shape:Null<Shape> = doc.shapes.get(frame.charId);
      if (shape != null && shape.bitmapId != null)
      {
        var combined = new FlxMatrix(
          shape.bitmapMatrix.a / 20.0,
          shape.bitmapMatrix.b / 20.0,
          shape.bitmapMatrix.c / 20.0,
          shape.bitmapMatrix.d / 20.0,
          shape.bitmapMatrix.tx,
          shape.bitmapMatrix.ty
        );
        combined.concat(frame.matrix);

        elements.push(cast {
          ASI: {
            N: 'swf_bitmap_${shape.bitmapId}',
            MX: [
              combined.a,
              combined.b,
              combined.c,
              combined.d,
              combined.tx / 20.0,
              combined.ty / 20.0
            ],
            C: buildColorJson(frame.colorMult, frame.colorAdd)
          }
        });
      }
      else if (doc.shapes.exists(frame.charId))
      {
        elements.push(cast {
          ASI: {
            N: 'swf_shape_${frame.charId}',
            MX: mx,
            C: buildColorJson(frame.colorMult, frame.colorAdd)
          }
        });
      }
      else if (doc.bitmaps.exists(frame.charId))
      {
        elements.push(cast {
          ASI: {
            N: 'swf_bitmap_${frame.charId}',
            MX: mx,
            C: buildColorJson(frame.colorMult, frame.colorAdd)
          }
        });
      }
      else if (doc.sprites.exists(frame.charId))
      {
        elements.push(cast {
          SI: {
            SN: makeSymbolName(frame.charId),
            ST: 'MC',
            MX: mx,
            FF: 0,
            LF: -1,
            C: buildColorJson(frame.colorMult, frame.colorAdd),
            B: Blend.fromInt(frame.blendMode),
            F: frame.filters
          }
        });
      }
    }

    return cast {
      I: startFrame,
      DU: duration,
      N: label ?? '',
      E: elements
    };
  }
}
