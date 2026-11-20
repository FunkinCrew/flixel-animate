package animate.internal.swf;

import animate.internal.swf.ShapeTypes.Fill;
import animate.internal.swf.ShapeTypes.Shape;
import animate.internal.swf.ShapeTypes.Stroke;
import flixel.math.FlxMath;
import flixel.math.FlxMatrix;
import flixel.math.FlxRect;
import format.swf.Data;
import hxGeomAlgo.Tess2;
import hxGeomAlgo.Tess2.WindingRule;
import flixel.util.FlxColor;
import openfl.Vector;

using Lambda;

class ShapeParser
{
   /**
   * Build a new `Shape` instance from raw SWF data
   * @param characterId The character ID of the shape
   * @param data The raw SWF data
   * @return The new `Shape` instance
   */
  public static function parse(characterId:Int, data:ShapeData):Shape
  {
    return switch (data)
    {
      case SHDShape1(bounds, shapes), SHDShape2(bounds, shapes), SHDShape3(bounds, shapes):
        buildShape(characterId, toFlxRect(bounds), shapes, WindingRule.ODD);
      case SHDShape4(d):
        buildShape(characterId, toFlxRect(d.shapeBounds), d.shapes, d.useWinding ? WindingRule.NON_ZERO : WindingRule.ODD);
    }
  }

  static inline function toFlxRect(r:Rect):FlxRect return FlxRect.get(r.left / 20.0, r.top / 20.0, (r.right - r.left) / 20.0, (r.bottom - r.top) / 20.0);

  static function buildShape(characterId:Int, bounds:FlxRect, styleData:ShapeWithStyleData, windingRule:WindingRule):Shape
  {
    var shape:Shape = new Shape(characterId, bounds);
    for (fs in styleData.fillStyles)
    {
      switch (fs)
      {
        case FSBitmap(cid, mat, _, _):
          shape.bitmapId = cid;
          shape.bitmapMatrix = Document.convertMatrix(mat);
        default:
      }
    }

    var fillStyles:Array<FillStyle> = styleData.fillStyles.copy();
    var lineStyles:Array<RawLineStyle> = styleData.lineStyles.map(resolveLineStyle);

    var allFillStyles:Array<FillStyle> = fillStyles.copy();
    var allLineStyles:Array<RawLineStyle> = lineStyles.copy();

    var fill0Edges:Map<Int, Array<FlatEdge>> = new Map<Int, Array<FlatEdge>>();
    var fill1Edges:Map<Int, Array<FlatEdge>> = new Map<Int, Array<FlatEdge>>();
    var lineEdges:Map<Int, Array<FlatEdge>> = new Map<Int, Array<FlatEdge>>();

    var x:Int = 0;
    var y:Int = 0;
    var fillStyle0:Int = 0;
    var fillStyle1:Int = 0;
    var lineStyle:Int = 0;
    var fillBase:Int = 0;
    var lineBase:Int = 0;

    inline function addEdge(map:Map<Int, Array<FlatEdge>>, style:Int, x0:Int, y0:Int, x1:Int, y1:Int):Void
    {
      if (style == 0) return;
      var list = map.get(style);
      if (list == null)
      {
        list = [];
        map.set(style, list);
      }
      list.push({x0: x0, y0: y0, x1: x1, y1: y1});
    }

    inline function emitStraight(x0:Int, y0:Int, x1:Int, y1:Int):Void
    {
      addEdge(fill1Edges, fillStyle1, x0, y0, x1, y1);
      addEdge(fill0Edges, fillStyle0, x1, y1, x0, y0);
      addEdge(lineEdges, lineStyle, x0, y0, x1, y1);
    }

    inline function flattenQuadratic(x0:Int, y0:Int, cx:Int, cy:Int, x1:Int, y1:Int):Void
    {
      var chord = FlxMath.vectorLength(x1 - x0, y1 - y0);
      var deviation = FlxMath.vectorLength(cx - (x0 + x1) / 2, cy - (y0 + y1) / 2);
      var segs = Std.int(FlxMath.bound(Math.sqrt(chord + deviation * 2) / 6, 1, 16));
      var px = x0;
      var py = y0;
      for (i in 1...segs + 1)
      {
        var t = i / segs;
        var mt = 1 - t;
        var nx = mt * mt * x0 + 2 * mt * t * cx + t * t * x1;
        var ny = mt * mt * y0 + 2 * mt * t * cy + t * t * y1;
        var ix = Math.round(nx);
        var iy = Math.round(ny);
        emitStraight(px, py, ix, iy);
        px = ix;
        py = iy;
      }
    }

    for (rec in styleData.shapeRecords)
    {
      switch (rec)
      {
        case SHREnd:
          break;

        case SHRChange(chg):
          if (chg.moveTo != null)
          {
            x = chg.moveTo.dx;
            y = chg.moveTo.dy;
          }
          if (chg.fillStyle0 != null)
          {
            var raw = chg.fillStyle0.idx;
            fillStyle0 = raw == 0 ? 0 : fillBase + raw;
          }
          if (chg.fillStyle1 != null)
          {
            var raw = chg.fillStyle1.idx;
            fillStyle1 = raw == 0 ? 0 : fillBase + raw;
          }
          if (chg.lineStyle != null)
          {
            var raw = chg.lineStyle.idx;
            lineStyle = raw == 0 ? 0 : lineBase + raw;
          }
          if (chg.newStyles != null)
          {
            fillBase += fillStyles.length;
            lineBase += lineStyles.length;
            fillStyles = chg.newStyles.fillStyles;
            lineStyles = chg.newStyles.lineStyles.map(resolveLineStyle);
            for (fs in fillStyles) allFillStyles.push(fs);
            for (ls in lineStyles) allLineStyles.push(ls);
          }

        case SHREdge(dx, dy):
          var nx = x + dx;
          var ny = y + dy;
          emitStraight(x, y, nx, ny);
          x = nx;
          y = ny;

        case SHRCurvedEdge(cdx, cdy, adx, ady):
          var cx = x + cdx;
          var cy = y + cdy;
          var ax = cx + adx;
          var ay = cy + ady;
          flattenQuadratic(x, y, cx, cy, ax, ay);
          x = ax;
          y = ay;
      }
    }

    var usedStyleIndices:Map<Int, Bool> = new Map<Int, Bool>();
    for (k in fill1Edges.keys()) usedStyleIndices.set(k, true);
    for (k in fill0Edges.keys()) usedStyleIndices.set(k, true);
    var sortedStyleIndices = [for (k in usedStyleIndices.keys()) k];
    sortedStyleIndices.sort((a, b) -> a - b);

    for (styleIndex in sortedStyleIndices)
    {
      var edges:Array<FlatEdge> = [];
      var e1 = fill1Edges.get(styleIndex);
      if (e1 != null) for (e in e1) edges.push(e);
      var e0 = fill0Edges.get(styleIndex);
      if (e0 != null) for (e in e0) edges.push(e);

      if (edges.length == 0) continue;

      var loops:Array<Array<Int>> = connectEdges(edges);
      if (loops.length == 0) continue;

      var style:Null<FillStyle> = styleIndex >= 1 && styleIndex <= allFillStyles.length ? allFillStyles[styleIndex - 1] : null;
      loopsToFill(loops, style, windingRule, shape.fills);
    }

    var sortedLineIndices:Array<Int> = [for (k in lineEdges.keys()) k];
    sortedLineIndices.sort((a, b) -> a - b);
    for (styleIndex in sortedLineIndices)
    {
      var edges = lineEdges.get(styleIndex);
      if (edges == null || edges.length == 0) continue;
      var style = styleIndex >= 1 && styleIndex <= allLineStyles.length ? allLineStyles[styleIndex - 1] : null;
      if (style == null) continue;
      makeStroke(edges, style, shape.strokes);
    }

    return shape;
  }

  static function getFillColors(fs:Null<FillStyle>, vertices:Array<Float>):Vector<Int>
  {
    var color = 0xFFFFFFFF;
    var gradient:Null<Gradient> = null;
    var matrix = new FlxMatrix();
    var radial = false;
    var focal = 0.0;

    switch (fs)
    {
      case null: color = 0xFFFF00FF;
      case FSSolid(rgb): color = FlxColor.fromRGB(rgb.r, rgb.g, rgb.b);
      case FSSolidAlpha(rgba): color = FlxColor.fromRGB(rgba.r, rgba.g, rgba.b, rgba.a);
      case FSBitmap(_, _, _, _): color = 0xFF808080;
      case FSLinearGradient(mat, grad):
        gradient = grad;
        matrix = Document.convertMatrix(mat);
      case FSRadialGradient(mat, grad):
        gradient = grad;
        matrix = Document.convertMatrix(mat);
        radial = true;
      case FSFocalGradient(mat, grad):
        gradient = grad.data;
        matrix = Document.convertMatrix(mat);
        radial = true;
        focal = grad.focalPoint / 256;
    }

    var colors = new Vector<Int>(Std.int(vertices.length / 2));
    if (gradient == null || gradient.data.length == 0)
    {
      for (i in 0...colors.length) colors[i] = color;
      return colors;
    }

    var ratios:Array<Float> = [];
    var stops:Array<FlxColor> = [];
    for (stop in gradient.data)
    {
      switch (stop)
      {
        case GRRGB(pos, rgb):
          ratios.push(pos / 255);
          stops.push(FlxColor.fromRGB(rgb.r, rgb.g, rgb.b));
        case GRRGBA(pos, rgba):
          ratios.push(pos / 255);
          stops.push(FlxColor.fromRGB(rgba.r, rgba.g, rgba.b, rgba.a));
      }
    }

    matrix.invert();
    for (i in 0...colors.length)
    {
      var x = matrix.transformX(vertices[i * 2], vertices[i * 2 + 1]) / 16384;
      var y = matrix.transformY(vertices[i * 2], vertices[i * 2 + 1]) / 16384;
      var ratio = radial ? Math.sqrt(x * x + y * y) : (x + 1) * 0.5;
      if (focal != 0)
      {
        var dx = x - focal;
        ratio = (Math.sqrt(dx * dx + y * y) - focal * dx) / (1 - focal * focal);
      }
      ratio = switch (gradient.spread)
      {
        case SMRepeat: ratio - Math.floor(ratio);
        case SMReflect:
          var folded = ratio - 2 * Math.floor(ratio / 2);
          folded > 1 ? 2 - folded : folded;
        default: FlxMath.bound(ratio, 0, 1);
      };

      var next = 0;
      while (next < ratios.length && ratios[next] < ratio) next++;
      if (next == 0) colors[i] = stops[0];
      else if (next == ratios.length) colors[i] = stops[next - 1];
      else
      {
        var span = ratios[next] - ratios[next - 1];
        colors[i] = span == 0 ? stops[next] : FlxColor.interpolate(stops[next - 1], stops[next], (ratio - ratios[next - 1]) / span);
      }
    }
    return colors;
  }

  static function resolveLineStyle(ls:LineStyle):RawLineStyle
  {
    var fill:FillStyle = switch (ls.data)
    {
      case LSRGB(rgb): FSSolid(rgb);
      case LSRGBA(rgba): FSSolidAlpha(rgba);
      case LS2(d):
        switch (d.fill)
        {
          case null: FSSolidAlpha({r: 255, g: 255, b: 255, a: 255});
          case LS2FColor(c): FSSolidAlpha(c);
          case LS2FStyle(fs): fs;
        }
    }
    return {widthTwips: ls.width, fill: fill};
  }

  static function connectEdges(edges:Array<FlatEdge>):Array<Array<Int>>
  {
    var used = [for (i in 0...edges.length) false];

    var startMap = new Map<String, Array<Int>>();
    for (i in 0...edges.length)
    {
      var e = edges[i];
      var k = e.x0 + '_' + e.y0;
      var list = startMap.get(k);
      if (list == null)
      {
        list = [];
        startMap.set(k, list);
      }
      list.push(i);
    }

    var loops:Array<Array<Int>> = [];

    for (startIdx in 0...edges.length)
    {
      if (used[startIdx]) continue;

      var loopPoints:Array<Int> = [];
      var currentIdx = startIdx;
      var loopStartKey = edges[startIdx].x0 + '_' + edges[startIdx].y0;
      var guard = 0;
      var maxSteps = edges.length + 1;

      while (currentIdx != -1 && guard < maxSteps)
      {
        guard++;
        var e = edges[currentIdx];
        used[currentIdx] = true;
        loopPoints.push(e.x0);
        loopPoints.push(e.y0);

        if (e.x1 + '_' + e.y1 == loopStartKey)
        {
          currentIdx = -1;
          break;
        }

        var candidates = startMap.get(e.x1 + '_' + e.y1);
        var next = -1;
        if (candidates != null)
        {
          for (c in candidates)
          {
            if (!used[c])
            {
              next = c;
              break;
            }
          }
        }
        currentIdx = next;
      }

      if (loopPoints.length >= 6) loops.push(loopPoints);
    }

    return loops;
  }

  static function loopsToFill(loops:Array<Array<Int>>, fillStyle:Null<FillStyle>, windingRule:WindingRule, outFills:Array<Fill>):Void
  {
    var tess = Tess2.tesselate([for (loop in loops) [for (point in loop) point]], windingRule);
    if (tess.elements.length > 0)
      outFills.push(new Fill(getFillColors(fillStyle, tess.vertices), tess.vertices, tess.elements));
  }

  static function makeStroke(edges:Array<FlatEdge>, style:RawLineStyle, outStrokes:Array<Stroke>):Void
  {
    var halfWidth = FlxMath.bound(style.widthTwips, 20.0) / 2;
    var vertices:Array<Float> = [];
    var indices:Array<Int> = [];

    for (e in edges)
    {
      var dx = e.x1 - e.x0;
      var dy = e.y1 - e.y0;
      var len = FlxMath.vectorLength(dx, dy);
      if (len == 0) continue;
      var nx = -dy / len * halfWidth;
      var ny = dx / len * halfWidth;

      var baseIndex = Std.int(vertices.length / 2);
      vertices.push(e.x0 + nx);
      vertices.push(e.y0 + ny);
      vertices.push(e.x0 - nx);
      vertices.push(e.y0 - ny);
      vertices.push(e.x1 - nx);
      vertices.push(e.y1 - ny);
      vertices.push(e.x1 + nx);
      vertices.push(e.y1 + ny);

      indices.push(baseIndex);
      indices.push(baseIndex + 1);
      indices.push(baseIndex + 2);
      indices.push(baseIndex);
      indices.push(baseIndex + 2);
      indices.push(baseIndex + 3);
    }

    if (indices.length > 0)
    {
      outStrokes.push(new Stroke(getFillColors(style.fill, vertices), style.widthTwips, vertices, indices));
    }
  }
}

typedef FlatEdge =
{
  x0:Int,
  y0:Int,
  x1:Int,
  y1:Int
}

typedef RawLineStyle =
{
  widthTwips:Float,
  fill:FillStyle
}
