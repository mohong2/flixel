package flixel.text;

import flash.display.BitmapData;
import flash.geom.ColorTransform;
import flash.text.TextField;
import flash.text.TextFieldAutoSize;
import flash.text.TextFormat;
import flash.text.TextFormatAlign;
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.graphics.FlxGraphic;
import flixel.graphics.atlas.FlxAtlas;
import flixel.graphics.atlas.FlxNode;
import flixel.graphics.frames.FlxFramesCollection;
import flixel.graphics.frames.FlxImageFrame;
import flixel.math.FlxMath;
import flixel.math.FlxPoint;
import flixel.math.FlxRect;
import flixel.system.FlxAssets;
import flixel.util.FlxColor;
import flixel.util.FlxDestroyUtil;
import flixel.util.helpers.FlxRange;
import openfl.Assets;
import openfl.geom.Point;
import openfl.geom.Rectangle;

using flixel.util.FlxStringUtil;
using flixel.util.FlxUnicodeUtil;

#if (openfl >= "8.0.0")
import openfl.utils.AssetType;
import openfl.utils.ByteArray;
#end

// TODO: think about filters and text

/**
 * Extends FlxSprite to support rendering text. Can tint, fade, rotate and scale just like a sprite. Doesn't really animate
 * though. Also does nice pixel-perfect centering on pixel fonts as long as they are only one-liners.
 */
class FlxText extends FlxSprite
{
	/**
	 * 2px gutter on both top and bottom
	 */
	static inline var VERTICAL_GUTTER:Int = 4;

	/** Transparent margin around the glyph box in the border scratch bitmap, in device pixels. */
	static inline var TEXT_PAD:Int = 2;

	/**
	 * How long the content signature has to stay unchanged before the finished bitmap is moved
	 * into the shared page (see `considerPageStamp()`).
	 *
	 * Long enough that the burst of `setFormat`/`text` calls a state does while it builds its
	 * HUD never reaches the page, short enough that a line that is genuinely static is packed
	 * before the player looks at it.
	 */
	static inline var PAGE_SETTLE_MS:Float = 750;

	/**
	 * How often a text may leave the page before it is kept private for good.
	 *
	 * Once is expected: the render scale settles shortly after boot and re-rasterizes every
	 * text at the final scale. Twice or more means the line keeps changing, and cycling it in
	 * and out of the page would cost a page copy and a texture upload each time.
	 */
	static inline var MAX_PAGE_DETACHES:Int = 1;

	/**
	 * The text being displayed.
	 */
	public var text(default, set):String = "";

	/**
	 * The size of the text being displayed in pixels.
	 */
	public var size(get, set):Int;

	/**
	 * The font used for this text (assuming that it's using embedded font).
	 */
	public var font(get, set):String;

	/**
	 * Whether this text field uses an embedded font (by default) or not.
	 * Read-only - use `systemFont` to specify a system font to use, which then automatically sets this to `false`.
	 */
	public var embedded(get, never):Bool;

	/**
	 * The system font for this text (not embedded). Setting this sets `embedded` to `false`.
	 * Passing an invalid font name (like `""` or `null`) causes a default font to be used.
	 */
	public var systemFont(get, set):String;

	/**
	 * Whether to use bold text or not (`false` by default).
	 */
	public var bold(get, set):Bool;

	/**
	 * Whether to use italic text or not (`false` by default). Only works on Flash.
	 */
	public var italic(get, set):Bool;

	/**
	 * Whether to use word wrapping and multiline or not (`true` by default).
	 */
	public var wordWrap(get, set):Bool;

	/**
	 * The alignment of the font. Note: `autoSize` must be set to
	 * `false` or `alignment` won't show any visual differences.
	 */
	public var alignment(get, set):FlxTextAlign;

	/**
	 * The border style to use
	 */
	public var borderStyle(default, set):FlxTextBorderStyle = NONE;

	/**
	 * Upper bound for this text's rasterization scale (see `getTextRenderScale`). `0` keeps the
	 * automatic scale, i.e. the historical behaviour.
	 *
	 * Why: the bitmap is re-rendered whenever the text changes, and the cost grows with the
	 * *square* of the rasterization scale (every glyph pass, including each border offset, is
	 * repeated into a bigger bitmap). At a 1.5x window scale a HUD line costs 2.25x more than at
	 * 1x; at a 3x mobile scale it costs 9x. For HUD lines that are rebuilt on every note hit
	 * (score / accuracy / ms readout / stat counters) capping this to 1 keeps the update at the
	 * game's own resolution - the resolution the rest of the world is drawn at anyway - and is the
	 * difference between a visible hitch and no hitch at all.
	 */
	public var renderScaleCap:Float = 0;


	/**
	 * The color of the border in `0xAARRGGBB` format
	 */
	public var borderColor(default, set):FlxColor = FlxColor.TRANSPARENT;

	/**
	 * The size of the border, in pixels.
	 */
	public var borderSize(default, set):Float = 1;

	/**
	 * How many iterations do use when drawing the border. `0`: only 1 iteration, `1`: one iteration for every pixel in `borderSize`
	 * A value of `1` will have the best quality for large border sizes, but might reduce performance when changing text.
	 * NOTE: If the `borderSize` is `1`, `borderQuality` of `0` or `1` will have the exact same effect (and performance).
	 */
	public var borderQuality(default, set):Float = 1;

	/**
	 * Reference to a `TextField` object used internally for rendering -
	 * be sure to know what you're doing if messing with its properties!
	 */
	public var textField(default, null):TextField;

	/**
	 * The width of the `TextField` object used for bitmap generation for this `FlxText` object.
	 * Use it when you want to change the visible width of text. Enables `autoSize` if `<= 0`.
	 */
	public var fieldWidth(get, set):Float;

	/**
	 * Whether the `fieldWidth` should be determined automatically. Requires `wordWrap` to be `false`.
	 */
	public var autoSize(get, set):Bool;

	/**
	 * Offset that is applied to the shadow border style, if active.
	 * `x` and `y` are multiplied by `borderSize`. Default is `(1, 1)`, or lower-right corner.
	 */
	public var shadowOffset(default, null):FlxPoint;

	var _defaultFormat:TextFormat;
	var _formatAdjusted:TextFormat;
	var _formatRanges:Array<FlxTextFormatRange> = [];
	var _font:String;

	/**
	 * Helper boolean which tells whether to update graphic of this text object or not.
	 */
	var _regen:Bool = true;

	/**
	 * Content signature of the bitmap that is currently rasterized (see `contentSignature()`),
	 * or `null` when the bitmap is not known to match the current inputs.
	 *
	 * `_regen` only says "someone asked for a rebuild"; it is set for inputs that are re-applied
	 * unchanged (a repeated `setFormat`, a `fieldWidth` write, a render-scale re-read), and
	 * rebuilding on those re-rasterizes the whole TextField for a bitmap that would not change a
	 * pixel. This signature is what actually decides whether a rebuild has any work to do.
	 */
	var _rasterSig:String;

	/** `FlxG.game.ticks` at the last rasterization, used by the static-text settle timer. */
	var _rasterAt:Float = 0;

	/** Cell this text holds in the shared page, `null` while it owns a private bitmap. */
	var _pageCell:FlxRect;

	/** Size of the bitmap the cell holds, i.e. the text's own size without the cell padding. */
	var _pageW:Int = 0;
	var _pageH:Int = 0;

	/** Whether this text has been refused by the page and must not ask again. */
	var _pageBanned:Bool = false;

	/** How often this text left the page, i.e. how often it changed after being packed. */
	var _pageDetaches:Int = 0;

	/** Page that owns `_pageCell`. */
	var _page:FlxTextPage;

	/** Scratch rectangle/point for copying a page cell back into a private bitmap. */
	static var _pageCopy:Rectangle = new Rectangle();
	static var _pageCopyAt:Point = new Point(0, 0);



	/**
	 * Rasterization scale for the current text bitmap.
	 * 1 keeps the original path; higher values keep text crisp when scaled up.
	 */
	var _textRenderScale:Float = 1;

	/**
	 * Helper vars to draw border styles with transparency.
	 */
	var _borderPixels:BitmapData;

	var _borderColorTransform:ColorTransform;

	var _hasBorderAlpha = false;

	/**
	 * Scratch bitmap for the border pass: the border-coloured text is rasterized into it once and
	 * then blitted at every border offset, so one rebuild runs the TextField layout and glyph
	 * rasterization twice instead of `1 + 8 * iterations` times. Kept between rebuilds
	 * (disposed in destroy()).
	 */
	var _textCache:BitmapData;

	/** Device-space border stamp offsets for the current style/border/scale; rebuilt when those change. */
	var _borderOffsets:Array<Float>;
	var _borderOffsetsKey:String = "";

	/**
	 * What the pixels in the bitmap currently show, for incremental rebuilds (C-2).
	 *
	 * A rebuild that only replaces one run of characters does not have to repaint the whole line:
	 * the glyphs before and after the run stay exactly where they were, so their pixels are still
	 * correct. The draws are then clipped to the run (see computeDirtyRect()), which is only legal
	 * while every one of these inputs is unchanged - they are what the old pixels were built from.
	 */
	var _rasterText:String;
	var _rasterTextW:Float = 0;
	var _rasterScale:Float = -1;
	var _rasterBorderKey:String = "";
	var _rasterFont:String;
	var _rasterAlign:String;
	var _rasterSize:Null<Int>;
	var _rasterColor:Null<Int>;
	var _rasterLeading:Null<Int>;
	var _rasterBorderColor:FlxColor = 0;
	var _rasterBorderSize:Float = -1;
	var _rasterBorderQuality:Float = -1;
	var _rasterBorderStyle:FlxTextBorderStyle = FlxTextBorderStyle.NONE;
	var _rasterAlignment:FlxTextAlign = FlxTextAlign.LEFT;
	var _rasterFieldW:Float = -1;

	/** Reused storage for the rectangle an incremental rebuild repaints. */
	var _dirtyRect:Rectangle = new Rectangle();


	#if flash
	/**
	 * Helper to draw line by line used at `drawTextFieldTo()`.
	 */
	var _textFieldRect:Rectangle = new Rectangle();
	#end

	/**
	 * Creates a new `FlxText` object at the specified position.
	 *
	 * @param   X              The x position of the text.
	 * @param   Y              The y position of the text.
	 * @param   FieldWidth     The `width` of the text object. Enables `autoSize` if `<= 0`.
	 *                         (`height` is determined automatically).
	 * @param   Text           The actual text you would like to display initially.
	 * @param   Size           The font size for this text object.
	 * @param   EmbeddedFont   Whether this text field uses embedded fonts or not.
	 */
	public function new(X:Float = 0, Y:Float = 0, FieldWidth:Float = 0, ?Text:String, Size:Int = 8, EmbeddedFont:Bool = true)
	{
		super(X, Y);

		if (Text == null || Text == "")
		{
			// empty texts have a textHeight of 0, need to
			// prevent initializing with "" before the first calcFrame() call
			text = "";
			Text = " ";
		}
		else
		{
			text = Text;
		}

		textField = new TextField();
		textField.selectable = false;
		textField.multiline = true;
		textField.wordWrap = true;
		_defaultFormat = new TextFormat(null, Size, 0xffffff);
		font = FlxAssets.FONT_DEFAULT;
		_formatAdjusted = new TextFormat();
		textField.defaultTextFormat = _defaultFormat;
		textField.text = Text;
		fieldWidth = FieldWidth;
		textField.embedFonts = EmbeddedFont;
		textField.sharpness = 100;
		textField.height = (Text.length <= 0) ? 1 : 10;

		allowCollisions = NONE;
		moves = false;

		drawFrame();

		shadowOffset = FlxPoint.get(1, 1);
	}

	/**
	 * Clean up memory.
	 */
	override public function destroy():Void
	{
		if (_pageCell != null && _page != null)
		{
			_page.release(_pageCell);
			_pageCell = null;
			_page = null;
		}

		if (_textCache != null)
		{
			_textCache.dispose();
			_textCache = null;
		}
		textField = null;
		_font = null;
		_defaultFormat = null;
		_formatAdjusted = null;
		shadowOffset = FlxDestroyUtil.put(shadowOffset);
		super.destroy();
	}

	override public function drawFrame(Force:Bool = false):Void
	{
		// A forced redraw is the caller saying the pixels are stale (the public `textField` was
		// poked directly), so it has to bypass the content-signature short circuit.
		if (Force)
			_rasterSig = null;

		_regen = _regen || Force;
		super.drawFrame(_regen);
	}

	/**
	 * Stamps text onto specified atlas object and loads graphic from this atlas.
	 * WARNING: Changing text after stamping it on the atlas will break the atlas, so do it only for
	 * static texts and only after making all the text customizing (like `size`, `alignment`, `color`, etc.)
	 *
	 * @param	atlas	atlas to stamp graphic to.
	 * @return	whether the graphic was stamped on the atlas successfully
	 */
	public function stampOnAtlas(atlas:FlxAtlas):Bool
	{
		regenGraphic();

		var node:FlxNode = atlas.addNode(graphic.bitmap, graphic.key);
		var result:Bool = (node != null);

		if (node != null)
		{
			frames = node.getImageFrame();
		}

		return result;
	}

	/**
	 * Applies formats to text between marker characters, then removes those markers.
	 * NOTE: this will clear all `FlxTextFormat`s and return to the default format.
	 *
	 * Usage:
	 *
	 * ```haxe
	 * text.applyMarkup(
	 * 	"show $green text$ between dollar-signs",
	 * 	[new FlxTextFormatMarkerPair(greenFormat, "$")]
	 * );
	 * ```
	 *
	 * Even works for complex nested formats like this:
	 *
	 * ```haxe
	 * var yellow = new FlxTextFormatMarkerPair(yellowFormat, "@");
	 * var green = new FlxTextFormatMarkerPair(greenFormat, "<g>");
	 * text.applyMarkup("Hey @Buddy@, what <g>is<g> going @on<g>?<g>@", [yellow, green]);
	 * ```
	 *
	 * @param   input   The text you want to format
	 * @param   rules   `FlxTextFormat`s to selectively apply, paired with marker strings
	 */
	public function applyMarkup(input:String, rules:Array<FlxTextFormatMarkerPair>):FlxText
	{
		if (rules == null || rules.length == 0)
			return this; // there's no point in running the big loop

		clearFormats(); // start with default formatting

		var rangeStarts:Array<Int> = [];
		var rangeEnds:Array<Int> = [];
		var rulesToApply:Array<FlxTextFormatMarkerPair> = [];

		var i:Int = 0;
		for (rule in rules)
		{
			if (rule.marker == null || rule.format == null)
				continue;

			var start:Bool = false;
			var markerLength:Int = rule.marker.uLength();

			if (!input.contains(rule.marker))
				continue; // marker not present

			// inspect each character
			for (charIndex in 0...input.uLength())
			{
				if (!input.uSub(charIndex, markerLength).uEquals(rule.marker))
					continue; // it's not one of the markers

				if (start)
				{
					start = false;
					rangeEnds.push(charIndex); // end a format block
				}
				else // we're outside of a format block
				{
					start = true; // start a format block
					rangeStarts.push(charIndex);
					rulesToApply.push(rule);
				}
			}

			if (start)
			{
				// we ended with an unclosed block, mark it as infinite
				rangeEnds.push(-1);
			}

			i++;
		}

		// Remove all of the markers in the string
		for (rule in rules)
			input = input.remove(rule.marker);

		// Adjust all the ranges to reflect the removed markers
		for (i in 0...rangeStarts.length)
		{
			// Consider each range start
			var delIndex:Int = rangeStarts[i];
			var markerLength:Int = rulesToApply[i].marker.uLength();

			// Any start or end index that is HIGHER than this must be subtracted by one markerLength
			for (j in 0...rangeStarts.length)
			{
				if (rangeStarts[j] > delIndex)
				{
					rangeStarts[j] -= markerLength;
				}
				if (rangeEnds[j] > delIndex)
				{
					rangeEnds[j] -= markerLength;
				}
			}

			// Consider each range end
			delIndex = rangeEnds[i];

			// Any start or end index that is HIGHER than this must be subtracted by one markerLength
			for (j in 0...rangeStarts.length)
			{
				if (rangeStarts[j] > delIndex)
				{
					rangeStarts[j] -= markerLength;
				}
				if (rangeEnds[j] > delIndex)
				{
					rangeEnds[j] -= markerLength;
				}
			}
		}

		// Apply the new text
		text = input;

		// Apply each format selectively to the given range
		for (i in 0...rangeStarts.length)
			addFormat(rulesToApply[i].format, rangeStarts[i], rangeEnds[i]);

		return this;
	}

	/**
	 * Adds another format to this `FlxText`
	 *
	 * @param	Format	The format to be added.
	 * @param	Start	The start index of the string where the format will be applied.
	 * @param	End		The end index of the string where the format will be applied.
	 */
	public function addFormat(Format:FlxTextFormat, Start:Int = -1, End:Int = -1):FlxText
	{
		_formatRanges.push(new FlxTextFormatRange(Format, Start, End));
		// sort the array using the start value of the format so we can skip formats that can't be applied to the textField
		_formatRanges.sort(function(left, right)
		{
			return left.range.start < right.range.start ? -1 : 1;
		});
		_regen = true;

		return this;
	}

	/**
	 * Removes a specific `FlxTextFormat` from this text.
	 * If a range is specified, this only removes the format when it touches that range.
	 */
	public function removeFormat(Format:FlxTextFormat, ?Start:Int, ?End:Int):FlxText
	{
		var i = _formatRanges.length;
		while (i-- > 0)
		{
			var formatRange = _formatRanges[i];
			if (formatRange.format != Format)
				continue;

			if (Start != null && End != null)
			{
				var range = formatRange.range;
				if (Start >= range.end || End <= range.start)
					continue;

				if (Start > range.start && End < range.end)
				{
					addFormat(formatRange.format, End + 1, range.end);
					range.end = Start;
					continue;
				}

				if (Start <= range.start && End < range.end)
				{
					range.start = End;
					continue;
				}

				if (Start > range.start && End >= range.end)
				{
					range.end = Start;
					continue;
				}
			}

			_formatRanges.remove(formatRange);
		}

		_regen = true;

		return this;
	}

	/**
	 * Clears all the formats applied.
	 */
	public function clearFormats():FlxText
	{
		_formatRanges = [];
		updateDefaultFormat();

		return this;
	}

	/**
	 * You can use this if you have a lot of text parameters to set instead of the individual properties.
	 *
	 * @param	Font			The name of the font face for the text display.
	 * @param	Size			The size of the font (in pixels essentially).
	 * @param	Color			The color of the text in `0xRRGGBB` format.
	 * @param	Alignment		The desired alignment
	 * @param	BorderStyle		Which border style to use
	 * @param	BorderColor 	Color for the border, `0xAARRGGBB` format
	 * @param	EmbeddedFont	Whether this text field uses embedded fonts or not
	 * @return	This `FlxText` instance (nice for chaining stuff together, if you're into that).
	 */
	public function setFormat(?Font:String, Size:Int = 8, Color:FlxColor = FlxColor.WHITE, ?Alignment:FlxTextAlign, ?BorderStyle:FlxTextBorderStyle,
			BorderColor:FlxColor = FlxColor.TRANSPARENT, EmbeddedFont:Bool = true):FlxText
	{
		BorderStyle = (BorderStyle == null) ? NONE : BorderStyle;

		if (EmbeddedFont)
		{
			font = Font;
		}
		else if (Font != null)
		{
			systemFont = Font;
		}

		size = Size;
		color = Color;
		if (Alignment != null)
			alignment = Alignment;
		setBorderStyle(BorderStyle, BorderColor);

		updateDefaultFormat();

		return this;
	}

	/**
	 * Set border's style (shadow, outline, etc), color, and size all in one go!
	 *
	 * @param	Style outline style
	 * @param	Color outline color in `0xAARRGGBB` format
	 * @param	Size outline size in pixels
	 * @param	Quality outline quality - # of iterations to use when drawing. `0`: just 1, `1`: equal number to `Size`
	 */
	public inline function setBorderStyle(Style:FlxTextBorderStyle, Color:FlxColor = 0, Size:Float = 1, Quality:Float = 1):FlxText
	{
		borderStyle = Style;
		borderColor = Color;
		borderSize = Size;
		borderQuality = Quality;

		return this;
	}

	override function updateHitbox()
	{
		regenGraphic();
		super.updateHitbox();
	}

	function set_fieldWidth(value:Float):Float
	{
		if (textField == null)
			return value;

		if (value <= 0)
		{
			wordWrap = false;
			autoSize = true;
		}
		else
		{
			autoSize = false;
			wordWrap = true;
			textField.width = value;
		}

		_regen = true;
		return value;
	}

	function get_fieldWidth():Float
	{
		return (textField != null) ? textField.width : 0;
	}

	function set_autoSize(value:Bool):Bool
	{
		if (textField != null)
		{
			textField.autoSize = value ? TextFieldAutoSize.LEFT : TextFieldAutoSize.NONE;
			_regen = true;
		}

		return value;
	}

	function get_autoSize():Bool
	{
		return (textField != null) ? (textField.autoSize != TextFieldAutoSize.NONE) : false;
	}

	function set_text(Text:String):String
	{
		text = Text;
		if (textField != null)
		{
			var ot:String = textField.text;
			textField.text = Text;
			_regen = (textField.text != ot) || _regen;
		}
		return Text;
	}

	inline function get_size():Int
	{
		return Std.int(_defaultFormat.size);
	}

	function set_size(Size:Int):Int
	{
		_defaultFormat.size = Size;
		updateDefaultFormat();
		return Size;
	}

	override function set_color(Color:FlxColor):Int
	{
		if (_defaultFormat.color == Color.to24Bit())
		{
			return Color;
		}
		_defaultFormat.color = Color.to24Bit();
		color = Color;
		updateDefaultFormat();
		return Color;
	}

	inline function get_font():String
	{
		return _font;
	}

	function set_font(Font:String):String
	{
		textField.embedFonts = true;

		if (Font != null)
		{
			var newFontName:String = Font;
			if (Assets.exists(Font, AssetType.FONT))
			{
				newFontName = Assets.getFont(Font).fontName;
			}

			_defaultFormat.font = newFontName;
		}
		else
		{
			_defaultFormat.font = FlxAssets.FONT_DEFAULT;
		}

		updateDefaultFormat();
		return _font = _defaultFormat.font;
	}

	inline function get_embedded():Bool
	{
		return textField.embedFonts = true;
	}

	inline function get_systemFont():String
	{
		return _defaultFormat.font;
	}

	function set_systemFont(Font:String):String
	{
		textField.embedFonts = false;
		_defaultFormat.font = Font;
		updateDefaultFormat();
		return Font;
	}

	inline function get_bold():Bool
	{
		return _defaultFormat.bold;
	}

	function set_bold(value:Bool):Bool
	{
		if (_defaultFormat.bold != value)
		{
			_defaultFormat.bold = value;
			updateDefaultFormat();
		}
		return value;
	}

	inline function get_italic():Bool
	{
		return _defaultFormat.italic;
	}

	function set_italic(value:Bool):Bool
	{
		if (_defaultFormat.italic != value)
		{
			_defaultFormat.italic = value;
			updateDefaultFormat();
		}
		return value;
	}

	inline function get_wordWrap():Bool
	{
		return textField.wordWrap;
	}

	function set_wordWrap(value:Bool):Bool
	{
		if (textField.wordWrap != value)
		{
			textField.wordWrap = value;
			_regen = true;
		}
		return value;
	}

	inline function get_alignment():FlxTextAlign
	{
		return FlxTextAlign.fromOpenFL(_defaultFormat.align);
	}

	function set_alignment(Alignment:FlxTextAlign):FlxTextAlign
	{
		_defaultFormat.align = FlxTextAlign.toOpenFL(Alignment);
		updateDefaultFormat();
		return Alignment;
	}

	function set_borderStyle(style:FlxTextBorderStyle):FlxTextBorderStyle
	{
		if (style != borderStyle)
			_regen = true;

		return borderStyle = style;
	}

	function set_borderColor(Color:FlxColor):FlxColor
	{
		if (borderColor != Color && borderStyle != NONE)
			_regen = true;
		_hasBorderAlpha = Color.alphaFloat < 1;
		return borderColor = Color;
	}

	function set_borderSize(Value:Float):Float
	{
		if (Value != borderSize && borderStyle != NONE)
			_regen = true;

		return borderSize = Value;
	}

	function set_borderQuality(Value:Float):Float
	{
		Value = FlxMath.bound(Value, 0, 1);
		if (Value != borderQuality && borderStyle != NONE)
			_regen = true;

		return borderQuality = Value;
	}

	override function set_graphic(Value:FlxGraphic):FlxGraphic
	{
		var oldGraphic:FlxGraphic = graphic;
		var graph:FlxGraphic = super.set_graphic(Value);
		FlxG.bitmap.removeIfNoUse(oldGraphic);
		return graph;
	}

	override function get_width():Float
	{
		regenGraphic();
		return super.get_width();
	}

	override function get_height():Float
	{
		regenGraphic();
		return super.get_height();
	}

	override function updateColorTransform():Void
	{
		if (colorTransform == null)
			colorTransform = new ColorTransform();

		if (alpha != 1)
		{
			colorTransform.alphaMultiplier = alpha;
			useColorTransform = true;
		}
		else
		{
			colorTransform.alphaMultiplier = 1;
			useColorTransform = false;
		}

		dirty = true;
	}

	/**
	 * Target pixel density for FlxText rendering: logical scene scale times
	 * window scale, clamped to [1, 4].
	 */
	function getTextRenderScale():Float
	{
		var result:Float = 1;
		try
		{
			if (FlxG.scaleMode != null)
				result = FlxG.scaleMode.scale.x;

			if (FlxG.stage != null && FlxG.stage.window != null)
				result *= FlxG.stage.window.scale;
		}
		catch (e:Dynamic) {}

		if (result < 1)
			result = 1;
		if (result > 4)
			result = 4;
		if (renderScaleCap > 0 && result > renderScaleCap)
			result = renderScaleCap;

		return result;
	}

	function regenGraphic():Void
	{
		if (textField == null)
			return;

		var renderScale:Float = getTextRenderScale();
		if (Math.abs(renderScale - _textRenderScale) > 0.001)
		{
			_textRenderScale = renderScale;
			_regen = true;
		}

		if (!_regen)
		{
			considerPageStamp();
			return;
		}

		// The bitmap is a pure function of the content signature: the same inputs produce the
		// same pixels, so an unchanged signature means a rebuild would repaint exactly what is
		// already there. flixel and the game both set `_regen` for inputs they re-apply
		// unchanged (a repeated `setFormat`, a `fieldWidth` write, a render-scale re-read), which
		// is why "no regen" cannot be the criterion for packing static text and this is.
		if (_rasterSig != null && _rasterSig == contentSignature())
		{
			_regen = false;
			considerPageStamp();
			return;
		}


		var oldWidth:Int = 0;
		var oldHeight:Int = VERTICAL_GUTTER;

		// A stamped text has to leave the page before it rasterizes: `graphic.bitmap` is the page
		// then, and drawing into it would overwrite every other text packed there.
		var fromPage:Bool = (_pageCell != null);
		var pageBitmap:BitmapData = null;
		var pageCell:FlxRect = null;
		if (fromPage)
		{
			// Hold on to the cell: its pixels are this text's last raster. Copying them into the
			// private bitmap is what keeps the first change after a stamp incremental instead of
			// forcing a full re-raster, which is what a text changing while packed used to cost.
			if (_page != null)
				pageBitmap = _page.bitmap;
			pageCell = _pageCell;
			// The cell is the bitmap plus padding; the rebuild cares about the bitmap.
			oldWidth = _pageW;
			oldHeight = _pageH;
		}
		else if (graphic != null)
		{
			oldWidth = graphic.width;
			oldHeight = graphic.height;
		}

		var newWidth:Float = textField.width;
		// Account for gutter
		var newHeight:Float = textField.textHeight + VERTICAL_GUTTER;


		// prevent text height from shrinking on flash if text == ""
		if (textField.textHeight == 0)
		{
			newHeight = oldHeight / _textRenderScale;
		}

		var pixelWidth:Int = Std.int(Math.max(1, newWidth * _textRenderScale));
		var pixelHeight:Int = Std.int(Math.max(1, newHeight * _textRenderScale));

		// `fromPage` forces the reallocation: the page is never the size of this one text, and
		// the rebuild has to start from a bitmap this text owns.
		var realloc:Bool = fromPage || (oldWidth != pixelWidth || oldHeight != pixelHeight);

		if (realloc)
		{
			// Need to generate a new buffer to store the text graphic.
			// Bitmap pixels use the render scale; logical width/height stay unchanged.
			var key:String = FlxG.bitmap.getUniqueKey("text");
			makeGraphic(pixelWidth, pixelHeight, FlxColor.TRANSPARENT, false, key);

			// makeGraphic() resets size to the high-res bitmap; restore logical size.
			width = newWidth;
			height = newHeight;

			if (_hasBorderAlpha && !fromPage)
				_borderPixels = graphic.bitmap.clone();
			textField.height = newHeight * 1.2;
			_flashRect.x = 0;
			_flashRect.y = 0;
			_flashRect.width = pixelWidth;
			_flashRect.height = pixelHeight;
		}

		// Leaving the page: a cell of the same size holds exactly the pixels this text would own,
		// so migrate them. The rebuild then diffs against `_rasterText`, which still describes
		// those pixels, and only repaints the run that actually changed.
		var migrated:Bool = false;
		if (fromPage && pageBitmap != null && pageCell != null && _pageW == pixelWidth && _pageH == pixelHeight)
		{
			_pageCopy.setTo(pageCell.x, pageCell.y, pixelWidth, pixelHeight);
			migrated = true;
		}

		detachFromPage(migrated);
		if (migrated)
		{
			graphic.bitmap.copyPixels(pageBitmap, _pageCopy, _pageCopyAt);
			if (_hasBorderAlpha)
				_borderPixels = graphic.bitmap.clone();
		}

		// C-2: the rectangle that actually has to be repainted (null = the whole bitmap)
		var dirty:Rectangle = computeDirtyRect(migrated ? false : realloc, pixelWidth, pixelHeight);

		if (dirty == null)
		{
			graphic.bitmap.fillRect(_flashRect, FlxColor.TRANSPARENT);
			if (_hasBorderAlpha)
			{
				if (_borderPixels == null)
					_borderPixels = new BitmapData(frameWidth, frameHeight, true);
				else
					_borderPixels.fillRect(_flashRect, FlxColor.TRANSPARENT);
			}
		}
		else
		{
			// Incremental rebuild: only the changed run is cleared, everything else keeps its pixels
			// (and is not drawn over again, which is why the draws below are clipped to the same box).
			graphic.bitmap.fillRect(dirty, FlxColor.TRANSPARENT);
			if (_hasBorderAlpha)
				_borderPixels.fillRect(dirty, FlxColor.TRANSPARENT);
		}


		if (textField != null && textField.text != null && textField.text.length > 0)
		{
			renderText(dirty);
		}


		_regen = false;
		resetFrame();
		rememberRaster();

	}

	/**
	 * Internal function to draw textField to a BitmapData, if flash it calculates every line x to avoid blurry lines.
	 */
	function drawTextFieldTo(graphic:BitmapData, clip:Rectangle = null):Void
	{
		#if flash
		if (alignment == FlxTextAlign.CENTER && isTextBlurry())
		{
			var h:Int = 0;
			var tx:Float = _matrix.tx;
			for (i in 0...textField.numLines)
			{
				var lineMetrics = textField.getLineMetrics(i);

				// Workaround for blurry lines caused by non-integer x positions on flash
				var diff:Float = lineMetrics.x - Std.int(lineMetrics.x);
				if (diff != 0)
				{
					_matrix.tx = tx + diff;
				}
				_textFieldRect.setTo(0, h, textField.width, lineMetrics.height + lineMetrics.descent);

				graphic.draw(textField, _matrix, null, null, _textFieldRect, false);

				_matrix.tx = tx;
				h += Std.int(lineMetrics.height);
			}

			return;
		}
		#end

		graphic.draw(textField, _matrix, null, null, clip, false);
	}

	#if flash
	/**
	 * Helper function for `drawTextFieldTo()`, this checks if thw workaround is needed to prevent blurry lines.
	 */
	function isTextBlurry():Bool
	{
		for (i in 0...textField.numLines)
		{
			var lineMetricsX = textField.getLineMetrics(i).x;
			if (lineMetricsX - Std.int(lineMetricsX) != 0)
			{
				return true;
			}
		}
		return false;
	}
	#end

	override public function draw():Void
	{
		regenGraphic();

		// Draw the high-res bitmap in logical coordinates with an equivalent origin.
		if (_textRenderScale > 1)
		{
			var oldScaleX:Float = scale.x;
			var oldScaleY:Float = scale.y;
			var oldOriginX:Float = origin.x;
			var oldOriginY:Float = origin.y;

			// Map the high-res center origin back to the logical coordinate space.
			var logicalOriginX:Float = oldOriginX / _textRenderScale;
			var logicalOriginY:Float = oldOriginY / _textRenderScale;
			var scaleXDenom:Float = 1 - oldScaleX / _textRenderScale;
			var scaleYDenom:Float = 1 - oldScaleY / _textRenderScale;
			var newOriginX:Float = 0;
			var newOriginY:Float = 0;
			if (Math.abs(scaleXDenom) > 0.0001)
				newOriginX = logicalOriginX * (1 - oldScaleX) / scaleXDenom;
			if (Math.abs(scaleYDenom) > 0.0001)
				newOriginY = logicalOriginY * (1 - oldScaleY) / scaleYDenom;

			scale.set(oldScaleX / _textRenderScale, oldScaleY / _textRenderScale);
			origin.set(newOriginX, newOriginY);

			super.draw();

			scale.set(oldScaleX, oldScaleY);
			origin.set(oldOriginX, oldOriginY);
		}
		else
		{
			super.draw();
		}
	}

	/**
	 * Internal function to update the current animation frame.
	 *
	 * @param	RunOnCpp	Whether the frame should also be recalculated if we're on a non-flash target
	 */
	override function calcFrame(RunOnCpp:Bool = false):Void
	{
		if (textField == null)
			return;

		if (FlxG.renderTile && !RunOnCpp)
			return;

		regenGraphic();
		super.calcFrame(RunOnCpp);
	}

	/**
	 * Allocation-reusing, cleared scratch bitmap for the border pass.
	 *
	 * C-0 sizes it to the glyph bounding box instead of the full text bitmap: the scratch is
	 * internal and cleared every rebuild, so a smaller one only removes transparent border area.
	 */
	function ensureTextCache(w:Int, h:Int):BitmapData
	{
		// Grow-only: auto-sized texts change their bitmap size on almost every rebuild, and
		// re-allocating the scratch bitmap there costs more than the extra transparent blit area.
		if (_textCache == null)
		{
			_textCache = new BitmapData(w, h, true, FlxColor.TRANSPARENT);
		}
		else if (_textCache.width < w || _textCache.height < h)
		{
			var nw:Int = Std.int(Math.max(w, _textCache.width));
			var nh:Int = Std.int(Math.max(h, _textCache.height));
			_textCache.dispose();
			_textCache = new BitmapData(nw, nh, true, FlxColor.TRANSPARENT);
		}
		else
		{
			_textCache.fillRect(_textCache.rect, FlxColor.TRANSPARENT);
		}
		return _textCache;
	}

	/** Milliseconds since the game started, for the static-text settle timer. */
	inline function uptimeMs():Float
	{
		return (FlxG.game != null) ? FlxG.game.ticks : 0;
	}

	/**
	 * Everything `renderText()` reads, as one comparable string.
	 *
	 * The raster is a pure function of these inputs, so two equal signatures mean a rebuild
	 * would produce the bitmap that is already there. Only pixel-affecting inputs are listed:
	 * tint, alpha, blend, position and scale are applied at draw time and must not invalidate
	 * the raster.
	 */
	function contentSignature():String
	{
		var f:TextFormat = _defaultFormat;
		var sb:StringBuf = new StringBuf();
		sb.add((textField.text == null) ? "" : textField.text);
		sb.add('|');
		sb.add(Std.string(f.font));
		sb.add(',');
		sb.add(Std.string(f.size));
		sb.add(',');
		sb.add(Std.string(f.color));
		sb.add(',');
		sb.add(Std.string(f.bold));
		sb.add(',');
		sb.add(Std.string(f.italic));
		sb.add(',');
		sb.add(Std.string(f.leading));
		sb.add(',');
		sb.add(Std.string(f.align));
		sb.add('|');
		sb.add(Std.string(alignment));
		sb.add(',');
		sb.add(Std.string(borderStyle));
		sb.add(',');
		sb.add(Std.string(borderColor));
		sb.add(',');
		sb.add(Std.string(borderSize));
		sb.add(',');
		sb.add(Std.string(borderQuality));
		sb.add(',');
		// `shadowOffset` is created after the first draw in the constructor.
		sb.add((shadowOffset != null) ? Std.string(shadowOffset.x) : "0");
		sb.add(',');
		sb.add((shadowOffset != null) ? Std.string(shadowOffset.y) : "0");
		sb.add('|');
		sb.add(Std.string(textField.width));
		sb.add(',');
		sb.add(Std.string(textField.multiline));
		sb.add(',');
		sb.add(Std.string(textField.wordWrap));
		sb.add(',');
		sb.add(Std.string(textField.autoSize));
		sb.add(',');
		sb.add(Std.string(textField.embedFonts));
		sb.add(',');
		sb.add(Std.string(_textRenderScale));

		if (_formatRanges.length > 0)
		{
			sb.add('|');
			for (formatRange in _formatRanges)
			{
				var range = formatRange.range;
				var textFormat:TextFormat = formatRange.format.format;
				sb.add(Std.string(range.start));
				sb.add('-');
				sb.add(Std.string(range.end));
				sb.add(',');
				sb.add(Std.string(textFormat.color));
				sb.add(',');
				sb.add(Std.string(textFormat.bold));
				sb.add(',');
				sb.add(Std.string(textFormat.italic));
				sb.add(',');
				sb.add(Std.string(textFormat.leading));
				sb.add(',');
				sb.add(Std.string(formatRange.format.borderColor));
				sb.add(';');
			}
		}

		return sb.toString();
	}

	/** Whether this text may hand its bitmap to the shared page at all. */
	function canUsePage():Bool
	{
		// The page only exists for the quad renderer: blit mode draws `framePixels` and would
		// copy the whole page instead of the cell.
		if (!FlxG.renderTile)
			return false;
		if (graphic == null || graphic.bitmap == null)
			return false;
		// A clipped sprite re-frames its bitmap per sprite, and that frame is never cell sized.
		if (clipRect != null)
			return false;

		return true;
	}

	/**
	 * Moves the finished bitmap into the shared page, once the text has been stable for a while.
	 *
	 * Sharing one page graphic is what collapses the texts into one batch - flixel starts a new
	 * batch whenever the graphic changes - so this only runs while the content signature keeps
	 * matching: a rebuild never reaches it, and the settle timer keeps the burst of formatting
	 * a state does while it builds its HUD from ever touching the page.
	 */
	function considerPageStamp():Void
	{
		if (_pageBanned || _pageCell != null || _regen || _rasterSig == null)
			return;
		if (uptimeMs() - _rasterAt < PAGE_SETTLE_MS)
			return;
		if (!canUsePage())
			return;

		var source:BitmapData = graphic.bitmap;
		if (source == null)
			return;

		var page:FlxTextPage = FlxTextPage.get();
		var cell:FlxRect = page.acquire(source.width, source.height);

		if (cell == null)
		{
			// The current page is full: carry on in a new one, which is still a single graphic
			// and therefore still one batch for every line that lands on it.
			page = FlxTextPage.next();
			if (page != null)
				cell = page.acquire(source.width, source.height);
		}

		if (cell == null)
		{
			// No room anywhere (or too many pages already). Asking again next frame cannot
			// succeed either, so stop proposing this text.
			_pageBanned = true;
			return;
		}

		var pageFrames:FlxImageFrame = FlxImageFrame.fromGraphic(page.graphic, FlxRect.get(cell.x, cell.y, source.width, source.height));
		if (pageFrames == null)
		{
			page.release(cell);
			return;
		}

		page.blit(cell, source);

		// Take the cell first, and only then read the size: `width`/`height` re-enter
		// `regenGraphic()` through their getters, which would stamp this text again from inside
		// its own stamp (and fill the page with copies of the same bitmap).
		_page = page;
		_pageCell = cell;
		_pageW = source.width;
		_pageH = source.height;
		_borderPixels = FlxDestroyUtil.dispose(_borderPixels);

		// Setting `frames` resets the sprite's size to the frame size, which is the bitmap size
		// (render scale included); the logical size is what the rest of the game sees.
		var logicalWidth:Float = width;
		var logicalHeight:Float = height;
		this.frames = pageFrames;
		width = logicalWidth;
		height = logicalHeight;
	}

	/**
	 * Gives the page cell back and returns to a private bitmap.
	 *
	 * The rebuild that follows reallocates (see `realloc` in `regenGraphic()`). When the caller
	 * copied the cell's pixels into the new bitmap first, `keepRaster` leaves the recorded raster
	 * in place so that rebuild can stay incremental; otherwise the fresh bitmap is empty and the
	 * bookkeeping has to be dropped.
	 */
	function detachFromPage(keepRaster:Bool = false):Void
	{
		if (_pageCell == null)
			return;

		// A text that changes after it was packed is not static after all: it gets one more
		// chance (the render scale settles once, early, and re-rasterizes everything), and then
		// stays private so a line that keeps changing cannot cycle in and out of the page.
		if (++_pageDetaches > MAX_PAGE_DETACHES)
			_pageBanned = true;

		if (_page != null)
			_page.release(_pageCell);

		_pageCell = null;
		_page = null;
		_pageW = 0;
		_pageH = 0;
		if (!keepRaster)
		{
			_rasterSig = null;
			_rasterText = null;
		}
		_borderPixels = FlxDestroyUtil.dispose(_borderPixels);
	}

	/** Records what the bitmap now shows, so the next rebuild can tell what it may keep. */
	function rememberRaster():Void
	{
		var f:TextFormat = _defaultFormat;
		_rasterText = textField.text;
		_rasterTextW = textField.textWidth;
		_rasterScale = _textRenderScale;
		_rasterBorderKey = _borderOffsetsKey;
		_rasterFont = Std.string(f.font);
		_rasterAlign = Std.string(f.align);
		_rasterSize = f.size;
		_rasterColor = f.color;
		_rasterLeading = f.leading;
		_rasterBorderColor = borderColor;
		_rasterBorderSize = borderSize;
		_rasterBorderQuality = borderQuality;
		_rasterBorderStyle = borderStyle;
		_rasterAlignment = alignment;
		_rasterFieldW = textField.width;
		_rasterSig = contentSignature();
		_rasterAt = uptimeMs();
	}

	/**
	 * The device-pixel rectangle an incremental rebuild has to repaint, or null when the whole
	 * bitmap has to be redrawn.
	 *
	 * A rebuild can keep the previous pixels when nothing but a value inside the line changed:
	 * the bitmap was not re-allocated, the render scale / font / colours / alignment / border
	 * geometry are the same as last time, the line still has exactly the same width (so the
	 * centred line did not move and the unchanged parts are still at the same x) and the string
	 * differs over one contiguous run of characters only. The rebuilt box then has to cover that
	 * run plus the border's reach, because the untouched glyphs keep their pixels and are simply
	 * not drawn again. Everything else in the bitmap is still valid, so the caller clips the
	 * draws to this rectangle and no pixel outside it is touched.
	 *
	 * It returns null - a full redraw, which is always correct - for every case it cannot prove:
	 * a transparent border colour, a style that draws outside the ring, a width change, an empty
	 * or very different string, and a change that would repaint most of the line anyway.
	 */
	function computeDirtyRect(realloc:Bool, pixelWidth:Int, pixelHeight:Int):Rectangle
	{
		if (realloc) return null;
		if (_hasBorderAlpha || (borderStyle != OUTLINE && borderStyle != OUTLINE_FAST)) return null;

		var text:String = textField.text;
		if (text == null || text.length == 0 || _rasterText == null) return null;
		if (Math.abs(_textRenderScale - _rasterScale) > 0.001) return null;

		var f:TextFormat = _defaultFormat;
		if (_rasterFont != Std.string(f.font) || _rasterAlign != Std.string(f.align)) return null;
		if (_rasterSize != f.size || _rasterColor != f.color || _rasterLeading != f.leading) return null;
		if (_rasterBorderColor != borderColor || _rasterBorderSize != borderSize || _rasterBorderQuality != borderQuality) return null;
		if (_rasterBorderStyle != borderStyle || _rasterAlignment != alignment) return null;
		if (_rasterFieldW != textField.width) return null;

		// the stamp offsets have to be the ones the previous rebuild used
		borderOffsetsFor(_textRenderScale);
		if (_rasterBorderKey != _borderOffsetsKey) return null;

		var textW:Float = textField.textWidth;
		if (Math.abs(textW - _rasterTextW) > 0.01) return null;

		// the changed run: [pre, runEnd) in the new string
		var oldText:String = _rasterText;
		var oldLen:Int = oldText.length;
		var newLen:Int = text.length;
		var pre:Int = 0;
		while (pre < oldLen && pre < newLen && oldText.charCodeAt(pre) == text.charCodeAt(pre))
			pre++;
		if (pre >= newLen && pre >= oldLen) return null; // identical: a full pass is the safe answer
		var suf:Int = 0;
		while (suf < oldLen - pre && suf < newLen - pre
			&& oldText.charCodeAt(oldLen - 1 - suf) == text.charCodeAt(newLen - 1 - suf))
			suf++;
		var runEnd:Int = newLen - suf;
		if (runEnd < pre) runEnd = pre;

		var x0:Float = charX(pre, newLen);
		var x1:Float = charX(runEnd, newLen);
		if (x0 < 0 || x1 < 0 || x1 < x0) return null;

		// x0/x1 are TextField-local, and the text is painted at device x = local * s (the centring is
		// already part of the local coordinates), so the box needs no further offset - only the
		// border's reach, which is drawn up to borderSize * s pixels outside the glyphs.
		var s:Float = _textRenderScale;
		var reach:Int = Std.int(Math.ceil(borderSize * s)) + 2 + Std.int(Math.ceil(2 * s));
		var dx0:Int = Std.int(Math.floor(x0 * s)) - reach;
		var dx1:Int = Std.int(Math.ceil(x1 * s)) + reach;
		if (dx0 < 0) dx0 = 0;
		if (dx1 > pixelWidth) dx1 = pixelWidth;
		if (dx1 <= dx0) return null;
		// repainting most of the line is not worth the bookkeeping (and would need its own proof)
		if ((dx1 - dx0) * 2 > pixelWidth) return null;

		_dirtyRect.setTo(dx0, 0, dx1 - dx0, pixelHeight);
		return _dirtyRect;
	}

	/** Left edge of the text inside the TextField (the alignment's own offset), in TextField units. */
	function oxFor(textW:Float):Float
	{
		if (alignment == FlxTextAlign.CENTER)
			return (textField.width - textW) * 0.5;
		if (alignment == FlxTextAlign.RIGHT)
			return textField.width - textW;
		return 0;
	}

	/**
	 * TextField-local x of a character boundary, -1 when it cannot be resolved.
	 *
	 * The end of the string uses the last character's box instead of textField.textWidth: the
	 * reported width is the advance sum, and the last glyph's box (and its border) can reach past
	 * it - which is exactly the case HUDTEXT_VERIFY caught as a missing column of border pixels.
	 */
	function charX(i:Int, len:Int):Float
	{
		if (i <= 0) return 0;
		if (i >= len)
		{
			var last:Rectangle = textField.getCharBoundaries(len - 1);
			if (last == null) return -1;
			return last.x + last.width;
		}
		var r:Rectangle = textField.getCharBoundaries(i);
		return (r == null) ? -1 : r.x;
	}


	inline static function pushRingOffset(out:Array<Float>, c:Float):Void
	{
		out.push(-c);
		out.push(-c);
		out.push(0);
		out.push(-c);
		out.push(c);
		out.push(-c);
		out.push(c);
		out.push(0);
		out.push(c);
		out.push(c);
		out.push(0);
		out.push(c);
		out.push(-c);
		out.push(c);
		out.push(-c);
		out.push(0);
	}

	/**
	 * Device-space border stamp offsets, in exactly the order the historical border loop produced
	 * them (see `applyBorderStyle`), cached because they only change with style/size/quality/scale.
	 */
	function borderOffsetsFor(s:Float):Array<Float>
	{
		var key:String = '#' + borderStyle + '_' + borderSize + '_' + borderQuality + '_' + s;
		if (_borderOffsetsKey == key && _borderOffsets != null)
			return _borderOffsets;

		var iterations:Int = Std.int(borderSize * borderQuality);
		if (iterations <= 0)
			iterations = 1;
		var delta:Float = borderSize / iterations;
		var out:Array<Float> = [];
		var c:Float;
		switch (borderStyle)
		{
			case SHADOW:
				for (i in 0...iterations)
				{
					c = delta * (i + 1) * s;
					out.push(c);
					out.push(c);
				}
			case OUTLINE:
				for (i in 0...iterations)
				{
					c = delta * (i + 1) * s;
					pushRingOffset(out, c);
				}
			case OUTLINE_FAST:
				for (i in 0...iterations)
				{
					c = delta * (i + 1) * s;
					out.push(-c);
					out.push(-c);
					out.push(c);
					out.push(-c);
					out.push(c);
					out.push(c);
					out.push(-c);
					out.push(c);
				}
			case NONE:
		}
		_borderOffsets = out;
		_borderOffsetsKey = key;
		return out;
	}

	/**
	 * Renders the current text, with its border style, into `graphic.bitmap`.
	 *
	 * The historical implementation drew the TextField itself once per border offset
	 * (`1 + 8 * iterations` draws - 17 for the HUD's `borderSize = 2`), and every one of those
	 * draws goes through the whole TextField path: layout bookkeeping, a fresh renderer for the
	 * target bitmap, glyph submission. Only the first draw of each colour actually rasterizes
	 * glyphs; the rest are pure blits. So the border is rasterized once into a scratch bitmap and
	 * stamped from there with plain bitmap blits at the very same offsets - pixel-identical output,
	 * but the expensive part now runs twice per rebuild instead of 17 times.
	 *
	 * Transparent border colours keep the historical path: they accumulate the stamps and then
	 * multiply their alpha in one pass, which needs the individual TextField draws.
	 */
	function renderText(clip:Rectangle = null, target:BitmapData = null):Void
	{
		copyTextFormat(_defaultFormat, _formatAdjusted);

		var s:Float = _textRenderScale;
		if (borderStyle == NONE || _hasBorderAlpha)
		{
			renderTextHistorical();
			return;
		}

		var bd:BitmapData = (target != null) ? target : graphic.bitmap;

		// C-0: rasterize and stamp only the glyph bounding box. The scratch bitmap is internal and
		// cleared every rebuild, so sizing it to the text instead of the field-width bitmap cannot
		// change a single output pixel - it only stops paying for the transparent area around the
		// glyphs. The box is snapped to whole device pixels, so glyph rasterization stays identical.
		var tw:Float = textField.textWidth;
		var th:Float = textField.textHeight;
		var ox:Float = 0;
		if (alignment == FlxTextAlign.CENTER)
			ox = (textField.width - tw) * 0.5;
		else if (alignment == FlxTextAlign.RIGHT)
			ox = textField.width - tw;
		var pad:Int = TEXT_PAD;
		var bx:Int = Std.int(Math.floor(ox * s)) - pad;
		var by:Int = -pad;
		var bw:Int = Std.int(Math.ceil(tw * s)) + pad * 2;
		var bh:Int = Std.int(Math.ceil(th * s)) + pad * 2;
		if (bw < 1)
			bw = 1;
		if (bh < 1)
			bh = 1;
		var cache:BitmapData = ensureTextCache(bw, bh);

		// Fast path: rasterize the text once, in the fill colour, and composite the border out of
		// that raster's alpha (see FlxTextStamp). Only for a single border/fill colour - format
		// ranges recolour part of the text, which one raster cannot express - and only for the ring
		// styles; every other case keeps the BitmapData.draw path below, so the two paths have to
		// stay equivalent (HUDTEXT_VERIFY compares them pixel by pixel).
		if (FlxTextStamp.available && _formatRanges.length == 0
			&& (borderStyle == OUTLINE || borderStyle == OUTLINE_FAST)
			&& bd.getSurface() != null && cache.getSurface() != null)
		{
			// The scratch raster carries the *border* colour: the ring is this raster painted at each
			// offset, and the fill is the fill colour through its alpha. Drawing it in the fill colour
			// instead forces the ring through a mask, which samples nearest and quantizes fractional
			// offsets (visible at 1.5x as a displaced outline).
			var fillColor:Int = _defaultFormat.color;
			applyFormats(_formatAdjusted, true);

			_matrix.identity();
			_matrix.a = s;
			_matrix.d = s;
			_matrix.tx = -bx;
			_matrix.ty = -by;
			cache.draw(textField, _matrix);

			FlxTextStamp.begin(bd, cache, clip);
			FlxTextStamp.border(borderOffsetsFor(s), bx, by);

			FlxTextStamp.fill(fillColor, bx, by);
			FlxTextStamp.end();
			return;
		}

		// 1) rasterize the border-coloured text once, into the box-sized scratch bitmap
		applyFormats(_formatAdjusted, true);
		_matrix.identity();
		_matrix.a = s;
		_matrix.d = s;
		_matrix.tx = -bx;
		_matrix.ty = -by;
		cache.draw(textField, _matrix);

		// 2) the border itself: plain bitmap blits at the offsets the old loop used
		var offsets:Array<Float> = borderOffsetsFor(s);
		var m:openfl.geom.Matrix = _matrix;
		var i:Int = 0;
		while (i < offsets.length)
		{
			m.identity();
			m.tx = bx + offsets[i];
			m.ty = by + offsets[i + 1];
			// Clipped to the rebuilt box: outside it the previous pixels are already correct.
			bd.draw(cache, m, null, null, clip, false);
			i += 2;
		}

		// 3) the fill-coloured text on top, exactly like the last pass of the old loop
		applyFormats(_formatAdjusted, false);
		m.identity();
		if (s != 1)
			m.scale(s, s);
		if (borderStyle == SHADOW)
			m.translate(-shadowOffset.x * borderSize, -shadowOffset.y * borderSize);
		drawTextFieldTo(bd, clip);
	}

	/** The pre-existing render pass, kept for transparent borders and as the benchmark baseline. */
	function renderTextHistorical():Void
	{
		copyTextFormat(_defaultFormat, _formatAdjusted);

		_matrix.identity();
		if (_textRenderScale != 1)
			_matrix.scale(_textRenderScale, _textRenderScale);

		applyBorderStyle();
		applyBorderTransparency();
		applyFormats(_formatAdjusted, false);

		drawTextFieldTo(graphic.bitmap);
	}

	function applyBorderStyle():Void
	{
		var iterations:Int = Std.int(borderSize * borderQuality);
		if (iterations <= 0)
		{
			iterations = 1;
		}
		var delta:Float = borderSize / iterations;

		switch (borderStyle)
		{
			case SHADOW:
				// Render a shadow beneath the text
				// (do one lower-right offset draw call)
				applyFormats(_formatAdjusted, true);

				for (i in 0...iterations)
				{
					copyTextWithOffset(delta, delta);
				}

				_matrix.translate(-shadowOffset.x * borderSize, -shadowOffset.y * borderSize);

			case OUTLINE:
				// Render an outline around the text
				// (do 8 offset draw calls)
				applyFormats(_formatAdjusted, true);

				var curDelta:Float = delta;
				for (i in 0...iterations)
				{
					copyTextWithOffset(-curDelta, -curDelta); // upper-left
					copyTextWithOffset(curDelta, 0); // upper-middle
					copyTextWithOffset(curDelta, 0); // upper-right
					copyTextWithOffset(0, curDelta); // middle-right
					copyTextWithOffset(0, curDelta); // lower-right
					copyTextWithOffset(-curDelta, 0); // lower-middle
					copyTextWithOffset(-curDelta, 0); // lower-left
					copyTextWithOffset(0, -curDelta); // lower-left

					_matrix.translate(curDelta, 0); // return to center
					curDelta += delta;
				}

			case OUTLINE_FAST:
				// Render an outline around the text
				// (do 4 diagonal offset draw calls)
				// (this method might not work with certain narrow fonts)
				applyFormats(_formatAdjusted, true);

				var curDelta:Float = delta;
				for (i in 0...iterations)
				{
					copyTextWithOffset(-curDelta, -curDelta); // upper-left
					copyTextWithOffset(curDelta * 2, 0); // upper-right
					copyTextWithOffset(0, curDelta * 2); // lower-right
					copyTextWithOffset(-curDelta * 2, 0); // lower-left

					_matrix.translate(curDelta, -curDelta); // return to center
					curDelta += delta;
				}

			case NONE:
		}
	}

	inline function applyBorderTransparency()
	{
		if (!_hasBorderAlpha)
			return;

		if (_borderColorTransform == null)
			_borderColorTransform = new ColorTransform();

		_borderColorTransform.alphaMultiplier = borderColor.alphaFloat;
		_borderPixels.colorTransform(_borderPixels.rect, _borderColorTransform);
		graphic.bitmap.draw(_borderPixels);
	}

	/**
	 * Helper function for `applyBorderStyle()`
	 */
	inline function copyTextWithOffset(x:Float, y:Float)
	{
		var graphic:BitmapData = _hasBorderAlpha ? _borderPixels : graphic.bitmap;
		_matrix.translate(x, y);
		drawTextFieldTo(graphic);
	}

	function applyFormats(FormatAdjusted:TextFormat, UseBorderColor:Bool = false):Void
	{
		// Apply the default format
		copyTextFormat(_defaultFormat, FormatAdjusted, false);
		FormatAdjusted.color = UseBorderColor ? borderColor.to24Bit() : _defaultFormat.color;
		textField.setTextFormat(FormatAdjusted);

		// Apply other formats
		for (formatRange in _formatRanges)
		{
			if (textField.text.length - 1 < formatRange.range.start)
			{
				// we can break safely because the array is ordered by the format start value
				break;
			}
			else
			{
				var textFormat:TextFormat = formatRange.format.format;
				copyTextFormat(textFormat, FormatAdjusted, false);
				FormatAdjusted.color = UseBorderColor ? formatRange.format.borderColor.to24Bit() : textFormat.color;
			}

			textField.setTextFormat(FormatAdjusted, formatRange.range.start, Std.int(Math.min(formatRange.range.end, textField.text.length)));
		}
	}

	function copyTextFormat(from:TextFormat, to:TextFormat, withAlign:Bool = true):Void
	{
		to.font = from.font;
		to.bold = from.bold;
		to.italic = from.italic;
		to.size = from.size;
		to.color = from.color;
		to.leading = from.leading;
		if (withAlign)
			to.align = from.align;
	}

	/**
	 * A helper function for updating the TextField that we use for rendering.
	 *
	 * @return	A writable copy of `TextField.defaultTextFormat`.
	 */
	function dtfCopy():TextFormat
	{
		var dtf:TextFormat = textField.defaultTextFormat;
		return new TextFormat(dtf.font, dtf.size, dtf.color, dtf.bold, dtf.italic, dtf.underline, dtf.url, dtf.target, dtf.align);
	}

	inline function updateDefaultFormat():Void
	{
		textField.defaultTextFormat = _defaultFormat;
		textField.setTextFormat(_defaultFormat);
		_regen = true;
	}

	override function set_frames(Frames:FlxFramesCollection):FlxFramesCollection
	{
		super.set_frames(Frames);
		_regen = false;
		return Frames;
	}
}

@:allow(flixel.text.FlxText)
class FlxTextFormat
{
	/**
	 * The leading (vertical space between lines) of the text.
	 * @since 4.10.0
	 */
	public var leading(default, set):Int;

	/**
	 * The border color if the text has a shadow or a border
	 */
	var borderColor:FlxColor;

	var format(default, null):TextFormat;

	/**
	 * @param   FontColor     Font color, in `0xRRGGBB` format. Inherits from the default format by default.
	 * @param   Bold          Whether the text should be bold (must be supported by the font). `false` by default.
	 * @param   Italic        Whether the text should be in italics (must be supported by the font). Only works on Flash. `false` by default.
	 * @param   BorderColor   Border color, in `0xAARRGGBB` format. By default, no border (`null` / transparent).
	 */
	public function new(?FontColor:FlxColor, ?Bold:Bool, ?Italic:Bool, ?BorderColor:FlxColor)
	{
		format = new TextFormat(null, null, FontColor, Bold, Italic);
		borderColor = BorderColor == null ? FlxColor.TRANSPARENT : BorderColor;
	}

	function set_leading(value:Int):Int
	{
		format.leading = value;
		return value;
	}
}

private class FlxTextFormatRange
{
	public var range(default, null):FlxRange<Int>;
	public var format(default, null):FlxTextFormat;

	public function new(format:FlxTextFormat, start:Int, end:Int)
	{
		range = new FlxRange<Int>(start, end);
		this.format = format;
	}
}

class FlxTextFormatMarkerPair
{
	public var format:FlxTextFormat;
	public var marker:String;

	public function new(format:FlxTextFormat, marker:String)
	{
		this.format = format;
		this.marker = marker;
	}
}

enum FlxTextBorderStyle
{
	NONE;

	/**
	 * A simple shadow to the lower-right.
	 * Use `FlxText.shadowOffset` for custom placement.
	 */
	SHADOW;

	/**
	 * Outline on all 8 sides
	 */
	OUTLINE;

	/**
	 * Outline, optimized using only 4 draw calls (might not work for narrow and/or 1-pixel fonts)
	 */
	OUTLINE_FAST;
}

enum abstract FlxTextAlign(String) from String
{
	var LEFT = "left";

	/**
	 * Warning: on Flash, this can have a negative impact on performance
	 * of multiline texts that are frequently regenerated (especially with
	 * `borderStyle == OUTLINE`) due to a workaround for blurry rendering.
	 */
	var CENTER = "center";

	var RIGHT = "right";
	var JUSTIFY = "justify";

	public static function fromOpenFL(align:AlignType):FlxTextAlign
	{
		return switch (align)
		{
			case TextFormatAlign.LEFT: LEFT;
			case TextFormatAlign.CENTER: CENTER;
			case TextFormatAlign.RIGHT: RIGHT;
			case TextFormatAlign.JUSTIFY: JUSTIFY;
			default: LEFT;
		}
	}

	public static function toOpenFL(align:FlxTextAlign):AlignType
	{
		return switch (align)
		{
			case LEFT: TextFormatAlign.LEFT;
			case CENTER: TextFormatAlign.CENTER;
			case RIGHT: TextFormatAlign.RIGHT;
			case JUSTIFY: TextFormatAlign.JUSTIFY;
			default: TextFormatAlign.LEFT;
		}
	}
}

private typedef AlignType = #if openfl_legacy String #else TextFormatAlign #end;
