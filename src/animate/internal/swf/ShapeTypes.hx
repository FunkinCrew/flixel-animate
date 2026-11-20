package animate.internal.swf;

import openfl.Vector;
import flixel.math.FlxRect;
import flixel.math.FlxMatrix;
import flixel.util.FlxDestroyUtil;

typedef MeshData =
{
  verts:Vector<Float>,
  indices:Vector<Int>,
  colors:Vector<Int>
}

class Fill
{
  public var colors:Vector<Int>;
  public var vertices:Array<Float>;
  public var indices:Array<Int>;

  var _mesh:MeshData;

  public function new(colors:Vector<Int>, vertices:Array<Float>, indices:Array<Int>)
  {
    this.colors = colors;
    this.vertices = vertices;
    this.indices = indices;
  }

  public function getMesh():Null<MeshData>
  {
    if (_mesh == null) _mesh = buildMesh();

    return _mesh;
  }

  inline function buildMesh():MeshData
  {
    return {verts: Vector.ofArray([for (v in vertices) v / 20.0]), indices: Vector.ofArray(indices), colors: colors};
  }

  public function destroy():Void
  {
    vertices = null;
    indices = null;
    colors = null;
    _mesh = null;
  }
}

class Stroke extends Fill
{
  public var widthTwips:Float;

  public function new(colors:Vector<Int>, widthTwips:Float, vertices:Array<Float>, indices:Array<Int>)
  {
    super(colors, vertices, indices);
    this.widthTwips = widthTwips;
  }
}

class Shape
{
  public var characterId:Int;
  public var bounds:FlxRect;
  public var fills:Array<Fill>;
  public var strokes:Array<Stroke>;
  public var bitmapId:Null<Int> = null;
  public var bitmapMatrix:Null<FlxMatrix> = null;

  var _meshes:Array<MeshData>;

  public function new(characterId:Int, bounds:FlxRect)
  {
    this.characterId = characterId;
    this.bounds = bounds;
    this.fills = [];
    this.strokes = [];
  }

  public function getMeshes():Array<MeshData>
  {
    if (_meshes == null)
    {
      _meshes = [];

      if (fills != null)
      {
        for (fill in fills)
        {
          var mesh:Null<MeshData> = fill.getMesh();
          if (mesh != null) _meshes.push(mesh);
        }
      }

      if (strokes != null)
      {
        for (stroke in strokes)
        {
          var mesh:Null<MeshData> = stroke.getMesh();
          if (mesh != null) _meshes.push(mesh);
        }
      }
    }

    return _meshes;
  }

  public function destroy():Void
  {
    if (fills != null)
    {
      for (fill in fills) fill.destroy();
    }

    if (strokes != null)
    {
      for (stroke in strokes) stroke.destroy();
    }

    fills = null;
    strokes = null;
    bounds = FlxDestroyUtil.put(bounds);
    _meshes = null;
  }
}
