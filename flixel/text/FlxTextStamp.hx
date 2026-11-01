package flixel.text;

import openfl.display.BitmapData;
import openfl.geom.Rectangle;

#if lime_cairo
import lime.graphics.cairo.Cairo;
import lime.graphics.cairo.CairoFilter;
import lime.graphics.cairo.CairoPattern;
import lime.graphics.cairo.CairoSurface;
import lime.math.Matrix3;
#end

/**
 * Cairo compositing pass for FlxText's border and fill.
 *
 * FlxText rasterizes its text exactly once, in the *border* colour, into a scratch bitmap. The
 * border is then that raster painted at every border offset, and the fill is the fill colour
 * painted through the raster's alpha - instead of the historical `1 + 8 * iterations` TextField
 * draws (17 for the HUD's `borderSize = 2`), each of which re-rasterized or re-laid-out the field.
 *
 * The border copies go through `setSourceSurface() + paint()` on purpose: a surface source is
 * resampled at the *fractional* offset (the same bilinear sampling the rasterizer applies when the
 * TextField itself is drawn at that offset), so a 1.5x scale - where the ring sits 1.5 and 3
 * device pixels out - composites pixel-identically to the historical path. `cairo_mask()` samples
 * the pattern nearest-neighbour, which quantizes the ring to whole pixels; at 1.5x that shifted
 * the outline by up to a pixel (666 pixels differing by up to 79/255 in the harness comparison).
 *
 * The pass is clipped to the caller's rectangle, which is what makes an incremental rebuild
 * possible: a clip can only remove contributions outside it, so the pixels inside are exactly
 * what a full redraw would produce.
 *
 * Everything here is a thin wrapper over the lime Cairo API, so the whole class compiles away to
 * `available = false` on targets that do not render through Cairo; FlxText then keeps the plain
 * BitmapData.draw path.
 */
class FlxTextStamp
{
	/** Whether this target can composite; false makes FlxText use the BitmapData.draw path. */
	public static var available(default, null):Bool = #if lime_cairo true #else false #end;

	#if lime_cairo
	static var _target:BitmapData;
	static var _targetSurface:CairoSurface;
	static var _cairo:Cairo;
	static var _source:BitmapData;
	static var _sourceSurface:CairoSurface;
	static var _pattern:CairoPattern;
	static var _matrix:Matrix3;

	/**
	 * Starts a compositing pass: `source` (the rasterized text) is painted onto `target`, clipped
	 * to `clip` (null = the whole bitmap). Returns false when either bitmap has no Cairo surface.
	 */
	public static function begin(target:BitmapData, source:BitmapData, clip:Rectangle):Bool
	{
		if (target == null || source == null)
			return false;

		var ts:CairoSurface = target.getSurface();
		var ss:CairoSurface = source.getSurface();
		if (ts == null || ss == null)
			return false;

		if (_target != target || _targetSurface != ts || _cairo == null)
		{
			_cairo = new Cairo(ts);
			_target = target;
			_targetSurface = ts;
		}

		if (_source != source || _sourceSurface != ss || _pattern == null)
		{
			_pattern = CairoPattern.createForSurface(ss);
			// the fill is composited through the mask at an integral offset, so the filter never
			// resamples; NEAREST keeps it exactly the rasterized alpha
			_pattern.filter = CairoFilter.NEAREST;
			_source = source;
			_sourceSurface = ss;
		}

		if (_matrix == null)
			_matrix = new Matrix3();

		_cairo.save();
		if (clip != null)
		{
			_cairo.rectangle(clip.x, clip.y, clip.width, clip.height);
			_cairo.clip();
		}
		return true;
	}

	/**
	 * Paints the border: the raster (already in the border colour) once per offset.
	 * `bx`/`by` place the raster on the target; `offsets` are the (x, y) pairs of FlxText.
	 */
	public static function border(offsets:Array<Float>, bx:Float, by:Float):Void
	{
		// the offset goes into the pattern, not the CTM: setSourceSurface() + paint() composites
		// the fragment at a fractional position exactly like the surface translated by the CTM,
		// without a save/translate/restore pair per offset
		var i:Int = 0;
		while (i < offsets.length)
		{
			_cairo.setSourceSurface(_sourceSurface, bx + offsets[i], by + offsets[i + 1]);
			_cairo.paint();
			i += 2;
		}
	}

	/**
	 * Paints the fill: the fill colour through the raster's alpha, at the raster's own place in the
	 * target (an integral offset, so the composition is exact).
	 */
	public static function fill(color:Int, bx:Float, by:Float):Void
	{
		// the text renderer treats TextFormat.color as RGB (its alpha is not used), so the fill is
		// opaque here as well
		_cairo.save();
		_cairo.translate(bx, by);
		_cairo.setSourceRGBA(((color >> 16) & 0xFF) / 255, ((color >> 8) & 0xFF) / 255, (color & 0xFF) / 255, 1);
		_cairo.mask(_pattern);
		_cairo.restore();
	}

	/** Ends the pass and makes the writes visible to the renderer's texture cache. */
	public static function end():Void
	{
		_cairo.restore();
		_cairo.target.flush();

		var image = _target.image;
		if (image != null)
		{
			image.dirty = true;
			image.version++;
		}
	}
	#else
	public static function begin(target:BitmapData, source:BitmapData, clip:Rectangle):Bool
	{
		return false;
	}

	public static function border(offsets:Array<Float>, bx:Float, by:Float):Void
	{}

	public static function fill(color:Int, bx:Float, by:Float):Void
	{}

	public static function end():Void
	{}
	#end
}
