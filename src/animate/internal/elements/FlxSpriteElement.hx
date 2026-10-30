package animate.internal.elements;

import animate.FlxAnimate;
import flixel.FlxBasic;
import flixel.FlxCamera;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.math.FlxMatrix;
import flixel.math.FlxPoint;
import flixel.math.FlxRect;
import flixel.util.FlxDestroyUtil;
import openfl.display.BlendMode;
import openfl.geom.ColorTransform;

using flixel.util.FlxColorTransformUtil;

class FlxSpriteElement extends FlxTypedElement<FlxSprite>
{
	var _colorTransform:ColorTransform = null;
	var _antialiasing:Bool = false;
	var _blend:BlendMode = null;
	var _point:FlxPoint = null;
	var _screenPoint:FlxPoint = null;
	var _angle:Float = 0.0;
	var _scale:FlxPoint = null;
	var _spriteMatrix:FlxMatrix = null;

	public function new(?sprite:FlxSprite)
	{
		super(sprite);

		this._colorTransform = new ColorTransform();
		this._point = FlxPoint.get();
		this._screenPoint = FlxPoint.get();
		this._scale = FlxPoint.get();
		this._spriteMatrix = new FlxMatrix();
	}

	override function destroy():Void
	{
		super.destroy();
		_colorTransform = null;
		_point = FlxDestroyUtil.put(_point);
		_screenPoint = FlxDestroyUtil.put(_screenPoint);
		_scale = FlxDestroyUtil.put(_scale);
		_spriteMatrix = null;
	}

	override function applyObjectTransform(camera:FlxCamera, parentMatrix:FlxMatrix, ?command:AnimateDrawCommand)
	{
		_scale.copyFrom(basic.scale);

		var hasTransform = transform != null;
		if (hasTransform)
		{
			if (transform.alphaMultiplier <= 0.0)
				return;

			var color = basic.colorTransform;
			if (color == null)
			{
				_transform.setMultipliers(1, 1, 1, 1);
				_transform.setOffsets(0, 0, 0, 0);
			}
			else
			{
				AnimateDrawCommand.copyTransform(_transform, color);
			}
		}

		_blend = basic.blend;
		_point.set(basic.x, basic.y);
		_angle = basic.angle;
		_blend = basic.blend;
		_antialiasing = basic.antialiasing;

		AnimateDrawCommand.copyTransform(_colorTransform, basic.colorTransform);

		// apply transformations
		super.applyObjectTransform(camera, parentMatrix, command);

		drawCommand.prepareCommand(command, this);

		var spriteMatrix = _spriteMatrix;
		spriteMatrix.identity();

		var parentSprite = command.parentSprite;
		@:privateAccess
		if (parentSprite != null && !parentSprite.checkRenderTexture())
			parentSprite.prepareAnimateMatrix(spriteMatrix, camera, parentSprite.timeline._bounds);

		var determinant = spriteMatrix.a * spriteMatrix.d - spriteMatrix.b * spriteMatrix.c;
		var flipSign = determinant < 0 ? -1 : 1;
		var spriteScale = Math.sqrt(Math.abs(determinant));

		var pivotX = basic.origin.x - basic.offset.x;
		var pivotY = basic.origin.y - basic.offset.y;

		var x = parentMatrix.transformX(basic.x, basic.y) + spriteMatrix.a * pivotX + spriteMatrix.c * pivotY - pivotX;
		var y = parentMatrix.transformY(basic.x, basic.y) + spriteMatrix.b * pivotX + spriteMatrix.d * pivotY - pivotY;

		basic.setPosition(0, 0);
		var screenPoint = basic.getScreenPosition(_screenPoint, camera);
		basic.setPosition(x - screenPoint.x, y - screenPoint.y);

		var symbolX = (spriteMatrix.d * parentMatrix.a - spriteMatrix.c * parentMatrix.b) * flipSign;
		var symbolY = (spriteMatrix.a * parentMatrix.b - spriteMatrix.b * parentMatrix.a) * flipSign;
		var symbolAngle = basic.angle + Math.atan2(symbolY, symbolX) * 180 / Math.PI;

		basic.angle = Math.atan2(spriteMatrix.b, spriteMatrix.a) * 180 / Math.PI + symbolAngle * flipSign;
		basic.scale.set(basic.scale.x * spriteScale, basic.scale.y * spriteScale * flipSign);

		if (isColored)
			basic.colorTransform.concat(_transform);

		basic.blend = command.blend;
		basic.antialiasing = basic.antialiasing || command.antialiasing;
		basic.camera = camera;
	}

	override function resetObjectTransform()
	{
		super.resetObjectTransform();

		basic.setPosition(_point.x, _point.y);
		basic.angle = _angle;
		basic.scale.copyFrom(_scale);
		basic.blend = _blend;
		basic.camera = _camera;
		basic.antialiasing = _antialiasing;

		var transform = basic.colorTransform;
		transform.redMultiplier = _colorTransform.redMultiplier;
		transform.greenMultiplier = _colorTransform.greenMultiplier;
		transform.blueMultiplier = _colorTransform.blueMultiplier;
		transform.alphaMultiplier = _colorTransform.alphaMultiplier;

		transform.redOffset = _colorTransform.redOffset;
		transform.greenOffset = _colorTransform.greenOffset;
		transform.blueOffset = _colorTransform.blueOffset;
		transform.alphaOffset = _colorTransform.alphaOffset;
	}

	override function draw(camera:FlxCamera, index:Int, frameIndex:Int, parentMatrix:FlxMatrix, ?command:AnimateDrawCommand)
	{
		if (basic == null || basic.alpha <= 0)
			return;

		super.draw(camera, index, frameIndex, parentMatrix, command);
	}

	override function getObjectBounds(?result:FlxRect):FlxRect
	{
		#if (flixel >= "5.0.0")
		return basic.getScreenBounds(result);
		#else
		return (result != null) ? result.set() : FlxRect.get();
		#end
	}
}

typedef FlxBasicElement = FlxTypedElement<FlxBasic>;

class FlxTypedElement<T:FlxBasic> extends Element
{
	public var basic:T;
	public var active:Bool = true;
	public var destroyObject:Bool = false;
	public var owner:Null<FlxAnimate> = null;

	var _camera:FlxCamera;

	public function new(?basic:T)
	{
		super(null, null, null);
		this.basic = basic;
	}

	override function destroy():Void
	{
		super.destroy();
		if (destroyObject)
			FlxDestroyUtil.destroy(basic);
		basic = null;
		owner = null;
		_camera = null;
	}

	function applyObjectTransform(camera:FlxCamera, parentMatrix:FlxMatrix, ?command:AnimateDrawCommand)
	{
		basic.camera = camera;
	}

	function resetObjectTransform()
	{
		basic.camera = _camera;
	}

	override function draw(camera:FlxCamera, index:Int, frameIndex:Int, parentMatrix:FlxMatrix, ?command:AnimateDrawCommand)
	{
		if (basic == null || !basic.visible)
			return;

		if (owner != null && (command == null || command.parentSprite != owner))
			return;

		_camera = basic.camera;

		if (active)
			basic.update(FlxG.elapsed);

		applyObjectTransform(camera, parentMatrix, command);

		basic.draw();

		resetObjectTransform();
	}

	function getObjectBounds(?result:FlxRect):FlxRect
	{
		return result;
	}

	override function getBounds(frameIndex:Int, ?rect:FlxRect, ?matrix:FlxMatrix, includeFilters:Bool = true, useCachedBounds:Bool = false):FlxRect
	{
		var bounds = super.getBounds(frameIndex, rect, matrix, includeFilters);

		if (basic != null)
			bounds = getObjectBounds(bounds);

		Timeline.applyMatrixToRect(bounds, matrix);

		return bounds;
	}
}
